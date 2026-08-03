#!/usr/bin/env bash
# npm-maintenance.sh
# Toggles maintenance mode across all NPM proxy hosts via the NPM REST API

set -euo pipefail

# ============================================================
# Configuration
# ============================================================

MAINTENANCE_HOST="maintenance"
MAINTENANCE_PORT=80
MAINTENANCE_SCHEME="http"

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
BACKUP_FILE="${SCRIPT_DIR}/proxy_backup.json"
LOG_DIR="${SCRIPT_DIR}"
LOG_OUT="${LOG_DIR}/npm-maintenance.out"
LOG_ERR="${LOG_DIR}/npm-maintenance.err"

TRIGGERED_BY="$(whoami)"

# ── Secrets ────────────────────────────────────────────────
# Set your credentials in the .secrets file, an example file is provided with this project
SECRETS_FILE="${SCRIPT_DIR}/.secrets"

if [ ! -f "$SECRETS_FILE" ]; then
    echo "[ERROR] Secrets file not found: $SECRETS_FILE" >&2
    echo "        Create it with NPM_USER, NPM_PASS, and NPM_URL defined." >&2
    exit 1
fi

# Verify no other user can read it
_perms="$(stat -c '%a' "$SECRETS_FILE")"
if [ "$_perms" != "600" ] && [ "$_perms" != "400" ]; then
    echo "[ERROR] Secrets file has unsafe permissions ($_perms). Run: chmod 600 $SECRETS_FILE" >&2
    exit 1
fi

# shellcheck source=.secrets
. "$SECRETS_FILE"

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
# Individual-host helpers
# ============================================================

# Returns the path to a per-host backup file for the select flow.
# Separate namespace from proxy_backup.json used by the bulk flow.
get_individual_backup_file() {
    local domain="$1"
    local safe
    safe=$(printf '%s' "$domain" | tr -cd '[:alnum:].-' | tr '[:upper:]' '[:lower:]')
    printf '%s/proxy_backup_single_%s.json' "$SCRIPT_DIR" "$safe"
}

