#!/usr/bin/env bash
# npm-maintenance.sh
# Toggles maintenance mode across all NPM proxy hosts via the NPM REST API

set -euo pipefail

# ============================================================
# Configuration
# ============================================================
NPM_URL="http://localhost:81"
NPM_USER="username"
NPM_PASS="password"

MAINTENANCE_HOST="maintenance"
MAINTENANCE_PORT=80
MAINTENANCE_SCHEME="http"

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
BACKUP_FILE="${SCRIPT_DIR}/proxy_backup.json"
LOG_DIR="${SCRIPT_DIR}"
LOG_OUT="${LOG_DIR}/npm-maintenance.out"
LOG_ERR="${LOG_DIR}/npm-maintenance.err"

TRIGGERED_BY="$(whoami)"

# ============================================================
# Logging
# ============================================================
log_separator() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [----]  ----------------------------------------" | tee -a "$LOG_OUT"
}

log_info() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO]  $1" | tee -a "$LOG_OUT"
}

log_warn() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN]  $1" | tee -a "$LOG_OUT" >&2
}

log_error() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1"
  echo "$msg" | tee -a "$LOG_OUT"
  echo "$msg" >> "$LOG_ERR"
}

# ============================================================
# Preflight checks
# ============================================================
preflight_checks() {
  if [ ! -d "$LOG_DIR" ]; then
    mkdir -p "$LOG_DIR"
    log_info "[PREFLIGHT] Log directory not found, created: $LOG_DIR"
  fi

  if [ ! -f "$LOG_OUT" ]; then
    touch "$LOG_OUT"
    log_info "[PREFLIGHT] Log file not found, created: $LOG_OUT"
  fi

  if [ ! -f "$LOG_ERR" ]; then
    touch "$LOG_ERR"
    log_info "[PREFLIGHT] Error log file not found, created: $LOG_ERR"
  fi

  if [ ! -f "$BACKUP_FILE" ]; then
    echo "[]" > "$BACKUP_FILE"
    log_info "[PREFLIGHT] Backup file not found, created empty: $BACKUP_FILE"
  fi
}

# ============================================================
# API helpers
# ============================================================
get_token() {
  local response
  response=$(curl -s -X POST "${NPM_URL}/api/tokens" \
    -H "Content-Type: application/json" \
    -d "{\"identity\":\"${NPM_USER}\",\"secret\":\"${NPM_PASS}\"}")

  local token
  token=$(echo "$response" | jq -r '.token // empty')

  if [ -z "$token" ]; then
    log_error "Failed to authenticate with NPM API. Check NPM_USER and NPM_PASS."
    exit 1
  fi

  echo "$token"
}

get_proxy_hosts() {
  local token="$1"
  curl -s -X GET "${NPM_URL}/api/nginx/proxy-hosts" \
    -H "Authorization: Bearer ${token}"
}

update_proxy_host() {
  local token="$1"
  local id="$2"
  local body="$3"

  curl -s -X PUT "${NPM_URL}/api/nginx/proxy-hosts/${id}" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "$body"
}

