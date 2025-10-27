# Postgres Backup Module for n8n

Automated daily backups of n8n (PostgreSQL DB + workflow JSON via API) to Git for versioning/rollback across envs (Dev/Staging/Prod). Uses Docker, cron, and GitHub PAT.

See DEPLOY.md for setup, RESTORE.md for recovery.

## Automated Backup Versioning (CI Integration)

Implements Git CI for n8n backups across environments using token auth, branching, and non-interactive pushes.

### CI Workflow
- Branching: Script switches/creates ENV_BRANCH (e.g., main=prod).
- Operations: pg_dump to cron/n8n-backups/*.sql.gz; API export to workflows/YYYY-MM-DD/*.json; commit/push if changes (diff-index skip); prune >7 days.
- Auth: GIT_TOKEN embedded in remote.
- Retention: 7 days auto; Git history full.

### Setup for Envs
1. Clone repo.
2. .env: Set vars, ENV_BRANCH=dev.
3. git config bot identity.
4. chmod +x scripts/backup_pg.sh.
5. Cron: Daily run.
6. Docker: up -d.

### Restore
See RESTORE.md.

Best Practices: Rotate token; monitor logs; HTTPS prod.
