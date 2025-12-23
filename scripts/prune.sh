#!/bin/sh
# prune.sh - Actually delete old snapshots and reclaim B2 storage
#
# Environment variables:
#   RESTIC_REPOSITORY, RESTIC_PASSWORD - Restic config
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY - B2 credentials
#   BACKUP_TAG - Tag for restic snapshots (default: postgres-backup)
#   SHORT_RETENTION - Hours to keep hourly snapshots (default: 72)
#   LONG_RETENTION - Hours to keep daily snapshots (default: 1440 = 60 days)

set -e

LOCK_DIR="/tmp/backup.lock"
LOCK_PID_FILE="/tmp/backup.lock/pid"
LOG_FILE="/var/log/backup.log"
BACKUP_TAG="${BACKUP_TAG:-postgres-backup}"
SHORT_RETENTION="${SHORT_RETENTION:-72}"
LONG_RETENTION="${LONG_RETENTION:-1440}"
LONG_RETENTION_DAYS=$((LONG_RETENTION / 24))
MAX_RETRIES=3
RETRY_DELAY=60

log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $1" | tee -a "$LOG_FILE"
}

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

# Cleanup function
cleanup() {
    rm -f "$LOCK_PID_FILE" 2>/dev/null
    rmdir "$LOCK_DIR" 2>/dev/null || true
}

trap cleanup EXIT

# =============================================================================
# Acquire lock (same as backup.sh - they share restic)
# =============================================================================
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    if [ -f "$LOCK_PID_FILE" ]; then
        LOCK_PID=$(cat "$LOCK_PID_FILE" 2>/dev/null)
        if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
            log "Another backup/prune is running (PID $LOCK_PID), skipping prune"
            exit 0
        fi
    fi
    log "Stale lock found, removing"
    rm -f "$LOCK_PID_FILE" 2>/dev/null
    rmdir "$LOCK_DIR" 2>/dev/null || rm -rf "$LOCK_DIR"
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        log "Failed to acquire lock, skipping prune"
        exit 0
    fi
fi

echo $$ > "$LOCK_PID_FILE"

# =============================================================================
# Prune
# =============================================================================
log "=========================================="
log "PRUNE START"
log "=========================================="
log "Repository: ${RESTIC_REPOSITORY}"
log "Tag: ${BACKUP_TAG}"
log "Retention: ${SHORT_RETENTION}h hourly, ${LONG_RETENTION_DAYS}d daily"

log "Pruning old data from B2..."
retry_restic restic forget --tag "$BACKUP_TAG" \
    --keep-hourly "$SHORT_RETENTION" \
    --keep-daily "$LONG_RETENTION_DAYS" \
    --prune

log "Current snapshots:"
restic snapshots --tag "$BACKUP_TAG" 2>&1 | tee -a "$LOG_FILE"

log "=========================================="
log "PRUNE COMPLETE"
log "=========================================="
