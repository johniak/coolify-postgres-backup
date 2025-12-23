# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2025-12-23

### Added
- PostgreSQL backup using `pg_dump` with custom format
- Encrypted storage with Restic to Backblaze B2
- Configurable retention policy (hourly + daily snapshots)
- Built-in cron scheduler (no external configuration needed)
- Automatic retry logic for network failures
- Atomic locking to prevent concurrent backups
- Safe restore with automatic pre-restore backup
- Status command showing snapshots and backup history
- Healthchecks.io integration for monitoring
- Docker healthcheck verifying backup success
- Automatic status logging every 5 minutes

### Security
- AES-256 encryption via Restic
- Support for bucket-specific B2 application keys
