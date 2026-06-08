#!/usr/bin/env bash
# =============================================================================
# backup.sh — Automated backup to AWS S3 Glacier Deep Archive
# =============================================================================
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
DATE_LABEL="$(date +%Y-%m-%d)"
DRY_RUN=false
VERIFY=false
EXIT_CODE=0

export RCLONE_CONFIG="/etc/rclone/rclone.conf"

CONFIG_FILE="${BACKUP_CONFIG_PATH:-/opt/tsdb-backup/backup.conf}"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Configuration file not found at $CONFIG_FILE"
    exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

# Provide safe defaults if config is missing them
DOCKER_STOP_TIMEOUT="${DOCKER_STOP_TIMEOUT:-30}"
STAGING_DIR="${STAGING_DIR:-/var/backup/staging}"
LOG_DIR="${LOG_DIR:-/var/log/backup}"
LOG_FILE="${LOG_DIR}/backup-$(date +%Y-%m).log"
MAX_LOG_DAYS="${MAX_LOG_DAYS:-90}"
KEEP_LOCAL_ARCHIVES="${KEEP_LOCAL_ARCHIVES:-7}"
RCLONE_RETRIES="${RCLONE_RETRIES:-3}"

# Parse arguments
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --verify)  VERIFY=true  ;;
    esac
done

mkdir -p "$LOG_DIR" "$STAGING_DIR"
chmod 700 "$STAGING_DIR"

# ─── Logging & Heartbeats ─────────────────────────────────────────────────────

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
separator()   { echo "────────────────────────────────────────────────────" | tee -a "$LOG_FILE"; }

ping_heartbeat() {
    local status="$1" # start, success, or fail
    if [[ -n "${HEARTBEAT_URL:-}" ]]; then
        # Append status to URL if it's start or fail (standard for Healthchecks.io)
        local url="$HEARTBEAT_URL"
        [[ "$status" != "success" ]] && url="${url}/${status}"
        curl -fsS -m 10 --retry 3 "$url" >/dev/null 2>&1 || true
    fi
}

# ─── Dependency & Resource Checks ─────────────────────────────────────────────

check_deps() {
    local missing=()
    for cmd in rclone tar sha256sum docker du df; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing[*]}"
        exit 1
    fi
}

check_disk_space() {
    local source_path="$1"
    
    # Get source size in KB
    local source_kb
    source_kb="$(du -sk "$source_path" | cut -f1)"
    
    # Get available space in STAGING_DIR in KB
    local avail_kb
    avail_kb="$(df -Pk "$STAGING_DIR" | awk 'NR==2 {print $4}')"

    # Require 1.5x the source size to be safe during compression
    local required_kb=$(( source_kb * 15 / 10 ))

    if [[ "$avail_kb" -lt "$required_kb" ]]; then
        log_error "Insufficient disk space! Required: $((required_kb/1024))MB, Available: $((avail_kb/1024))MB"
        return 1
    fi
    log_info "Disk space OK. Available: $((avail_kb/1024))MB, Estimated Need: $((required_kb/1024))MB"
}

# ─── Docker Handling ──────────────────────────────────────────────────────────

STOPPED_COMPOSE_DIRS=()

