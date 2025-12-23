# Coolify PostgreSQL Backup

[![CI](https://github.com/johniak/coolify-postgres-backup/actions/workflows/ci.yml/badge.svg)](https://github.com/johniak/coolify-postgres-backup/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Automated PostgreSQL backups using `pg_dump` + [Restic](https://restic.net/) to [Backblaze B2](https://www.backblaze.com/b2/cloud-storage.html).

Single container with built-in cron. **Zero UI configuration required** - just set environment variables.

## Features

- **Logical backups** via `pg_dump`
- **Encrypted storage** with Restic (AES-256)
- **Configurable retention**: hourly + daily snapshots
- **Safe restore**: Always creates pre-restore backup
- **Built-in cron**: No Coolify Scheduled Tasks needed
- **Monitoring**: Optional Healthchecks.io integration
- **Retry logic**: Automatic retries on network failures
- **Lock file**: Prevents concurrent backups
- **Status command**: View backup status and snapshots

## Quick Start

1. **Deploy** from Git in Coolify (Docker Compose)
2. **Set environment variables** (copy from `.env.example`)
3. **Done!** Backups start automatically

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    backup container                         │
│                                                             │
│  ┌───────────────────────────────────────────────────────┐  │
│  │                      crond                            │  │
│  │                                                       │  │
│  │  SHORT_CRON → backup.sh (dump + upload to B2)         │  │
│  │  LONG_CRON  → prune.sh (delete old backups from B2)   │  │
│  │  */5 * * *  → status.sh (log status every 5 min)      │  │
│  └───────────────────────────────────────────────────────┘  │
│                                                             │
│  Tools: postgresql-client, restic, wget                     │
└─────────────────────────────────────────────────────────────┘
         │                                    │
         │ TCP                                │ HTTPS
         ▼                                    ▼
┌─────────────────┐                  ┌─────────────────┐
│   PostgreSQL    │                  │  Backblaze B2   │
└─────────────────┘                  └─────────────────┘
```

---

## Setup

### 1. Backblaze B2

1. Create a **private bucket**
2. Note the **region** (e.g., `us-west-004`)
3. Create an **Application Key** (not master key):
   - Select your bucket
   - Read and Write access
   - Save `keyID` and `applicationKey`

### 2. Find Coolify Network

```bash
docker network ls | grep coolify
# or
docker inspect <postgres-container> | grep -A5 Networks
```

### 3. Deploy on Coolify

1. **New Resource** → Docker Compose → Public Repository
2. Enter: `https://github.com/johniak/coolify-postgres-backup.git`
3. Set **Environment Variables**:

| Variable | Example |
|----------|---------|
| `PGHOST` | `postgres` |
| `PGPORT` | `5432` |
| `PGUSER` | `postgres` |
| `PGPASSWORD` | `secret` |
| `PGDATABASE` | `myapp` |
| `RESTIC_REPOSITORY` | `s3:https://s3.us-west-004.backblazeb2.com/my-bucket` |
| `RESTIC_PASSWORD` | `encryption-password` |
| `AWS_ACCESS_KEY_ID` | `b2-key-id` |
| `AWS_SECRET_ACCESS_KEY` | `b2-app-key` |
| `AWS_DEFAULT_REGION` | `us-west-004` |
| `COOLIFY_NETWORK` | `coolify` |

4. **Deploy** - backups start automatically!

---

## Configuration

### Cron Schedules

| Variable | Default | Description |
|----------|---------|-------------|
| `SHORT_CRON` | `0 * * * *` | When to run backup (dump + upload) |
| `LONG_CRON` | `0 3 * * *` | When to prune old snapshots |
| `TZ` | `UTC` | Timezone for cron |

### Retention

| Variable | Default | Description |
|----------|---------|-------------|
| `SHORT_RETENTION` | `72` | Hours to keep hourly snapshots |
| `LONG_RETENTION` | `1440` | Hours to keep daily snapshots (1440h = 60 days) |
| `LOCAL_DUMPS_KEEP` | `90` | Number of local dump files to keep |

### Monitoring

| Variable | Default | Description |
|----------|---------|-------------|
| `HEALTHCHECKS_URL` | (empty) | Healthchecks.io ping URL (optional) |

### Example Configurations

**Every hour (default):**
```env
SHORT_CRON=0 * * * *
LONG_CRON=0 3 * * *
```

**Every 15 minutes:**
```env
SHORT_CRON=*/15 * * * *
LONG_CRON=0 3 * * *
```

**Every 6 hours:**
```env
SHORT_CRON=0 */6 * * *
LONG_CRON=0 3 * * *
```

---

## Usage

### View Logs

```bash
docker exec -it <backup-container> tail -f /var/log/backup.log
```

### List Snapshots

```bash
docker exec -it <backup-container> restic snapshots --tag postgres-backup
```

### Manual Backup

```bash
docker exec -it <backup-container> /scripts/backup.sh
```

### Status

```bash
docker exec -it <backup-container> /scripts/status.sh
```

Shows:
- Last successful backup time
- Repository stats (size, compression)
- All snapshots in B2
- Recent backup/prune runs with status

**Note:** Status is automatically logged every 5 minutes to `/var/log/backup.log`

### Restore

```bash
# 1. List snapshots
docker exec -it <backup-container> restic snapshots --tag postgres-backup

# 2. Restore (all-in-one, creates pre-restore backup first!)
docker exec -it <backup-container> /scripts/restore.sh <SNAPSHOT_ID>
```

---

## How It Works

### Backup Flow

```
Every SHORT_CRON:
  backup.sh
    ├─► pg_dump → /dumps/postgres-backup_YYYYMMDD_HHMMSS.dump
    ├─► restic backup → encrypted upload to B2
    ├─► restic forget → mark old snapshots (no delete yet)
    └─► ping healthchecks.io (if configured)

Every LONG_CRON (daily):
  prune.sh
    └─► restic forget --prune → actually delete old data from B2

Every 5 minutes:
  status.sh
    └─► log current status (snapshots, last backup, repo stats)
```

### Retention Policy

```
Time:     NOW ◄─────────────────────────────────────────── 60 DAYS AGO

SHORT_RETENTION=72 (hours)
├─────────────────────┤
│  72 hourly snapshots │  (one per hour, last 3 days)
└─────────────────────┘

LONG_RETENTION=1440 (hours = 60 days)
├─────────────────────────────────────────────────────────┤
│              60 daily snapshots                         │
└─────────────────────────────────────────────────────────┘
```

---

## Files

```
coolify-postgres-backup/
├── Dockerfile
├── entrypoint.sh
├── docker-compose.yml
├── .env.example
├── README.md
├── CONTRIBUTING.md
├── CHANGELOG.md
├── .shellcheckrc
├── .github/
│   └── workflows/
│       └── ci.yml      # GitHub Actions CI
└── scripts/
    ├── backup.sh       # Dump + upload to B2
    ├── prune.sh        # Delete old backups from B2
    ├── restore.sh      # All-in-one restore
    ├── status.sh       # Show backup status
    └── healthcheck.sh  # Docker healthcheck
```

---

## Troubleshooting

### Quick Status Check

```bash
docker exec -it <backup-container> /scripts/status.sh
```

### Check if cron is running

```bash
docker exec -it <backup-container> ps aux | grep cron
```

### Test database connection

```bash
docker exec -it <backup-container> pg_isready -h $PGHOST -p $PGPORT
```

### Test B2 connection

```bash
docker exec -it <backup-container> restic snapshots
```

### View crontab

```bash
docker exec -it <backup-container> cat /etc/crontabs/root
```

### Check last successful backup

```bash
docker exec -it <backup-container> cat /tmp/last_backup_success
```

---

## Security

- **RESTIC_PASSWORD**: Store securely! Lost = backups unusable.
- **B2 Key**: Use bucket-specific application key, not master key.
- Mark sensitive vars as "Secret" in Coolify.

## License

MIT
