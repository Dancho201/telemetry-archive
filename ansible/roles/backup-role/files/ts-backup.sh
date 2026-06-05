#!/usr/bin/env bash
# =============================================================================
# backup.sh — Automated backup to AWS S3 Glacier Deep Archive via rclone
# =============================================================================
# Usage:
#   ./backup.sh                  # backup all configured sources
#   ./backup.sh --dry-run        # simulate without uploading
#   ./backup.sh --verify         # verify remote after upload
# Cron example (daily at 2:30 AM):
#   30 2 * * * /opt/backup/backup.sh >> /var/log/backup/cron.log 2>&1
# =============================================================================

set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────

# Directories to back up (space-separated, or load from config file)
BACKUP_SOURCES=(
    "/opt/kumacompose"          # adjust to your actual path
    # "/opt/another-service"    # add more sources here
)

# ── Docker settings ───────────────────────────────────────────────────────────
# Map each source directory to the compose project that owns it.
# Format: ["source_path"]="compose_project_dir"
# Leave empty to skip Docker stop/start entirely.
declare -A DOCKER_COMPOSE_MAP=(
    ["/opt/kumacompose"]="/opt/kumacompose"   # dir containing compose.yml
    # ["/opt/another-service"]="/opt/another-service"
)

# Seconds to wait after `docker compose stop` before archiving
DOCKER_STOP_TIMEOUT=30

# Where to store local archives before upload
STAGING_DIR="/var/backup/staging"

# Log settings
LOG_DIR="/var/log/backup"
LOG_FILE="${LOG_DIR}/backup-$(date +%Y-%m).log"   # monthly rotating log
MAX_LOG_DAYS=90                                    # keep logs this many days

# Archive settings
ARCHIVE_PREFIX="backup"
COMPRESSION="gz"                                   # gz | bz2 | xz
KEEP_LOCAL_ARCHIVES=7                              # days to keep local archives

# rclone remote name (as configured in rclone config)
RCLONE_REMOTE="s3-deep-archive"

# S3 bucket and path
S3_BUCKET="tsdb-backup-da"
S3_PREFIX="backups"                                # folder prefix inside bucket

# Storage class — cheapest AWS options:
#   DEEP_ARCHIVE          → $0.00099/GB/month  (12h retrieval minimum)
#   GLACIER               → $0.004/GB/month    (3-5h retrieval)
#   INTELLIGENT_TIERING   → auto-moves tiers
S3_STORAGE_CLASS="DEEP_ARCHIVE"

# Notification (optional — leave empty to disable)
# Set NOTIFY_EMAIL to receive failure alerts via sendmail/msmtp
NOTIFY_EMAIL="yordan.basin@noto360.com"
# Or use a webhook (curl POST on failure)
NOTIFY_WEBHOOK=""

# ─── Script internals ─────────────────────────────────────────────────────────

SCRIPT_NAME="$(basename "$0")"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
DATE_LABEL="$(date +%Y-%m-%d)"
DRY_RUN=false
VERIFY=false
EXIT_CODE=0

# Parse arguments
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --verify)  VERIFY=true  ;;
        --help)
            echo "Usage: $SCRIPT_NAME [--dry-run] [--verify] [--help]"
            exit 0
            ;;
    esac
done

# ─── Logging helpers ──────────────────────────────────────────────────────────

mkdir -p "$LOG_DIR" "$STAGING_DIR"

log() {
    local level="$1"; shift
    local msg="$*"
    local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[${ts}] [${level}] ${msg}" | tee -a "$LOG_FILE"
}

log_info()    { log "INFO   " "$@"; }
log_success() { log "SUCCESS" "$@"; }
log_warn()    { log "WARN   " "$@"; }
log_error()   { log "ERROR  " "$@"; EXIT_CODE=1; }

separator() {
    echo "────────────────────────────────────────────────────" | tee -a "$LOG_FILE"
}

# ─── Dependency check ─────────────────────────────────────────────────────────

check_deps() {
    local missing=()
    for cmd in rclone tar gzip sha256sum docker; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing[*]}"
        log_error "Install with: apt install ${missing[*]}  (or equivalent)"
        exit 1
    fi
}

# ─── Docker helpers ───────────────────────────────────────────────────────────

# Tracks which compose dirs were actually stopped so we restart only those
STOPPED_COMPOSE_DIRS=()

