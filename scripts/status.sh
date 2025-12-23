#!/bin/sh
# status.sh - Show backup status and snapshots
#
# Usage: /scripts/status.sh

set -e

BACKUP_TAG="${BACKUP_TAG:-postgres-backup}"
LOG_FILE="/var/log/backup.log"
LAST_BACKUP_FILE="/tmp/last_backup_success"

# =============================================================================
# Helper: Format seconds to human readable
# =============================================================================
format_ago() {
    local seconds="$1"
    if [ "$seconds" -lt 60 ]; then
        echo "${seconds}s ago"
    elif [ "$seconds" -lt 3600 ]; then
        echo "$((seconds / 60))m ago"
    elif [ "$seconds" -lt 86400 ]; then
        echo "$((seconds / 3600))h ago"
    else
        echo "$((seconds / 86400))d ago"
    fi
}

# =============================================================================
# Helper: Format Unix timestamp to ISO
# =============================================================================
format_ts() {
    local ts="$1"
    date -u -d "@$ts" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
    date -u -r "$ts" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
    echo "unknown"
}

# =============================================================================
# Section 1: Status Summary
# =============================================================================
echo "============================================================"
echo "BACKUP STATUS"
echo "============================================================"

NOW=$(date +%s)

# Last successful backup
if [ -f "$LAST_BACKUP_FILE" ]; then
    LAST_TS=$(cat "$LAST_BACKUP_FILE")
    if [ -n "$LAST_TS" ]; then
        AGO=$((NOW - LAST_TS))
        # Format timestamp using date
        LAST_DATE=$(date -u -d "@$LAST_TS" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || \
                    date -u -r "$LAST_TS" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || \
                    echo "unknown")
        echo "Last successful backup: $LAST_DATE UTC ($(format_ago $AGO))"
    else
        echo "Last successful backup: (file empty)"
    fi
else
    echo "Last successful backup: (no backup yet)"
fi

# Local dumps count
LOCAL_DUMPS=$(ls -1 /dumps/${BACKUP_TAG}_*.dump 2>/dev/null | wc -l || echo 0)
echo "Local dump files:       $LOCAL_DUMPS"

# Check cron status
if pgrep -x crond >/dev/null 2>&1; then
    echo "Cron daemon:            running"
else
    echo "Cron daemon:            NOT RUNNING!"
fi

echo ""

# =============================================================================
# Section 2: Repository Stats
# =============================================================================
echo "============================================================"
echo "REPOSITORY"
echo "============================================================"
echo "Repository: ${RESTIC_REPOSITORY:-not set}"
echo ""

# Get repo stats (suppress errors if repo not accessible)
if restic stats --mode raw-data 2>/dev/null; then
    :
else
    echo "(Could not fetch repository stats)"
fi

echo ""

# =============================================================================
# Section 3: Snapshots
# =============================================================================
echo "============================================================"
echo "SNAPSHOTS IN B2"
echo "============================================================"

if restic snapshots --tag "$BACKUP_TAG" 2>/dev/null; then
    :
else
    echo "(Could not fetch snapshots)"
fi

echo ""

# =============================================================================
# Section 4: Recent Runs (from log)
# =============================================================================
echo "============================================================"
echo "RECENT RUNS (from log)"
echo "============================================================"

if [ -f "$LOG_FILE" ]; then
    echo "Date                 | Type   | Status"
    echo "---------------------|--------|--------"

    # Parse log for COMPLETE and failed entries
    grep -E "(BACKUP COMPLETE|BACKUP START|PRUNE COMPLETE|Backup failed)" "$LOG_FILE" 2>/dev/null | \
    tail -20 | \
    while read -r line; do
        # Extract timestamp
        TS=$(echo "$line" | grep -oE '\[[-0-9T:Z]+\]' | tr -d '[]')

        if echo "$line" | grep -q "BACKUP COMPLETE"; then
            echo "$TS | BACKUP | OK"
        elif echo "$line" | grep -q "PRUNE COMPLETE"; then
            echo "$TS | PRUNE  | OK"
        elif echo "$line" | grep -q "Backup failed"; then
            echo "$TS | BACKUP | FAILED"
        fi
    done | tail -10
else
    echo "(No log file found)"
fi

echo ""
echo "============================================================"
echo "Run 'tail -f /var/log/backup.log' for live logs"
echo "============================================================"
