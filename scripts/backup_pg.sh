#!/bin/bash

# Dynamic n8n PostgreSQL Backup and Git Versioning Script
# Usage: ./backup_pg.sh [--date YYYY-MM-DD] [--retention DAYS] [--help]
# Requires: .env with POSTGRES_PASSWORD, N8N_URL, N8N_API_KEY (or basic auth), GIT_REPO, BACKUP_DIR
# Install deps: apt install postgresql-client curl jq git

# Load environment variables from .env
set -a
if [[ -f .env ]]; then
  source .env
else
  echo "ERROR: .env file not found!" >&2
  exit 1
fi
set +a

ENV_BRANCH="${ENV_BRANCH:-main}"
info "Using branch: $ENV_BRANCH for backups."  # Assumes your info() function; replace with echo -e "\033[1;33mINFO: ...\033[0m" if not.

# Switch/Create/Pull Branch (non-interactive for CI/cron)
if ! git ls-remote --exit-code --heads origin "$ENV_BRANCH" >/dev/null 2>&1; then
  git checkout -b "$ENV_BRANCH" || { echo -e "\033[0;31mERROR: Failed to create branch $ENV_BRANCH.\033[0m" >&2; exit 1; }
  echo -e "\033[1;33mINFO: Created new env branch: $ENV_BRANCH.\033[0m"
else
  git checkout "$ENV_BRANCH" || { echo -e "\033[0;31mERROR: Failed to switch to branch $ENV_BRANCH.\033[0m" >&2; exit 1; }
  git pull origin "$ENV_BRANCH" --ff-only || { echo -e "\033[0;31mERROR: Pull failed on $ENV_BRANCH (conflicts?). Manual merge needed.\033[0m" >&2; exit 1; }
fi

# Defaults (override via env or args)
DATE="${1:-$(date +%F)}"
RETENTION="${RETENTION:-7}"
BACKUP_DIR="${BACKUP_DIR:-$(pwd)/n8n-backups}"
N8N_URL="${N8N_URL:-http://localhost:5678}"
N8N_API_KEY="${N8N_API_KEY}"  # Preferred; fallback to basic auth
POSTGRES_HOST="${POSTGRES_HOST:-postgres}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD}"
POSTGRES_DB="${POSTGRES_DB:-n8n}"
GIT_REPO="${GIT_REPO:-origin main}"
LOG_FILE="${LOG_FILE:-/var/log/n8n_backup.log}"
GIT_REPO_URL="${GIT_REPO_URL:-https://github.com/gajerayashvi1-droid/postgres_backup_module.git}"  # Dynamic repo URL
GIT_TOKEN="${GIT_TOKEN}"  # Required for private; error if empty
GIT_REPO="${GIT_REPO:-origin main}"
mkdir -p "$BACKUP_DIR/workflows/$DATE"

# Colors for logging
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function: Log messages
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

error() {
  log "${RED}ERROR: $1${NC}"
  exit 1
}

success() {
  log "${GREEN}SUCCESS: $1${NC}"
}

info() {
  log "${YELLOW}INFO: $1${NC}"
}

# Function: Check prerequisites
check_deps() {
  command -v pg_dump >/dev/null 2>&1 || error "pg_dump not found. Install postgresql-client."
  command -v curl >/dev/null 2>&1 || error "curl not found. Install curl."
  command -v jq >/dev/null 2>&1 || error "jq not found. Install jq."
  command -v git >/dev/null 2>&1 || error "Git not found. Install git."
  
  # Check Git repo
  git rev-parse --git-dir >/dev/null 2>&1 || error "Not in a Git repository. Run 'git init' first."
  
  # Check required env vars
  [[ -z "$POSTGRES_PASSWORD" ]] && error "POSTGRES_PASSWORD not set in .env."
  if [[ -n "$N8N_API_KEY" ]]; then
    [[ -z "$N8N_API_KEY" ]] && error "N8N_API_KEY not set in .env."
  else
    [[ -z "$N8N_BASIC_AUTH_USER" || -z "$N8N_BASIC_AUTH_PASSWORD" ]] && error "Set N8N_API_KEY or N8N_BASIC_AUTH_USER/PASSWORD in .env."
  fi
  
  mkdir -p "$BACKUP_DIR/workflows/$DATE"
  success "Prerequisites checked successfully."
}

