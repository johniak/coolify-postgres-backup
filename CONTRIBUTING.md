# Contributing

Thanks for your interest in contributing to coolify-postgres-backup!

## Reporting Issues

- Check existing issues before creating a new one
- Include your environment details (Docker version, OS)
- Provide steps to reproduce the problem
- Include relevant logs from `/var/log/backup.log`

## Pull Requests

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/my-feature`)
3. Make your changes
4. Run shellcheck: `shellcheck scripts/*.sh entrypoint.sh`
5. Test with docker-compose.test.yml
6. Commit with a descriptive message
7. Push and create a Pull Request

## Code Style

- All shell scripts must pass [shellcheck](https://www.shellcheck.net/)
- Use `#!/bin/sh` for POSIX compatibility
- Add comments for complex logic
- Follow existing patterns in the codebase

## Testing

```bash
# Create test environment
cp .env.example .env
# Edit .env with your B2 credentials

# Run tests
docker compose -f docker-compose.test.yml up -d
docker compose -f docker-compose.test.yml exec backup /scripts/backup.sh
docker compose -f docker-compose.test.yml exec backup /scripts/status.sh
docker compose -f docker-compose.test.yml down -v
```

## Questions?

Open an issue with the "question" label.
