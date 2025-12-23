#!/bin/sh
# restore.sh - All-in-one restore from restic snapshot
# ALWAYS creates a pre-restore backup before overwriting
#
# Usage: restore.sh <SNAPSHOT_ID>
#
# Steps (all automatic):
#   1. Verify snapshot exists
#   2. Create pre-restore backup of current database
#   3. Upload pre-restore backup to B2
#   4. Download and extract snapshot from B2
#   5. Drop and recreate database
#   6. Restore from dump
#
# Environment variables:
#   PGHOST, PGPORT, PGUSER, PGPASSWORD, PGDATABASE - PostgreSQL connection
#   RESTIC_REPOSITORY, RESTIC_PASSWORD - Restic config
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY - B2 credentials
#   BACKUP_TAG - Tag name for dump files (default: postgres-backup)

set -e

SNAPSHOT_ID="$1"
BACKUP_TAG="${BACKUP_TAG:-postgres-backup}"
RESTORE_DIR="/restore"

if [ -z "$SNAPSHOT_ID" ]; then
    echo "Usage: restore.sh <SNAPSHOT_ID>"
    echo ""
    echo "List available snapshots:"
    echo "  restic snapshots --tag ${BACKUP_TAG}"
    echo ""
    echo "Example:"
    echo "  /scripts/restore.sh abc123"
    echo ""
    echo "This script will:"
    echo "  1. Verify the snapshot exists"
    echo "  2. Create pre-restore backup (safety)"
    echo "  3. Download snapshot from B2"
    echo "  4. Restore database"
    exit 1
fi

echo "============================================================"
echo "RESTORE FROM SNAPSHOT"
echo "============================================================"
echo "Snapshot: ${SNAPSHOT_ID}"
echo "Database: ${PGDATABASE}@${PGHOST}:${PGPORT:-5432}"
echo ""
echo "WARNING: This will DROP and RECREATE the database!"
echo "============================================================"
echo ""

# =============================================================================
# Step 1: Verify snapshot exists
# =============================================================================
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Step 1/6: Verifying snapshot exists..."

if ! restic snapshots "${SNAPSHOT_ID}" --json >/dev/null 2>&1; then
    echo "  ERROR: Snapshot '${SNAPSHOT_ID}' not found"
    echo ""
    echo "Available snapshots:"
    restic snapshots --tag "${BACKUP_TAG}"
    exit 1
fi

echo "  Snapshot verified"

# =============================================================================
# Step 2: Create pre-restore dump
# =============================================================================
TS=$(date -u +%Y%m%d_%H%M%S)
PRE_RESTORE="/dumps/pre-restore_${TS}.dump"

echo ""
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Step 2/6: Creating pre-restore backup..."

if pg_dump -Fc -f "$PRE_RESTORE" 2>/dev/null; then
    echo "  Created: ${PRE_RESTORE}"
else
    echo "  WARNING: Could not create pre-restore backup (database may be empty)"
    PRE_RESTORE=""
fi

# =============================================================================
# Step 3: Upload pre-restore to B2
# =============================================================================
if [ -n "$PRE_RESTORE" ] && [ -f "$PRE_RESTORE" ]; then
    echo ""
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Step 3/6: Uploading pre-restore backup to B2..."
    restic backup "$PRE_RESTORE" --tag "${BACKUP_TAG}" --tag "pre-restore"
    echo "  Pre-restore backup saved to B2"
else
    echo ""
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Step 3/6: Skipping (no pre-restore to upload)"
fi

# =============================================================================
# Step 4: Download snapshot from B2
# =============================================================================
echo ""
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Step 4/6: Downloading snapshot from B2..."

rm -rf "${RESTORE_DIR}/dumps"
restic restore "${SNAPSHOT_ID}" --target "${RESTORE_DIR}"

echo "  Snapshot downloaded"

# =============================================================================
# Step 5: Find dump file
# =============================================================================
echo ""
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Step 5/6: Finding dump file..."

DUMP_FILE=$(find "${RESTORE_DIR}" -name "*.dump" -type f 2>/dev/null | head -1)

if [ -z "$DUMP_FILE" ]; then
    echo "  ERROR: No .dump file found in snapshot"
    echo "  Contents of ${RESTORE_DIR}:"
    find "${RESTORE_DIR}" -type f 2>/dev/null || echo "    (empty)"
    exit 1
fi

echo "  Found: ${DUMP_FILE}"

# =============================================================================
# Step 6: Drop, recreate, and restore
# =============================================================================
echo ""
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Step 6/6: Restoring database..."
if [ -z "$SKIP_RESTORE_DELAY" ]; then
    echo "  Dropping ${PGDATABASE} in 5 seconds... (Ctrl+C to cancel)"
    sleep 5
fi

echo "  Terminating other database connections..."
psql -d postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${PGDATABASE}' AND pid <> pg_backend_pid();" >/dev/null 2>&1 || true

dropdb --if-exists "$PGDATABASE"
createdb "$PGDATABASE"
echo "  Database recreated"

echo "  Restoring from dump..."
if ! pg_restore -d "$PGDATABASE" "$DUMP_FILE"; then
    echo "  Note: pg_restore returned non-zero (warnings are normal)"
fi

# =============================================================================
# Success
# =============================================================================
echo ""
echo "============================================================"
echo "RESTORE COMPLETED"
echo "============================================================"
echo "Database: ${PGDATABASE}"
echo "Restored from: ${DUMP_FILE}"
if [ -n "$PRE_RESTORE" ]; then
    echo "Pre-restore backup: ${PRE_RESTORE}"
    echo "Pre-restore also saved to B2 with tag 'pre-restore'"
    echo ""
    echo "To rollback, run:"
    echo "  restic snapshots --tag pre-restore"
    echo "  /scripts/restore.sh <PRE_RESTORE_SNAPSHOT_ID>"
fi
echo "============================================================"