# Function: Backup PostgreSQL via pg_dump
# Function: Backup PostgreSQL via pg_dump (inside container for network access)
backup_postgres() {
  local container_name="postgres_backup_module-postgres-1"  # Full Compose name; adjust if project changes
  local dump_file="$BACKUP_DIR/n8n_backup_$DATE.sql.gz"
  
  # Check container exists and running
  if ! docker ps --format "table {{.Names}}" | grep -q "$container_name"; then
    error "Container $container_name not running. Run 'docker compose up -d'."
  fi
  
  info "Dumping PostgreSQL database inside $container_name to $dump_file"
  
  # Run pg_dump in container, pipe to gzip on host
  if ! docker exec "$container_name" bash -c "PGPASSWORD='${POSTGRES_PASSWORD}' pg_dump \
    --username='${POSTGRES_USER}' \
    --dbname='${POSTGRES_DB}' \
    --format=plain \
    --verbose" | gzip > "$dump_file"; then
    error "pg_dump via docker exec failed. Check password/DB (docker logs $container_name)."
  fi
  
  # Verify output file not empty
  if [[ ! -s "$dump_file" ]]; then
    error "Backup file empty: $dump_file. Check pg_dump output (docker logs $container_name)."
  fi
  
  local size=$(stat -c%s "$dump_file" 2>/dev/null || echo 0)
  success "PostgreSQL backup completed: $dump_file (${size} bytes)"
}

# Function: Export n8n workflows via API
export_workflows() {
  local api_url="$N8N_URL/rest/workflows"
  local json_file="$BACKUP_DIR/workflows/$DATE/workflows_$DATE.json"
  local auth_header
  if [[ -n "$N8N_API_KEY" ]]; then
    auth_header="Authorization: Bearer $N8N_API_KEY"
  else
    auth_header="--user $N8N_BASIC_AUTH_USER:$N8N_BASIC_AUTH_PASSWORD"
  fi
  
  info "Exporting workflows from $api_url"
  if curl -s -X GET $auth_header \
    -H "Content-Type: application/json" \
    "$api_url" | jq -r '.' > "$json_file"; then
    local count=$(jq -r '. | length' "$json_file" 2>/dev/null || echo 0)
    if [[ $count -gt 0 ]]; then
      success "Exported $count workflows to $json_file"
    else
      info "No workflows to export (empty n8n)."
      echo "[]" > "$json_file"  # Empty array for consistency
    fi
  else
    error "Workflow export failed. Check API key/auth/URL (HTTP 401?)."
  fi
}

# Function: Commit to Git (only if changes; private repo support)
git_commit() {
  local msg="Auto backup $DATE $(date '+%T') [CI: $ENV_BRANCH]"
  local remote="origin"
  local branch="$ENV_BRANCH"  # CI: Use ENV_BRANCH (main/dev/staging/prod); set post-.env load

  # Token check (from .env)
  if [[ -z "$GIT_TOKEN" ]]; then
    error "GIT_TOKEN missing in .env. Add PAT with 'repo' scope for private repo."
  fi

  # Add changes (updated path post-refactor)
  git add n8n-backups/ || error "Git add failed (gitignore or path issue)."

  # Skip unchanged (fallback logic; updated path)
  if git diff-index --quiet HEAD -- n8n-backups/; then
    info "No changes in n8n-backups/. Skip commit."
    return 0
  fi

  git commit -m "$msg" || error "Commit failed."

  # Update remote URL with token if needed (uses GIT_REPO_URL)
  local base_url="${GIT_REPO_URL#https://}"
  local auth_url="https://${GIT_TOKEN}@${base_url}"

  if ! git remote get-url "$remote" | grep -q "$GIT_TOKEN"; then
    git remote set-url "$remote" "$auth_url" || error "Set remote URL failed."
  fi

  # Explicit push (uses $branch var; fixes 'origin main' by dynamic branch)
  git push "$remote" "$branch" || error "Push failed. Test manual: git push origin $ENV_BRANCH."

  success "Pushed to $GIT_REPO_URL ($branch): $msg"
}

# Function: Prune old backups (retention policy)
prune_backups() {
  info "Pruning backups older than $RETENTION days from $BACKUP_DIR"
  find "$BACKUP_DIR" -name "n8n_backup_*.sql.gz" -mtime +$RETENTION -delete 2>/dev/null || true
  find "$BACKUP_DIR/workflows" -mindepth 1 -maxdepth 1 -type d -mtime +$RETENTION -exec rm -rf {} + 2>/dev/null || true
  success "Pruning completed."
}

# Main execution with arg parsing
main() {
  # Parse options
  while [[ $# -gt 0 ]]; do
    case $1 in
      --date)
        DATE="$2"
        shift 2
        ;;
      --retention)
        RETENTION="$2"
        shift 2
        ;;
      --help|-h)
        echo "Usage: $0 [--date YYYY-MM-DD] [--retention DAYS]"
        echo "Defaults: Today, 7 days retention."
        echo "Env: Set in .env for DB, n8n, Git."
        exit 0
        ;;
      *)
        echo "Unknown option $1. Use --help."
        exit 1
        ;;
    esac
  done
  
  check_deps
  backup_postgres
  export_workflows
  git_commit
  prune_backups
  info "Backup cycle completed for $DATE."
}

# Run if not sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
