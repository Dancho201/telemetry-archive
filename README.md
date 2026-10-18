# telemetry-archive

Monthly, low-cost backups of a small monitoring host (Grafana + Uptime Kuma) to
Amazon S3 Glacier Instant Retrieval.

Terraform provisions the S3 bucket and a cheap EC2 spot instance; Ansible installs
Docker, runs Grafana and Uptime Kuma with Docker Compose, and installs a systemd
timer that archives both stacks and ships them to S3 once a month.

```
┌──────────────── EC2 (Ubuntu 24.04, t3.nano spot) ────────────────┐
│                                                                  │
│  /opt/grafanacompose   ── grafana      (127.0.0.1:3000)          │
│  /opt/kumacompose      ── uptime-kuma  (127.0.0.1:3001)          │
│                                                                  │
│  ts-backup.timer (monthly) ─▶ ts-backup.sh  (runs as `noto`)     │
│     stop stack ▸ tar.gz + sha256 ▸ start stack ▸ rclone copy     │
│                                                        │         │
└────────────────────────────────────────────────────────┼─────────┘
                                   instance IAM role     ▼
                    s3://tsdb-backup-da/backups/<hostname>/  (GLACIER_IR)
                    lifecycle: delete after 365 days
```

## Repository layout

```
.
├── terraform/
│   ├── s3/                       # Backup bucket, encryption, lifecycle rules
│   └── ec2/                      # Spot instance, security group, IAM role/profile
├── docker_engine/                # Role: swapfile + Docker Engine & Compose plugin
├── backup_monitoring_stack/      # Role: noto user, rclone, backup script, systemd timer
│   └── files/
│       ├── ts-backup.sh          # The backup script
│       ├── backup.conf           # What to back up and where to send it
│       └── rclone.conf           # rclone S3 remote (uses the instance role)
├── monitoring_apps/              # Role: Grafana + Uptime Kuma compose stacks
├── site.yml                      # Playbook: docker_engine → backup_monitoring_stack → monitoring_apps
├── inventory.ini.example         # Target host template (copy to inventory.ini)
└── ansible.cfg
```

## Prerequisites

- An AWS account and credentials available to Terraform through the standard
  credential chain (`aws configure`, `AWS_PROFILE`, or environment variables)
- Terraform >= 1.6
- Ansible core >= 2.15 with the `community.docker` collection:
  ```bash
  ansible-galaxy collection install community.docker
  ```

## Deployment

### 1. Create the S3 bucket

```bash
cd terraform/s3
terraform init
terraform apply
```

S3 bucket names are global. If `tsdb-backup-da` is taken, set `bucket_name` and update
the bucket name in `terraform/ec2/instance-role.json`,
`backup_monitoring_stack/defaults/main.yml` (`rclone_s3_bucket`) and
`backup_monitoring_stack/files/backup.conf` (`S3_BUCKET`).

### 2. Generate an SSH key

Terraform registers the public half of this key as the EC2 key pair.

```bash
cd terraform/ec2
ssh-keygen -t rsa -b 4096 -m PEM -N "" -f mon_backup.pem
chmod 400 mon_backup.pem
```

### 3. Create the EC2 instance

Restrict SSH to your own IP. The default allows `0.0.0.0/0`.

```bash
terraform init
terraform apply -var 'ssh_allowed_cidrs=["203.0.113.10/32"]'
terraform output instance_public_ip
```

| Variable            | Default       | Description                         |
|---------------------|---------------|-------------------------------------|
| `aws_region`        | `eu-west-1`   | Region for the instance             |
| `name`              | `mon-backup`  | Name prefix for all resources       |
| `instance_type`     | `t3.nano`     | Instance size                       |
| `root_volume_size`  | `8`           | Root volume size in GiB             |
| `private_key_path`  | `mon_backup.pem` | SSH private key, relative to `terraform/ec2` |
| `ssh_allowed_cidrs` | `["0.0.0.0/0"]` | CIDRs allowed to reach port 22    |

> 8 GiB is very tight once Docker images (~2 GiB) and the 1 GiB swapfile are in place.
> 16–20 GiB is recommended.

