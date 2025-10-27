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

# Defaults (override via env or args)
DATE="${1:-$(date +%F)}"
RETENTION="${RETENTION:-7}"
BACKUP_DIR="${BACKUP_DIR:-/backups}"
N8N_URL="${N8N_URL:-http://localhost:5678}"
N8N_API_KEY="${N8N_API_KEY}"  # Preferred; fallback to basic auth
POSTGRES_HOST="${POSTGRES_HOST:-postgres}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD}"
POSTGRES_DB="${POSTGRES_DB:-n8n}"
GIT_REPO="${GIT_REPO:-origin main}"
LOG_FILE="${LOG_FILE:-/var/log/n8n_backup.log}"
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
backup_postgres() {
  local dump_file="$BACKUP_DIR/n8n_backup_$DATE.sql"
  info "Dumping PostgreSQL database to $dump_file"
  
  PGPASSWORD="$POSTGRES_PASSWORD" pg_dump \
    --host="$POSTGRES_HOST" \
    --port="$POSTGRES_PORT" \
    --username="$POSTGRES_USER" \
    --dbname="$POSTGRES_DB" \
    --format=plain \
    --verbose \
    --file="$dump_file" || error "pg_dump failed. Check credentials/host."
  
  gzip -f "$dump_file"  # Compress
  success "PostgreSQL backup completed: $dump_file.gz"
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

# Function: Commit to Git (only if changes)
git_commit() {
  local msg="Auto backup $DATE $(date '+%T')"
  
  # Add backups (ignore .env, logs)
  git add "$BACKUP_DIR" || error "Git add failed (check .gitignore)."
  
  # Check for changes
  if git diff-index --quiet HEAD -- "$BACKUP_DIR"; then
    info "No changes in backups. Skipping commit."
    return 0
  fi
  
  git commit -m "$msg" || error "Git commit failed."
  if [[ -n "$GIT_TOKEN" ]]; then
    git remote set-url origin https://$GIT_TOKEN@github.com/your_username/your_repo.git  # If token needed
  fi
  git push "$GIT_REPO" || error "Git push failed. Check token/permissions."
  
  success "Committed and pushed: $msg"
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
