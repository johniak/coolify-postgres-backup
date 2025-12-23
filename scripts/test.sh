#!/bin/sh
# test.sh - Integration test for backup and restore
#
# Test flow:
# 1. Insert 100 rows -> backup1
# 2. Insert 100 more rows (200 total) -> backup2
# 3. Restore backup1
# 4. Verify only 100 rows

set -e

echo "=== INTEGRATION TEST ==="
echo ""

# Step 1: Insert initial data
echo "[1/6] Inserting initial test data (100 rows)..."
psql -c "DROP TABLE IF EXISTS test_data; CREATE TABLE test_data (id SERIAL, value TEXT);"
psql -c "INSERT INTO test_data (value) SELECT md5(random()::text) FROM generate_series(1, 100);"
COUNT1=$(psql -t -c "SELECT COUNT(*) FROM test_data;" | tr -d ' ')
echo "  Rows: $COUNT1"

# Step 2: Backup #1
echo ""
echo "[2/6] Creating backup #1..."
/scripts/backup.sh
SNAPSHOT1=$(restic snapshots --tag postgres-backup --json | jq -r '.[-1].id')
echo "  Snapshot: $SNAPSHOT1"

# Step 3: Add more data
echo ""
echo "[3/6] Adding more data (100 more rows)..."
psql -c "INSERT INTO test_data (value) SELECT md5(random()::text) FROM generate_series(1, 100);"
COUNT2=$(psql -t -c "SELECT COUNT(*) FROM test_data;" | tr -d ' ')
echo "  Rows: $COUNT2"

# Step 4: Backup #2
echo ""
echo "[4/6] Creating backup #2..."
/scripts/backup.sh
SNAPSHOT2=$(restic snapshots --tag postgres-backup --json | jq -r '.[-1].id')
echo "  Snapshot: $SNAPSHOT2"

# Step 5: Restore backup #1 (skip the 5s confirmation delay)
echo ""
echo "[5/6] Restoring backup #1 ($SNAPSHOT1)..."
SKIP_RESTORE_DELAY=1 /scripts/restore.sh "$SNAPSHOT1"

# Step 6: Verify
echo ""
echo "[6/6] Verifying restore..."
COUNT_RESTORED=$(psql -t -c "SELECT COUNT(*) FROM test_data;" | tr -d ' ')
echo "  Rows after restore: $COUNT_RESTORED"

echo ""
if [ "$COUNT_RESTORED" = "$COUNT1" ]; then
    echo "=========================================="
    echo "=== TEST PASSED ==="
    echo "=========================================="
    echo "Expected: $COUNT1 rows"
    echo "Got: $COUNT_RESTORED rows"
    exit 0
else
    echo "=========================================="
    echo "=== TEST FAILED ==="
    echo "=========================================="
    echo "Expected: $COUNT1 rows"
    echo "Got: $COUNT_RESTORED rows"
    exit 1
fi
