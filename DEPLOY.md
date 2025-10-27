# n8n Backup Module Deployment Guide

Self-hosted n8n with PostgreSQL backup automation via Docker, Git, and cron. Ensures daily versioning of workflows, executions, and configuration data to a private GitHub repository for rollback and multi-environment support (Dev, Staging, Production). This module prevents data loss by dumping the DB to SQL, exporting workflows via n8n API to JSON, committing to Git with branching, and pruning old files [web:191].

## Prerequisites
- Ubuntu/Debian server (root or sudo access; at least 2GB RAM, 20GB disk for volumes).
- Docker and Docker Compose installed (v20+; verify: `docker --version && docker compose version`).
- GitHub account with a private repository (e.g., postgres_backup_module.git).
- Personal Access Token (PAT) with 'repo' full scope (generate: GitHub > Settings > Developer settings > Personal access tokens > Tokens (classic) > Generate new token (classic) > Select repo scopes) [web:184].
- Domain/IP for n8n access (port 5678; optional HTTPS via reverse proxy like Nginx or Traefik).
- Basic tools: `apt update && apt install -y curl wget nano` [web:195].

## Step 1: Clone the Repository
Clone the main branch (or staging/dev for testing):
git clone https://github.com/gajerayashvi1-droid/postgres_backup_module.git
cd postgres_backup_module
git checkout main # Switch to env branch if needed: git checkout staging
Verify structure: `tree` (expect docker-compose.yml, scripts/backup_pg.sh, .env.example, etc.) [web:172].

## Step 2: Configure Environment Variables
Copy the template and edit for your setup (strong passwords; no spaces):
cp .env.example .env
nano .env # Edit below vars
Key variables:
- **Database**:
  - POSTGRES_DB=n8n  # Default DB name
  - POSTGRES_USER=postgres  # Default user
  - POSTGRES_PASSWORD=your_strong_pg_password_12_chars  # Change; used for pg_dump/restore
- **n8n**:
  - N8N_BASIC_AUTH_ACTIVE=true  # Enable basic auth
  - N8N_BASIC_AUTH_USER=admin  # Login username
  - N8N_BASIC_AUTH_PASSWORD=your_secure_n8n_pass_16_chars  # Change for prod; hashed in config
  - N8N_HOST=0.0.0.0  # Bind all interfaces
  - N8N_PORT=5678  # UI port
  - N8N_PROTOCOL=http  # http for local; https with proxy
- **Git Backup**:
  - GIT_REPO_URL=https://github.com/gajerayashvi1-droid/postgres_backup_module.git  # Your private repo
  - GIT_TOKEN=ghp_YourPATWithRepoScope  # Paste token; rotate quarterly
  - ENV_BRANCH=main  # main=prod; set dev/staging for env isolation
- **Backup Options**:
  - BACKUP_RETENTION_DAYS=7  # Prune files >7 days
Source and test: `source .env && echo $GIT_TOKEN` (should show token masked) [web:184].

## Step 3: Install Dependencies
Install required tools for backups (pg_dump for SQL, jq for JSON, git/curl for API/push):

apt update && apt install -y postgresql-client jq git curl
chmod +x scripts/backup_pg.sh # Make script executable
Test prerequisites: `./scripts/backup_pg.sh` (expect SUCCESS if .env valid; skips if no changes) [web:199].

## Step 4: Configure Git Identity (for CI Commits)
Set bot identity locally (overrides global; ensures anonymous CI pushes):
git config user.name "n8n Backup Bot"
git config user.email "bot@ai-router.local" # Or no-reply@github.com
git config --list | grep user # Verify: user.name=n8n Backup Bot

Update remote with token (if not auto): Script handles, but manual: `git remote set-url origin https://${GIT_TOKEN}@github.com/gajerayashvi1-droid/postgres_backup_module.git` [web:171].

## Step 5: Deploy Docker Containers (n8n + PostgreSQL)
Launch services with persistent volumes (postgres_data for DB, .n8n for config):
docker compose up -d # Detached; creates postgres_backup_module-postgres-1 and -n8n-1
docker compose logs -f n8n # Follow logs; expect "n8n ready on 0.0.0.0, port 5678"
docker compose ps # Both up/running

Access n8n UI: http://your-server-ip:5678 (login: admin/your_password). Create test workflow (e.g., "Phase 1 Test") [web:195].
- Volumes: Auto-created (docker volume ls | grep postgres_backup_module); data persists on restart.
- HTTPS (Prod): Set N8N_PROTOCOL=https; add proxy (e.g., docker run nginx with volumes).

## Step 6: Test Manual Backup
Run script to verify dump/export/commit/push:
source .env && ./scripts/backup_pg.sh # Dumps to cron/n8n-backups/, exports JSON, commits/pushes if changes
ls cron/n8n-backups/ # Expect n8n_backup_YYYY-MM-DD.sql.gz and workflows/YYYY-MM-DD/*.json
git log --oneline -1 # Latest: "Auto backup YYYY-MM-DD HH:MM:SS [CI: main]" by n8n Backup Bot

No changes? Rerun: Expect "No changes... Skip commit." Prune test: Touch old file > Rerun (deletes >7 days) [web:176].

## Step 7: Automate Backups (Cron on Host)
Schedule daily runs (2:30 AM IST; adjust for timezone):
crontab -e # Select nano; add line below
0 21 * * * cd /root/postgres_backup_module && source .env && ./scripts/backup_pg.sh >> /var/log/n8n_backup.log 2>&1
Create log: `touch /var/log/n8n_backup.log && chmod 644 /var/log/n8n_backup.log`.
Test cron: `run-parts /etc/cron.hourly` (or manual: `./scripts/backup_pg.sh >> /var/log/n8n_backup.log 2>&1`); monitor: `tail -f /var/log/n8n_backup.log` [web:199].
- Container Cron (Optional): Add to docker-compose.yml (cron service: image: alpine/cron, volumes: /cron:/etc/cron.d, /scripts, /n8n-backups, /var/log); use cron/n8n-backup file.

## Step 8: Multi-Environment Deployment (Dev/Staging/Prod)
Deploy isolated instances:
- Clone separate dir per env (e.g., ~/n8n-dev).
- Edit .env: ENV_BRANCH=dev (pushes to origin/dev branch).
- Deploy: docker compose up -d (different ports/volumes if same server).
- Sync: Git PR from dev > main (GitHub UI or `git push origin dev` > merge).
- Scale: Use Terraform/Ansible for cloud (AWS ECS with volumes) [web:185].

## Monitoring and Troubleshooting
- Logs: `docker compose logs postgres` (DB errors); `tail -n 50 /var/log/n8n_backup.log` (script: grep ERROR).
- Git: `git status` (clean); GitHub > Commits (bot authors, timestamps).
- Common Issues:
  - Push Fail: Regenerate GIT_TOKEN (repo scope); `git remote -v` (token embedded).
  - pg_dump Error: Reinstall postgresql-client; check POSTGRES_PASSWORD.
  - n8n API Fail: Verify N8N_BASIC_AUTH_*; curl test: `curl -u admin:pass http://localhost:5678/rest/workflows`.
  - Volume Loss: `docker volume inspect postgres_backup_module_postgres_data` (persistent).
- Security: HTTPS (N8N_SECURE_COOKIE=true); firewall (ufw allow 5678); rotate tokens/passwords quarterly [web:178].
- Updates: `git pull origin main` > docker compose down/up -d.

For restore: See RESTORE.md. Questions: Check README.md or community.n8n.io.