# Called automatically on exit (even on error) to ensure containers come back up
_docker_restart_all() {
    if [[ ${#STOPPED_COMPOSE_DIRS[@]} -gt 0 ]]; then
        log_warn "EXIT trap: restarting any stopped containers..."
        for compose_dir in "${STOPPED_COMPOSE_DIRS[@]}"; do
            docker_start "$compose_dir" || true
        done
    fi
}
trap '_docker_restart_all' EXIT

docker_stop() {
    local compose_dir="$1"

    if [[ ! -f "${compose_dir}/compose.yml" && ! -f "${compose_dir}/docker-compose.yml" ]]; then
        log_warn "No compose file found in ${compose_dir}, skipping Docker stop."
        return 0
    fi

    log_info "Stopping containers in: ${compose_dir}"
    if docker compose -f "${compose_dir}/compose.yml" stop --timeout "$DOCKER_STOP_TIMEOUT" \
            >> "$LOG_FILE" 2>&1; then
        STOPPED_COMPOSE_DIRS+=("$compose_dir")
        log_success "Containers stopped: ${compose_dir}"
        # Brief pause to let the app flush any pending writes
        sleep 2
    else
        log_error "Failed to stop containers in: ${compose_dir}"
        return 1
    fi
}

docker_start() {
    local compose_dir="$1"

    if [[ ! -f "${compose_dir}/compose.yml" && ! -f "${compose_dir}/docker-compose.yml" ]]; then
        return 0
    fi

    log_info "Starting containers in: ${compose_dir}"
    if docker compose -f "${compose_dir}/compose.yml" start \
            >> "$LOG_FILE" 2>&1; then
        # Remove from the stopped list — no need to restart again in trap
        local updated=()
        for d in "${STOPPED_COMPOSE_DIRS[@]}"; do
            [[ "$d" != "$compose_dir" ]] && updated+=("$d")
        done
        STOPPED_COMPOSE_DIRS=("${updated[@]}")
        log_success "Containers started: ${compose_dir}"
    else
        log_error "Failed to start containers in: ${compose_dir} — manual intervention needed!"
        return 1
    fi
}

# ─── Archive a single source ──────────────────────────────────────────────────

archive_source() {
    local source_path="$1"
    local source_name; source_name="$(basename "$source_path")"
    local archive_name="${ARCHIVE_PREFIX}_${source_name}_${TIMESTAMP}.tar.${COMPRESSION}"
    local archive_path="${STAGING_DIR}/${archive_name}"
    local checksum_path="${archive_path}.sha256"

    log_info "Archiving: ${source_path}"

    if [[ ! -d "$source_path" && ! -f "$source_path" ]]; then
        log_warn "Source not found, skipping: ${source_path}"
        return 0
    fi

    # Create compressed archive
    local tar_flag
    case "$COMPRESSION" in
        gz)  tar_flag="z" ;;
        bz2) tar_flag="j" ;;
        xz)  tar_flag="J" ;;
        *)   log_error "Unknown compression: $COMPRESSION"; return 1 ;;
    esac

    tar -c"${tar_flag}"f "$archive_path" \
            --exclude="*.log" \
            --exclude="*.tmp" \
            --exclude="__pycache__" \
            --exclude=".git" \
            -C "$(dirname "$source_path")" \
            "$(basename "$source_path")" 2>>"$LOG_FILE"
    local tar_exit=$?
    # exit code 1 = warnings only (e.g. "file changed as we read it") — tolerated
    # exit code 2 = fatal error — abort
    if [[ $tar_exit -eq 2 ]]; then
        log_error "Failed to create archive for: ${source_path} (tar fatal error)"
        return 1
    elif [[ $tar_exit -eq 1 ]]; then
        log_warn "Archive created with warnings for: ${source_path} (file changed — ensure container is stopped)"
    fi

    # Generate checksum
    sha256sum "$archive_path" > "$checksum_path"
    local size; size="$(du -sh "$archive_path" | cut -f1)"
    log_success "Archive created: ${archive_name} (${size})"

    # Return the archive path for upload
    echo "$archive_path"
}

# ─── Upload to S3 via rclone ──────────────────────────────────────────────────