# ============================================================
# Enable maintenance
# ============================================================
enable_maintenance() {
  log_separator
  log_info "START: Enabling maintenance mode (triggered by ${TRIGGERED_BY})"

  local token
  token=$(get_token)

  local hosts
  hosts=$(get_proxy_hosts "$token")

  local total
  total=$(echo "$hosts" | jq length)

  if [ "$total" -eq 0 ]; then
    log_warn "No proxy hosts found. Nothing to do."
    log_separator
    exit 0
  fi

  # Save backup: id, forward_host, forward_port, forward_scheme
  echo "$hosts" | jq '[.[] | {id, forward_host, forward_port, forward_scheme}]' > "$BACKUP_FILE"
  log_info "Backed up $total proxy host(s) to $BACKUP_FILE"

  local success=0
  local failed=0

  for i in $(seq 0 $((total - 1))); do
    local id domain body response
    id=$(echo "$hosts" | jq -r ".[$i].id")
    domain=$(echo "$hosts" | jq -r ".[$i].domain_names[0]")

    # Build update payload from existing host, only swapping forward fields
    body=$(echo "$hosts" | jq -c \
    ".[$i] | del(.id, .created_on, .modified_on, .owner_user_id) | .forward_host = \"${MAINTENANCE_HOST}\" | .forward_port = ${MAINTENANCE_PORT} | .forward_scheme = \"${MAINTENANCE_SCHEME}\"")

    response=$(update_proxy_host "$token" "$id" "$body")

    if echo "$response" | jq -e '.id' > /dev/null 2>&1; then
      log_info "  ✓ [$((i+1))/$total] $domain (id: $id) → ${MAINTENANCE_HOST}:${MAINTENANCE_PORT}"
      success=$((success + 1))
    else
      log_error "  ✗ [$((i+1))/$total] $domain (id: $id) — API error: $(echo "$response" | jq -r '.error.message // .message // "unknown"')"
    fi
  done

  log_info "DONE: $success succeeded, $failed failed out of $total host(s)"
  log_separator
}

# ============================================================
# Disable maintenance
# ============================================================
disable_maintenance() {
  log_separator
  log_info "START: Disabling maintenance mode (triggered by ${TRIGGERED_BY})"

  local count
  count=$(jq length "$BACKUP_FILE")

  if [ "$count" -eq 0 ]; then
    log_error "Backup file exists at $BACKUP_FILE but contains no hosts. Was enable ever run? Aborting."
    log_separator
    exit 1
  fi

  local token
  token=$(get_token)

  local hosts
  hosts=$(get_proxy_hosts "$token")

  local success=0
  local failed=0

  for i in $(seq 0 $((count - 1))); do
    local id fwd_host fwd_port fwd_scheme current_host domain body response
    id=$(jq -r ".[$i].id" "$BACKUP_FILE")
    fwd_host=$(jq -r ".[$i].forward_host" "$BACKUP_FILE")
    fwd_port=$(jq -r ".[$i].forward_port" "$BACKUP_FILE")
    fwd_scheme=$(jq -r ".[$i].forward_scheme" "$BACKUP_FILE")

    # Get the current live config for this host and restore only the forward fields
    current_host=$(echo "$hosts" | jq -c ".[] | select(.id == $id)")
    domain=$(echo "$current_host" | jq -r '.domain_names[0]')

    body=$(echo "$current_host" | jq -c \
    "del(.id, .created_on, .modified_on, .owner_user_id) | .forward_host = \"${fwd_host}\" | .forward_port = ${fwd_port} | .forward_scheme = \"${fwd_scheme}\"")

    response=$(update_proxy_host "$token" "$id" "$body")

    if echo "$response" | jq -e '.id' > /dev/null 2>&1; then
      log_info "  ✓ [$((i+1))/$count] $domain (id: $id) → ${fwd_host}:${fwd_port}"
      success=$((success + 1))
    else
      log_error "  ✗ [$((i+1))/$total] $domain (id: $id) — API error: $(echo "$response" | jq -r '.error.message // .message // "unknown"')"
    fi
  done

  if [ "$failed" -eq 0 ]; then
    echo "[]" > "$BACKUP_FILE"
    log_info "Backup cleared after full successful restore"
  else
    log_warn "Backup retained at $BACKUP_FILE due to $failed failure(s)"
  fi

  log_info "DONE: $success succeeded, $failed failed out of $count host(s)"
  log_separator
}

# ============================================================
# Entry point
# ============================================================
case "$1" in
  enable)
    preflight_checks
    enable_maintenance
    ;;
  disable)
    preflight_checks
    disable_maintenance
    ;;
  *)
    log_error "Invalid or missing argument. Usage: npm-maintenance {enable|disable}"
    exit 1
    ;;
esac
