#!/bin/sh
# backup.sh - Complete backup: pg_dump + restic upload + retention
#
# Uses flock to prevent concurrent backups
# Includes retry logic for restic operations
#
# Environment variables:
#   PGHOST, PGPORT, PGUSER, PGPASSWORD, PGDATABASE - PostgreSQL connection
#   RESTIC_REPOSITORY, RESTIC_PASSWORD - Restic config
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY - B2 credentials
#   BACKUP_TAG - Tag name for dump files (default: postgres-backup)
#   LOCAL_DUMPS_KEEP - Number of local dumps to retain (default: 90)
#   SHORT_RETENTION - Hours to keep hourly backups (default: 72)
#   LONG_RETENTION - Hours to keep daily backups (default: 1440)
#   HEALTHCHECKS_URL - Optional healthchecks.io ping URL

set -e

LOCK_DIR="/tmp/backup.lock"
LOCK_PID_FILE="/tmp/backup.lock/pid"
LOG_FILE="/var/log/backup.log"
BACKUP_TAG="${BACKUP_TAG:-postgres-backup}"
LOCAL_DUMPS_KEEP="${LOCAL_DUMPS_KEEP:-90}"
SHORT_RETENTION="${SHORT_RETENTION:-72}"
LONG_RETENTION="${LONG_RETENTION:-1440}"
MIN_DUMP_SIZE=1024
MAX_RETRIES=3
RETRY_DELAY=30

# Logging function
log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $1" | tee -a "$LOG_FILE"
}

# Retry function for restic commands
retry_restic() {
    local attempt=1
    local cmd="$*"

    while [ $attempt -le $MAX_RETRIES ]; do
        if eval "$cmd"; then
            return 0
        fi

        if [ $attempt -lt $MAX_RETRIES ]; then
            log "  Restic failed (attempt $attempt/$MAX_RETRIES), retrying in ${RETRY_DELAY}s..."
            sleep $RETRY_DELAY
        fi
        attempt=$((attempt + 1))
    done

    log "  ERROR: Restic failed after $MAX_RETRIES attempts"
    return 1
}

# Ping healthchecks.io
ping_healthcheck() {
    local status="$1"
    if [ -n "$HEALTHCHECKS_URL" ]; then
        case "$status" in
            start)
                wget -q -O /dev/null "${HEALTHCHECKS_URL}/start" 2>/dev/null || true
                ;;
            success)
                wget -q -O /dev/null "$HEALTHCHECKS_URL" 2>/dev/null || true
                ;;
            fail)
                wget -q -O /dev/null "${HEALTHCHECKS_URL}/fail" 2>/dev/null || true
                ;;
        esac
    fi
}

# Cleanup function
cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        log "Backup failed with exit code $exit_code"
        ping_healthcheck fail
    fi
    rm -f "$LOCK_PID_FILE" 2>/dev/null
    rmdir "$LOCK_DIR" 2>/dev/null || true
}

trap cleanup EXIT

# =============================================================================
# Acquire lock (atomic mkdir)
# =============================================================================
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    # Lock exists, check if process is still running
    if [ -f "$LOCK_PID_FILE" ]; then
        LOCK_PID=$(cat "$LOCK_PID_FILE" 2>/dev/null)
        if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
            log "Another backup is running (PID $LOCK_PID), skipping"
            exit 0
        fi
    fi
    # Stale lock, remove and retry
    log "Stale lock found, removing"
    rm -f "$LOCK_PID_FILE" 2>/dev/null
    rmdir "$LOCK_DIR" 2>/dev/null || rm -rf "$LOCK_DIR"
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        log "Failed to acquire lock, skipping"
        exit 0
    fi
fi

echo $$ > "$LOCK_PID_FILE"

# =============================================================================
# Start backup
# =============================================================================
log "=========================================="
log "BACKUP START"
log "=========================================="
log "Database: ${PGDATABASE}@${PGHOST}:${PGPORT:-5432}"

ping_healthcheck start

# =============================================================================
# Step 1: PostgreSQL dump
# =============================================================================
TS=$(date -u +%Y%m%d_%H%M%S)
DUMP_FILE="/dumps/${BACKUP_TAG}_${TS}.dump"

log "Step 1/4: Creating PostgreSQL dump..."
log "  Output: ${DUMP_FILE}"

pg_dump -Fc -f "$DUMP_FILE"

# Validate dump file
DUMP_SIZE=$(stat -c%s "$DUMP_FILE" 2>/dev/null || stat -f%z "$DUMP_FILE" 2>/dev/null)
if [ "$DUMP_SIZE" -lt "$MIN_DUMP_SIZE" ]; then
    log "  ERROR: Dump file too small (${DUMP_SIZE} bytes)"
    rm -f "$DUMP_FILE"
    exit 1
fi

DUMP_SIZE_HUMAN=$(ls -lh "$DUMP_FILE" | awk '{print $5}')
log "  Dump created (${DUMP_SIZE_HUMAN})"

# =============================================================================
# Step 2: Upload to restic
# =============================================================================
log "Step 2/4: Uploading to restic..."

retry_restic restic backup "$DUMP_FILE" --tag "${BACKUP_TAG}"

log "  Upload complete"

# =============================================================================
# Step 3: Apply retention policy
# =============================================================================
log "Step 3/4: Applying retention policy..."
log "  Keep hourly: ${SHORT_RETENTION}h, Keep daily: $((LONG_RETENTION / 24))d"

retry_restic restic forget \
    --tag "${BACKUP_TAG}" \
    --keep-hourly "$SHORT_RETENTION" \
    --keep-daily "$((LONG_RETENTION / 24))"

log "  Retention policy applied"

# =============================================================================
# Step 4: Clean old local dumps
# =============================================================================
log "Step 4/4: Cleaning old local dumps..."

DUMP_COUNT=$(ls -1 /dumps/${BACKUP_TAG}_*.dump 2>/dev/null | wc -l)
if [ "$DUMP_COUNT" -gt "$LOCAL_DUMPS_KEEP" ]; then
    REMOVED=$(ls -t /dumps/${BACKUP_TAG}_*.dump | tail -n +$((LOCAL_DUMPS_KEEP + 1)) | wc -l)
    ls -t /dumps/${BACKUP_TAG}_*.dump | tail -n +$((LOCAL_DUMPS_KEEP + 1)) | xargs -r rm -f
    log "  Removed $REMOVED old dumps"
else
    log "  No cleanup needed ($DUMP_COUNT dumps)"
fi

# =============================================================================
# Success
# =============================================================================
# Update last successful backup timestamp (Unix timestamp for busybox compatibility)
date +%s > /tmp/last_backup_success

log "=========================================="
log "BACKUP COMPLETE"
log "=========================================="
log "Dump: ${DUMP_FILE}"
log "Local dumps: $(ls -1 /dumps/${BACKUP_TAG}_*.dump 2>/dev/null | wc -l)"

ping_healthcheck success
