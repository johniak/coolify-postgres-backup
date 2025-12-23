#!/bin/sh
# healthcheck.sh - Check if backup is healthy
#
# Checks:
#   1. Last successful backup was within BACKUP_MAX_AGE seconds (default: 2 hours)
#   2. Crond is running (checked in Dockerfile CMD)

BACKUP_MAX_AGE="${BACKUP_MAX_AGE:-7200}"  # 2 hours in seconds
LAST_BACKUP_FILE="/tmp/last_backup_success"

# First backup hasn't run yet - allow start_period to handle this
if [ ! -f "$LAST_BACKUP_FILE" ]; then
    exit 0
fi

# File contains Unix timestamp
LAST_BACKUP_TS=$(cat "$LAST_BACKUP_FILE")
NOW_TS=$(date +%s)

# Validate timestamp is a number
case "$LAST_BACKUP_TS" in
    ''|*[!0-9]*)
        echo "Invalid timestamp in $LAST_BACKUP_FILE"
        exit 1
        ;;
esac

AGE=$((NOW_TS - LAST_BACKUP_TS))

if [ "$AGE" -gt "$BACKUP_MAX_AGE" ]; then
    echo "Last backup too old: ${AGE}s ago (max: ${BACKUP_MAX_AGE}s)"
    exit 1
fi

exit 0
