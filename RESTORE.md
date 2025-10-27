# n8n Backup Restoration Guide

Restore n8n data from Git-backed SQL dumps (for DB schema, executions, credentials metadata) and JSON exports (for workflow nodes/connections). Supports full/partial rollback across environments (e.g., revert to 2025-10-27 state). Assumes Docker setup; test monthly for integrity. This process isolates backups per branch (main=prod, dev=dev) via ENV_BRANCH [web:152][web:189].

## Prerequisites
- Access to the repository: `git clone https://github.com/gajerayashvi1-droid/postgres_backup_module.git && cd postgres_backup_module`.
- Docker/n8n running (or stopped for DB restore).
- Backup artifacts: Pull latest branch, locate dated files in cron/n8n-backups/ (e.g., n8n_backup_2025-10-27.sql.gz for DB, workflows/2025-10-27/workflows_2025-10-27.json for definitions).
- Tools: postgresql-client (for psql/pg_restore if manual).
- Safety: Always backup current state before restore (run `./scripts/backup_pg.sh`) [web:191].

## Step 1: Switch to Target Branch and Pull Backup
Identify the commit/branch with desired state:
cd ~/postgres_backup_module # Or your deploy path
git checkout main # Or dev/staging; e.g., git checkout dev
git pull origin main # Fetch latest backups
git log --oneline -5 -- cron/n8n-backups/ # Find commit: e.g., "Auto backup 2025-10-27 [CI: main]"
ls cron/n8n-backups/ # List: n8n_backup_YYYY-MM-DD.sql.gz, workflows/YYYY-MM-DD/
Optional: Checkout specific: git checkout <commit-hash> -- cron/n8n-backups/
Verify files: `gunzip -c cron/n8n-backups/n8n_backup_YYYY-MM-DD.sql.gz | head -20` (SQL header); `cat cron/n8n-backups/workflows/YYYY-MM-DD/workflows_*.json | jq .length` (workflow count) [web:152].

## Step 2: Backup Current State (Pre-Restore Safety)
Create a snapshot before overwriting:
source .env && ./scripts/backup_pg.sh # Generates new n8n_backup_*.sql.gz and JSON
Commit if needed: `git add cron/n8n-backups/ && git commit -m "Pre-restore snapshot $(date '+%Y-%m-%d %T')" && git push origin $ENV_BRANCH` [web:176].

## Step 3: Restore PostgreSQL Database (Schema, Executions, Creds Metadata)
This replaces the DB (use --clean to drop old objects; stop n8n to avoid locks):
docker compose stop n8n # Stop n8n; PG remains running

Restore full dump (decompress pipe to psql; replaces n8n DB)
gunzip -c cron/n8n-backups/n8n_backup_YYYY-MM-DD.sql.gz | docker compose exec -T postgres psql -U postgres -d n8n -v ON_ERROR_STOP=1 --clean

Alternative: pg_restore for .sql (if not gz): docker compose exec -T postgres pg_restore -U postgres -d n8n --clean --verbose cron/n8n-backups/n8n_backup_YYYY-MM-DD.sql

Verify DB restore:
docker compose exec postgres psql -U postgres -d n8n -c "SELECT name FROM workflow_entity;" # Expect: Phase 1 Test (or your workflows)
docker compose exec postgres psql -U postgres -d n8n -c "SELECT COUNT(*) FROM execution_entity;" # Executions count from backup
docker compose exec postgres psql -U postgres -d n8n -c "\dt" # Tables: workflow_entity, execution_entity, credentials_entity, etc.
Restart: `docker compose start n8n` (wait 30s; UI reloads—workflows appear but may be inactive without JSON import) [web:191][web:194].

## Step 4: Restore Workflows (Nodes, Connections, Definitions)
Import JSON via UI (full/all workflows) or CLI (for automation):
- **UI Method** (Recommended; preserves UI state):
  1. Open n8n UI: http://your-server:5678 (login).
  2. Workflows > Three dots (...) > Import from File > Select cron/n8n-backups/workflows/YYYY-MM-DD/workflows_YYYY-MM-DD.json.
  3. Choose "Import All" (overwrites if names match); confirm.
  4. Workflows activate; re-link credentials if changed (UI prompt: Settings > Credentials > Reconnect) [web:152].
- **CLI Method** (Headless; mount volume first if needed):

Mount backups to n8n container (add to docker-compose.yml temp: volumes: - ./n8n-backups:/backups)
docker compose down && docker compose up -d # Remount if edited
docker compose exec n8n n8n import:workflow --input=/backups/workflows/YYYY-MM-DD/workflows_YYYY-MM-DD.json --all --overwrite

- For credentials (if exported separately; script skips for security): `docker compose exec n8n n8n import:credentials --input=creds.json --all` [web:189].

## Step 5: Full Verification and Testing
- **UI Check**: Reload http://your-server:5678; expect all workflows (e.g., 2: Phase 1 Test); run each (executions trigger as pre-backup).
- **DB Integrity**: `docker compose exec postgres psql -U postgres -d n8n -c "SELECT name, active FROM workflow_entity;"` (active=true post-import).
- **Logs**: `tail -n 20 /var/log/n8n_backup.log` (no errors); docker compose logs n8n (no import warnings).
- **Partial Rollback**: For specific workflow: Import single JSON file in UI; or SQL: `pg_restore --table=workflow_entity cron/n8n-backups/n8n_backup_*.sql`.
- **Creds Restore**: If mismatch, export from backup DB: `docker compose exec postgres pg_dump -U postgres -d n8n -t credentials_entity > creds.sql`; import separately [web:194].