# Prints a fixed-width ASCII separator (56 chars) — no tput required.
print_separator() {
    printf '%56s\n' '' | tr ' ' '='
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
# Enable maintenance — single host (select flow)
# ============================================================
enable_single_host() {
    local id="$1"
    local domain="$2"
    local host_json="$3"
    local backup_file
    backup_file=$(get_individual_backup_file "$domain")

    if [ -f "$backup_file" ]; then
        log_error "Backup already exists for $domain — is it already in maintenance?"
        log_error "  Backup: $backup_file"
        return 1
    fi

    printf '%s\n' "$host_json" > "$backup_file"

    local token body tmp http_code response
    token=$(get_token)
    body=$(printf '%s' "$host_json" | jq -c \
        "del(.id, .created_on, .modified_on, .owner_user_id)
         | .forward_host   = \"${MAINTENANCE_HOST}\"
         | .forward_port   = ${MAINTENANCE_PORT}
         | .forward_scheme = \"${MAINTENANCE_SCHEME}\"")

    tmp=$(mktemp)
    http_code=$(curl -s -o "$tmp" -w "%{http_code}" \
        -X PUT \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d "$body" \
        "${NPM_URL}/api/nginx/proxy-hosts/${id}")
    response=$(cat "$tmp"); rm -f "$tmp"

    if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
        log_info "✓ $domain (id: $id) → maintenance:${MAINTENANCE_PORT}"
        log_info "  Backup: $backup_file"
    else
        rm -f "$backup_file"
        log_error "✗ $domain (id: $id) — API error: $(printf '%s' "$response" | jq -r '.error.message // .message // "unknown"')"
        return 1
    fi
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
      log_error "  ✗ [$((i+1))/$count] $domain (id: $id) — API error: $(echo "$response" | jq -r '.error.message // .message // "unknown"')"
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
# Disable maintenance — single host  (select flow)
# ============================================================
disable_single_host() {
    local id="$1"
    local domain="$2"
    local backup_file
    backup_file=$(get_individual_backup_file "$domain")

    if [ ! -f "$backup_file" ]; then
        log_error "No individual backup found for $domain"
        log_error "  Expected: $backup_file"
        log_error "  If this host was put into maintenance via 'enable' (bulk), use 'disable' instead."
        return 1
    fi

    local backup_json fwd_host fwd_port fwd_scheme body token tmp http_code response
    backup_json=$(cat "$backup_file")
    fwd_host=$(  printf '%s' "$backup_json" | jq -r '.forward_host')
    fwd_port=$(  printf '%s' "$backup_json" | jq -r '.forward_port')
    fwd_scheme=$(printf '%s' "$backup_json" | jq -r '.forward_scheme')

    token=$(get_token)
    body=$(printf '%s' "$backup_json" | jq -c \
        "del(.id, .created_on, .modified_on, .owner_user_id)
         | .forward_host   = \"${fwd_host}\"
         | .forward_port   = ${fwd_port}
         | .forward_scheme = \"${fwd_scheme}\"")

    tmp=$(mktemp)
    http_code=$(curl -s -o "$tmp" -w "%{http_code}" \
        -X PUT \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d "$body" \
        "${NPM_URL}/api/nginx/proxy-hosts/${id}")
    response=$(cat "$tmp"); rm -f "$tmp"

    if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
        rm -f "$backup_file"
        log_info "✓ $domain (id: $id) → ${fwd_host}:${fwd_port} (restored, backup cleared)"
    else
        log_error "✗ $domain (id: $id) — HTTP $http_code: $(printf '%s' "$response" | jq -r '.error.message // .message // "unknown"')"
        return 1
    fi
}

# ============================================================
# Interactive select mode
# ============================================================
cmd_select() {
    local page_size=10
    local page=1
    local token hosts total total_pages

    token=$(get_token)
    hosts=$(get_proxy_hosts "$token")
    total=$(printf '%s' "$hosts" | jq 'length')

    if [ "$total" -eq 0 ]; then
        log_error "No proxy hosts returned from the NPM API."
        log_separator
        exit 1
    fi

    total_pages=$(( (total + page_size - 1) / page_size ))

    while true; do
        local slice_start slice_end slice_count
        slice_start=$(( (page - 1) * page_size ))
        slice_end=$(( slice_start + page_size - 1 ))
        [ "$slice_end" -ge "$total" ] && slice_end=$(( total - 1 ))
        slice_count=$(( slice_end - slice_start + 1 ))

        clear 2>/dev/null || true
        print_separator
        printf '  NPM Maintenance Manager — Select a Proxy Host\n'
        printf '  Page %d of %d  (%d total hosts)\n' "$page" "$total_pages" "$total"
        print_separator
        printf '\n'

        local i=0
        while [ "$i" -lt "$slice_count" ]; do
            local abs_idx domain fwd_host state backup_file_check
            abs_idx=$(( slice_start + i ))
            domain=$(   printf '%s' "$hosts" | jq -r ".[$abs_idx].domain_names[0]")
            fwd_host=$( printf '%s' "$hosts" | jq -r ".[$abs_idx].forward_host")
            backup_file_check=$(get_individual_backup_file "$domain")

            if [ "$fwd_host" = "$MAINTENANCE_HOST" ] || [ -f "$backup_file_check" ]; then
                state="[MAINT]"
            else
                state="[ LIVE]"
            fi

            printf '  [%2d]  %-42s %s\n' "$(( i + 1 ))" "$domain" "$state"
            i=$(( i + 1 ))
        done

        printf '\n'
        print_separator

        local nav_hint=""
        [ "$total_pages" -gt 1 ] && nav_hint="[n]ext  [p]rev  "
        printf '  %s[q]uit\n' "$nav_hint"
        print_separator
        printf '\n'
        printf 'Select a number or action: '

        local choice
        read -r choice

        case "$choice" in
            q|Q)
                log_info "Select mode exited by user."
                log_separator
                break
                ;;
            n|N)
                if [ "$page" -lt "$total_pages" ]; then
                    page=$(( page + 1 ))
                else
                    printf 'Already on the last page. Press Enter to continue.\n'
                    read -r _dummy
                fi
                continue
                ;;
            p|P)
                if [ "$page" -gt 1 ]; then
                    page=$(( page - 1 ))
                else
                    printf 'Already on the first page. Press Enter to continue.\n'
                    read -r _dummy
                fi
                continue
                ;;
            *)
                # Must be a non-empty all-digit string
                case "$choice" in
                    ''|*[!0-9]*)
                        printf 'Invalid input. Press Enter to try again.\n'
                        read -r _dummy
                        continue
                        ;;
                esac

                # Range check against current page slice
                if [ "$choice" -lt 1 ] || [ "$choice" -gt "$slice_count" ]; then
                    printf 'Number out of range for this page. Press Enter to try again.\n'
                    read -r _dummy
                    continue
                fi

                local selected_idx selected_domain selected_id selected_json selected_fwd_host current_state selected_backup
                selected_idx=$(    printf '%s' "$hosts" | jq -r "$(( slice_start + choice - 1 ))" 2>/dev/null || true)
                selected_idx=$(( slice_start + choice - 1 ))
                selected_domain=$( printf '%s' "$hosts" | jq -r ".[$selected_idx].domain_names[0]")
                selected_id=$(     printf '%s' "$hosts" | jq -r ".[$selected_idx].id")
                selected_json=$(   printf '%s' "$hosts" | jq -c ".[$selected_idx]")
                selected_fwd_host=$(printf '%s' "$hosts" | jq -r ".[$selected_idx].forward_host")
                selected_backup=$(get_individual_backup_file "$selected_domain")

                if [ "$selected_fwd_host" = "$MAINTENANCE_HOST" ] || [ -f "$selected_backup" ]; then
                    current_state="MAINTENANCE"
                else
                    current_state="LIVE"
                fi

                clear 2>/dev/null || true
                print_separator
                printf '  Host:   %s\n' "$selected_domain"
                printf '  ID:     %s\n' "$selected_id"
                printf '  Status: %s\n' "$current_state"
                print_separator
                printf '\n'

                if [ "$current_state" = "LIVE" ]; then
                    printf '  [1] Enable maintenance for this host\n'
                    printf '  [2] Cancel — return to list\n'
                    printf '\n'
                    printf 'Choice: '
                    local action
                    read -r action
                    case "$action" in
                        1)
                            printf '\n'
                            log_info "Enabling maintenance for $selected_domain (id: $selected_id)"
                            if enable_single_host "$selected_id" "$selected_domain" "$selected_json"; then
                                printf '\nDone. Press Enter to return to the list.\n'
                            else
                                printf '\nFailed — check the log for details. Press Enter to continue.\n'
                            fi
                            read -r _dummy
                            # Refresh host list so status reflects the change
                            hosts=$(get_proxy_hosts "$(get_token)")
                            ;;
                        *)
                            continue
                            ;;
                    esac

                else
                    printf '  [1] Disable maintenance for this host (restore from backup)\n'
                    printf '  [2] Cancel — return to list\n'
                    printf '\n'
                    printf 'Choice: '
                    local action
                    read -r action
                    case "$action" in
                        1)
                            printf '\n'
                            log_info "Disabling maintenance for $selected_domain (id: $selected_id)"
                            if disable_single_host "$selected_id" "$selected_domain"; then
                                printf '\nDone. Press Enter to return to the list.\n'
                            else
                                printf '\nFailed — check the log for details. Press Enter to continue.\n'
                            fi
                            read -r _dummy
                            # Refresh host list so status reflects the change
                            hosts=$(get_proxy_hosts "$(get_token)")
                            ;;
                        *)
                            continue
                            ;;
                    esac
                fi
                ;;
        esac
    done
}


# ============================================================
# Entry point
# ============================================================
preflight_checks
log_separator
log_info "npm-maintenance called with arg: '${1:-}' (triggered by ${TRIGGERED_BY})"
log_separator

case "${1:-}" in
    enable)
        enable_maintenance
        ;;
    disable)
        disable_maintenance
        ;;
    select)
        cmd_select
        ;;
    *)
        log_error "Invalid or missing argument. Usage: npm-maintenance {enable|disable|select}"
        printf 'Usage: npm-maintenance {enable|disable|select}\n' >&2
        exit 1
        ;;
esac
