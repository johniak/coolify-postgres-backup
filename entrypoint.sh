#!/bin/sh
set -e

echo "=== PostgreSQL Backup Container ==="
echo ""

# =============================================================================
# Validate required environment variables
# =============================================================================
MISSING=""

[ -z "$PGHOST" ] && MISSING="$MISSING PGHOST"
[ -z "$PGUSER" ] && MISSING="$MISSING PGUSER"
[ -z "$PGPASSWORD" ] && MISSING="$MISSING PGPASSWORD"
[ -z "$PGDATABASE" ] && MISSING="$MISSING PGDATABASE"
[ -z "$RESTIC_REPOSITORY" ] && MISSING="$MISSING RESTIC_REPOSITORY"
[ -z "$RESTIC_PASSWORD" ] && MISSING="$MISSING RESTIC_PASSWORD"
[ -z "$AWS_ACCESS_KEY_ID" ] && MISSING="$MISSING AWS_ACCESS_KEY_ID"
[ -z "$AWS_SECRET_ACCESS_KEY" ] && MISSING="$MISSING AWS_SECRET_ACCESS_KEY"
[ -z "$COOLIFY_NETWORK" ] && echo "Warning: COOLIFY_NETWORK not set"

if [ -n "$MISSING" ]; then
    echo "ERROR: Missing required environment variables:"
    for var in $MISSING; do
        echo "  - $var"
    done
    echo ""
    echo "Please set these variables in Coolify or .env file"
    exit 1
fi

echo "Configuration:"
echo "  Database: ${PGDATABASE}@${PGHOST}:${PGPORT:-5432}"
echo "  Repository: ${RESTIC_REPOSITORY}"
echo "  Timezone: ${TZ:-UTC}"
echo ""

# =============================================================================
# Export environment variables to file for cron jobs
# Alpine crond does NOT pass environment variables to jobs!
# =============================================================================
echo "Exporting environment for cron..."
printenv | grep -E '^(PG|RESTIC_|AWS_|BACKUP_|LOCAL_|SHORT_|LONG_|HEALTHCHECKS_|TZ)' > /etc/environment || true

# =============================================================================
# Initialize restic repository (once)
# =============================================================================
echo "Initializing restic repository..."
if restic snapshots >/dev/null 2>&1; then
    echo "  Repository already initialized"
else
    if restic init 2>&1; then
        echo "  Repository initialized"
    else
        echo "  ERROR: Failed to initialize repository"
        exit 1
    fi
fi
echo ""

# =============================================================================
# Generate wrapper script and crontab
# =============================================================================
echo "Generating crontab..."

# Wrapper script that loads environment before running
cat > /scripts/run-with-env.sh << 'WRAPPER'
#!/bin/sh
set -a
. /etc/environment
set +a
exec "$@"
WRAPPER
chmod +x /scripts/run-with-env.sh

# Create crontab - scripts log directly to file
cat > /etc/crontabs/root << EOF
# PostgreSQL Backup Cron Jobs
# Generated at $(date -u +%Y-%m-%dT%H:%M:%SZ)

# Backup (dump + restic upload)
${SHORT_CRON:-0 * * * *} /scripts/run-with-env.sh /scripts/backup.sh

# Prune old snapshots (delete from B2)
${LONG_CRON:-0 3 * * *} /scripts/run-with-env.sh /scripts/prune.sh

# Status check (every 5 minutes)
*/5 * * * * /scripts/run-with-env.sh /scripts/status.sh >> /var/log/backup.log 2>&1

# Log rotation (keep last 10MB)
0 0 * * * tail -c 10000000 /var/log/backup.log > /var/log/backup.log.tmp && mv /var/log/backup.log.tmp /var/log/backup.log
EOF

echo "Cron schedule:"
echo "  Backup: ${SHORT_CRON:-0 * * * *}"
echo "  Prune:  ${LONG_CRON:-0 3 * * *}"
echo "  Status: */5 * * * *"
echo ""

# =============================================================================
# Create log file
# =============================================================================
touch /var/log/backup.log

# =============================================================================
# Test database connection
# =============================================================================
echo "Testing database connection..."
if pg_isready -h "$PGHOST" -p "${PGPORT:-5432}" -U "$PGUSER" > /dev/null 2>&1; then
    echo "  Database connection: OK"
else
    echo "  WARNING: Cannot connect to database (may not be ready yet)"
fi
echo ""

# =============================================================================
# Start crond
# =============================================================================
echo "Starting crond..."
exec crond -f -l 2