### 4. Point Ansible at the instance

Copy the example inventory and set `ansible_host` to the instance's public IP
(`inventory.ini` is git-ignored so your host address is not published):

```bash
cp inventory.ini.example inventory.ini
```

```ini
[mon_backup]
mon-backup ansible_host=<instance_public_ip>
```

The instance is a persistent spot instance that stops on interruption, so its public
IP can change after a stop/start. Re-check `terraform output instance_public_ip`
before each run.

### 5. Run the playbook

```bash
ansible-playbook site.yml
```

The playbook is safe to re-run. Roles can be targeted with tags, e.g.
`--tags rclone` or `--tags systemd`.

## Accessing Grafana and Uptime Kuma

Both services listen on `127.0.0.1` only, and the security group allows SSH only.
Use an SSH tunnel:

```bash
ssh -i terraform/ec2/mon_backup.pem \
    -L 3000:localhost:3000 -L 3001:localhost:3001 \
    ubuntu@<instance_public_ip>
```

- Grafana: <http://localhost:3000> (first login `admin` / `admin`, you will be asked to change it)
- Uptime Kuma: <http://localhost:3001> (pick **SQLite** in the setup wizard; the
  instance does not have the memory for the embedded MariaDB)

## How the backup works

`ts-backup.timer` fires on the **1st of every month at 00:00 UTC** (plus a random
delay of up to 1 hour). `Persistent=true` means a run missed while the instance was
stopped happens at the next boot.

For each entry in `BACKUP_SOURCES` (`backup.conf`), `ts-backup.sh`:

1. Checks there is free space for 1.5× the source size in the staging directory.
2. Stops the matching Compose stack so the SQLite databases are consistent.
3. Creates `<hostname>_<dir>_<timestamp>.tar.gz` in `/var/ts-backup/staging/`
   (excluding `*.log` and `*.tmp`) plus a `.sha256` checksum.
4. Starts the stack again. An exit trap restarts any stack left stopped if the
   script fails part-way.
5. Copies the staging directory to
   `s3://tsdb-backup-da/backups/<hostname>/` with `rclone`, storage class `GLACIER_IR`.

It then prunes old local files and logs. Logs are written to
`/var/log/ts-backup/<hostname>/backup-YYYY-MM.log` and to the journal.

The containers run as the `noto` user (the same user the backup service runs as), and
their data lives in bind mounts inside the backed-up directories:

| Stack       | Directory             | Data                         |
|-------------|-----------------------|------------------------------|
| Uptime Kuma | `/opt/kumacompose`    | `./data` → `/app/data`       |
| Grafana     | `/opt/grafanacompose` | `./data` → `/var/lib/grafana`|

### Retention

| Location | Rule | Effect |
|---|---|---|
| Local archives (`/var/ts-backup/staging`) | Files older than `KEEP_LOCAL_ARCHIVES` (3) **days** are deleted at the end of each run | Only the latest backup is kept locally; it is removed by the next monthly run |
| Local logs | `*.log` older than `MAX_LOG_DAYS` (90) days are deleted at the end of each run | About 3 months of logs |
| S3 `backups/` | Lifecycle expiration after 365 days | About 12 monthly backups per stack |
| S3 multipart uploads | Aborted after 7 days | Cleans up failed partial uploads |

The instance role can list, read and write under `backups/` but has **no delete
permission**. Expiry in S3 is handled only by the lifecycle rule.

## Operations

Run a backup now:

```bash
sudo systemctl start ts-backup.service
journalctl -u ts-backup.service -f
```

Dry run (stops/starts the stacks and creates local archives, but skips the upload):

```bash
cd / && sudo -u noto /opt/tsdb-backup/ts-backup.sh --dry-run
```

Check the schedule:

```bash
systemctl list-timers ts-backup.timer
```

### Restoring a backup