upload_to_s3() {
    local remote="${RCLONE_REMOTE}:${S3_BUCKET}/${S3_PREFIX}/"

    if $DRY_RUN; then
        log_info "[DRY-RUN] Would upload: ${STAGING_DIR} → ${remote}"
        rclone copy "$STAGING_DIR" "$remote" \
            --s3-storage-class "$S3_STORAGE_CLASS" \
            --progress \
            --dry-run 2>&1 | tee -a "$LOG_FILE"
    else
        log_info "Uploading: ${STAGING_DIR} → ${remote}"
        if ! rclone copy "$STAGING_DIR" "$remote" \
                --s3-storage-class "$S3_STORAGE_CLASS" \
                --progress 2>&1 | tee -a "$LOG_FILE"; then
            log_error "Upload failed"
            return 1
        fi
    fi

    log_success "Upload complete → ${remote}"
}

# ─── Optional: verify remote listing ─────────────────────────────────────────

verify_remote() {
    log_info "Verifying remote files at: ${RCLONE_REMOTE}:${S3_BUCKET}/${S3_PREFIX}/${DATE_LABEL}/"
    rclone ls "${RCLONE_REMOTE}:${S3_BUCKET}/${S3_PREFIX}/${DATE_LABEL}/" \
        --log-level INFO 2>>"$LOG_FILE" | tee -a "$LOG_FILE" || \
        log_warn "Could not list remote (may be normal for Deep Archive)"
}

# ─── Cleanup old local archives ───────────────────────────────────────────────

cleanup_local() {
    log_info "Cleaning local archives older than ${KEEP_LOCAL_ARCHIVES} days..."
    find "$STAGING_DIR" -name "*.tar.*" -mtime +"${KEEP_LOCAL_ARCHIVES}" -delete
    find "$STAGING_DIR" -name "*.sha256" -mtime +"${KEEP_LOCAL_ARCHIVES}" -delete
    log_info "Local cleanup done."
}

# ─── Cleanup old logs ─────────────────────────────────────────────────────────

cleanup_logs() {
    find "$LOG_DIR" -name "*.log" -mtime +"${MAX_LOG_DAYS}" -delete 2>/dev/null || true
}

# ─── Notifications ────────────────────────────────────────────────────────────

notify_failure() {
    local subject="[BACKUP FAILED] ${HOSTNAME:-server} — ${DATE_LABEL}"
    local body="Backup script encountered errors. Check log: ${LOG_FILE}"

    if [[ -n "$NOTIFY_EMAIL" ]]; then
        echo "$body" | mail -s "$subject" "$NOTIFY_EMAIL" 2>/dev/null || true
    fi

    if [[ -n "$NOTIFY_WEBHOOK" ]]; then
        curl -sS -X POST "$NOTIFY_WEBHOOK" \
            -H "Content-Type: application/json" \
            -d "{\"text\":\"${subject}\"}" >/dev/null 2>&1 || true
    fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
    separator
    log_info "╔══ Backup started: ${TIMESTAMP}"
    $DRY_RUN && log_warn "DRY-RUN mode — no files will be uploaded"
    separator

    check_deps

    local uploaded=0
    local failed=0

    for source in "${BACKUP_SOURCES[@]}"; do
        log_info "Processing source: ${source}"

        # Stop associated Docker containers if mapped
        local compose_dir="${DOCKER_COMPOSE_MAP[$source]:-}"
        if [[ -n "$compose_dir" ]]; then
            if ! docker_stop "$compose_dir"; then
                log_error "Skipping backup of ${source} due to Docker stop failure."
                (( failed++ )) || true
                separator
                continue
            fi
        fi

        # Archive
        local archive_path
        if archive_path="$(archive_source "$source")"; then
            # Restart containers as soon as archive is done — minimise downtime
            if [[ -n "$compose_dir" ]]; then
                docker_start "$compose_dir" || true
            fi
            # Upload
            if upload_to_s3 "$archive_path"; then
                (( uploaded++ )) || true
            else
                (( failed++ )) || true
            fi
        else
            # Archive failed — still restart containers
            if [[ -n "$compose_dir" ]]; then
                docker_start "$compose_dir" || true
            fi
            (( failed++ )) || true
        fi

        separator
    done

    # Verify (optional flag)
    $VERIFY && verify_remote

    # Cleanup
    cleanup_local
    cleanup_logs

    separator
    if [[ $failed -eq 0 ]]; then
        log_success "╚══ Backup finished: ${uploaded} source(s) uploaded, 0 failures."
    else
        log_error "╚══ Backup finished with errors: ${uploaded} uploaded, ${failed} failed."
        notify_failure
    fi
    separator

    exit $EXIT_CODE
}

main "$@"