_docker_restart_all() {
    if [[ ${#STOPPED_COMPOSE_DIRS[@]} -gt 0 ]]; then
        log_warn "EXIT trap: restarting any stopped containers..."
        for compose_dir in "${STOPPED_COMPOSE_DIRS[@]}"; do
            docker compose -f "${compose_dir}/compose.yml" start >/dev/null 2>&1 || true
        done
    fi
}
trap '_docker_restart_all' EXIT



docker_stop() {
    local compose_dir="$1"
    if [[ ! -f "${compose_dir}/compose.yml" && ! -f "${compose_dir}/docker-compose.yml" ]]; then
        return 0
    fi

    log_info "Stopping containers in: ${compose_dir}"
    if docker compose -f "${compose_dir}/compose.yml" stop --timeout "$DOCKER_STOP_TIMEOUT" >> "$LOG_FILE" 2>&1; then
        STOPPED_COMPOSE_DIRS+=("$compose_dir")
        log_success "Containers stopped."
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
    if docker compose -f "${compose_dir}/compose.yml" start >> "$LOG_FILE" 2>&1; then
        # Remove from trap list
        local updated=()
        for d in "${STOPPED_COMPOSE_DIRS[@]}"; do
            [[ "$d" != "$compose_dir" ]] && updated+=("$d")
        done
        STOPPED_COMPOSE_DIRS=("${updated[@]}")
        log_success "Containers started."
    else
        log_error "Failed to start containers! Manual intervention needed."
        return 1
    fi
}

# ─── Archive & Upload ─────────────────────────────────────────────────────────

archive_source() {
    local source_path="$1"
    local source_name; source_name="$(basename "$source_path")"
    local archive_name="${ARCHIVE_PREFIX}_${source_name}_${TIMESTAMP}.tar.gz"
    local archive_path="${STAGING_DIR}/${archive_name}"

    log_info "Archiving: ${source_path}"

    # Use pigz if available for multi-core speed, otherwise fallback to gzip
    local tar_cmd=("tar" "-cf" "$archive_path")
    if command -v pigz >/dev/null 2>&1; then
        tar_cmd=("tar" "-I" "pigz" "-cf" "$archive_path")
        log_info "Using pigz for parallel compression"
    else
        tar_cmd=("tar" "-czf" "$archive_path")
    fi

    "${tar_cmd[@]}" \
        --exclude="*.log" --exclude="*.tmp" \
        -C "$(dirname "$source_path")" "$(basename "$source_path")" 2>>"$LOG_FILE"
    
    local tar_exit=$?
    if [[ $tar_exit -eq 2 ]]; then
        log_error "Fatal error creating archive."
        return 1
    fi

    sha256sum "$archive_path" > "${archive_path}.sha256"
    local size; size="$(du -sh "$archive_path" | cut -f1)"
    log_success "Archive created: ${archive_name} (${size})"
    echo "$archive_path"
}

upload_to_s3() {
    local remote="${RCLONE_REMOTE}:${S3_BUCKET}/${S3_PREFIX}/"

    if $DRY_RUN; then
        log_info "[DRY-RUN] Would upload to ${remote}"
        return 0
    fi

    log_info "Uploading to ${remote}"
    if ! rclone copy "$STAGING_DIR" "$remote" \
            --s3-storage-class "$S3_STORAGE_CLASS" \
            --retries "$RCLONE_RETRIES" \
            --low-level-retries 10 \
            --progress 2>&1 | tee -a "$LOG_FILE"; then
        log_error "Upload failed"
        return 1
    fi
    log_success "Upload complete."
}



cleanup_old_files() {
    log_info "Cleaning files older than ${KEEP_LOCAL_ARCHIVES} days..."
    find "$STAGING_DIR" -type f -name "*.tar.*" -mtime +"${KEEP_LOCAL_ARCHIVES}" -delete
    find "$STAGING_DIR" -type f -name "*.sha256" -mtime +"${KEEP_LOCAL_ARCHIVES}" -delete
    find "$LOG_DIR" -type f -name "*.log" -mtime +"${MAX_LOG_DAYS}" -delete 2>/dev/null || true
}

# ─── Main Execution ───────────────────────────────────────────────────────────

main() {
    ping_heartbeat "start"
    separator
    log_info "╔══ Backup started for: ${ARCHIVE_PREFIX} (${TIMESTAMP})"
    separator

    check_deps

    local failed=0
    for source in "${BACKUP_SOURCES[@]}"; do
        if [[ ! -e "$source" ]]; then
            log_warn "Source not found: ${source}"; continue
        fi

        if ! check_disk_space "$source"; then
            (( failed++ )) || true; continue
        fi

        local compose_dir="${DOCKER_COMPOSE_MAP[$source]:-}"
        [[ -n "$compose_dir" ]] && docker_stop "$compose_dir"

        local archive_path
        if archive_path="$(archive_source "$source")"; then
            [[ -n "$compose_dir" ]] && docker_start "$compose_dir"
            upload_to_s3 "$archive_path" || (( failed++ )) || true
        else
            [[ -n "$compose_dir" ]] && docker_start "$compose_dir"
            (( failed++ )) || true
        fi
        separator
    done

    cleanup_old_files

    separator
    if [[ $failed -eq 0 ]]; then
        log_success "╚══ Backup finished successfully."
        ping_heartbeat "success"
    else
        log_error "╚══ Backup finished with ${failed} failure(s)."
        ping_heartbeat "fail"
    fi
    separator
    exit $EXIT_CODE
}

main "$@"