```bash
export RCLONE_CONFIG=/etc/rclone/rclone.conf
REMOTE="s3-deep-archive:tsdb-backup-da/backups/$(hostname -f)"

# 1. Find and download the archive
sudo -E rclone lsf "$REMOTE/"
sudo -E rclone copy "$REMOTE/<archive>.tar.gz" /tmp/restore/
sudo -E rclone copy "$REMOTE/<archive>.tar.gz.sha256" /tmp/restore/

# 2. Verify the checksum (the .sha256 file stores the original staging path)
cd /tmp/restore && sha256sum <archive>.tar.gz && cat <archive>.tar.gz.sha256

# 3. Stop the stack, restore, start it again (example: Grafana)
sudo docker compose -f /opt/grafanacompose/compose.yaml down
sudo mv /opt/grafanacompose /opt/grafanacompose.old
sudo tar -xzf /tmp/restore/<archive>.tar.gz -C /opt
sudo docker compose -f /opt/grafanacompose/compose.yaml up -d
```

Glacier Instant Retrieval objects can be read immediately; no restore request is needed.

## Configuration

| File | Key settings |
|---|---|
| `backup_monitoring_stack/files/backup.conf` | `BACKUP_SOURCES`, `DOCKER_COMPOSE_MAP`, `KEEP_LOCAL_ARCHIVES`, `MAX_LOG_DAYS`, `S3_STORAGE_CLASS`, optional `HEARTBEAT_URL` |
| `backup_monitoring_stack/defaults/main.yml` | `noto_user`, directories, `rclone_remote`, `rclone_s3_bucket`, `ts_backup_schedule` (systemd `OnCalendar`, default `monthly`) |
| `monitoring_apps/defaults/main.yml` | Image tags, ports, `apps_bind_address` |
| `docker_engine/defaults/main.yml` | `swapfile_path`, `swapfile_size`, Docker packages |
| `terraform/s3/variables.tf` | `bucket_name`, `retention_days`, `kms_key_arn` |

Set `HEARTBEAT_URL` (e.g. a [Healthchecks.io](https://healthchecks.io) check URL) to be
alerted when a backup fails or does not run. Without it, failures are only visible
in the log and as a failed `ts-backup.service` unit.

The rclone remote is named `s3-deep-archive` for historical reasons; uploads use
`GLACIER_IR`. To switch to Deep Archive, change `S3_STORAGE_CLASS` in `backup.conf`
and `storage_class` in `rclone.conf`, and note that restores then take 12–48 hours.

## Cost

Estimated yearly cost of the two storage classes considered, using the same backup
volume and schedule:

|                                   | Glacier Instant Retrieval | Glacier Deep Archive |
|-----------------------------------|--------------------------:|---------------------:|
| Storage $/GB-month                | $0.00400                  | $0.00099             |
| Minimum storage duration          | 90 days                   | 180 days             |
| Retrieval $/GB (standard)         | $0.030                    | $0.020               |
| PUT $/1,000 requests              | $0.020                    | $0.050               |
| Restore time                      | Milliseconds              | 12–48 h + restore step |
| Storage cost per year             | $2.40                     | $0.59                |
| Upload requests per year          | $0.03                     | $0.08                |
| Restore cost per year (standard)  | $0.25                     | $0.17                |
| **Total per year**                | **$2.68**                 | **$0.84**            |
| Restore all backups once          | $1.50                     | $1.00                |

Glacier Instant Retrieval costs a little more but allows immediate restores. The
EC2 instance (t3.nano spot) and its EBS volume are the main running costs.

## Security notes

- Never commit `*.pem`, `*.tfstate`, `*.tfvars` or `inventory.ini`; the included
  `.gitignore` excludes them, along with Ansible vault password files and local
  backup archives.
- The instance uses an IAM instance profile; no AWS keys are stored on the host.
  IMDSv2 is enforced.
- The EBS root volume and the S3 bucket are encrypted (SSE-S3, or SSE-KMS when
  `kms_key_arn` is set). All public access to the bucket is blocked.
- Bucket versioning is disabled, so the host could overwrite an existing backup
  object. Enable versioning (old versions then expire after 90 days via the
  lifecycle rule) or S3 Object Lock for stronger protection.
