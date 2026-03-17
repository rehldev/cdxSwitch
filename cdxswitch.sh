#!/usr/bin/env bash

# Multi-Account Switcher for Codex CLI
# Simple tool to manage and switch between multiple Codex CLI accounts

set -euo pipefail

# Configuration
readonly BACKUP_DIR="$HOME/.codex-switch-backup"
readonly SEQUENCE_FILE="$BACKUP_DIR/sequence.json"
readonly DEFAULT_KEYCHAIN_SERVICE="Codex Auth"

# Container detection
is_running_in_container() {
    if [[ -f /.dockerenv ]]; then
        return 0
    fi
    if [[ -f /proc/1/cgroup ]] && grep -q 'docker\|lxc\|containerd\|kubepods' /proc/1/cgroup 2>/dev/null; then
        return 0
    fi
    if [[ -f /proc/self/mountinfo ]] && grep -q 'docker\|overlay' /proc/self/mountinfo 2>/dev/null; then
        return 0
    fi
    if [[ -n "${CONTAINER:-}" ]] || [[ -n "${container:-}" ]]; then
        return 0
    fi
    return 1
}

# Platform detection
detect_platform() {
    case "$(uname -s)" in
        Darwin) echo "macos" ;;
        Linux)
            if [[ -n "${WSL_DISTRO_NAME:-}" ]]; then
                echo "wsl"
            else
                echo "linux"
            fi
            ;;
        *) echo "unknown" ;;
    esac
}

# Get Codex home directory
get_codex_home() {
    echo "${CODEX_HOME:-$HOME/.codex}"
}

# Get auth.json path
get_codex_auth_path() {
    echo "$(get_codex_home)/auth.json"
}

# Compute macOS keyring account key (matches Codex CLI Rust implementation)
get_keyring_account() {
    local codex_home
    codex_home=$(get_codex_home)
    if [[ -d "$codex_home" ]]; then
        codex_home=$(cd "$codex_home" && pwd -P)
    fi
    local hash
    hash=$(printf '%s' "$codex_home" | shasum -a 256 | cut -c1-16)
    echo "cli|$hash"
}

# Decode JWT payload (base64url -> JSON)
decode_jwt_payload() {
    local jwt="$1"
    local payload
    payload=$(echo "$jwt" | cut -d. -f2)
    # Add base64 padding
    local pad=$(( 4 - ${#payload} % 4 ))
    if [[ $pad -lt 4 ]]; then
        local i
        for (( i=0; i<pad; i++ )); do
            payload="${payload}="
        done
    fi
    # Replace URL-safe characters and decode
    echo "$payload" | tr '_-' '/+' | base64 -d 2>/dev/null
}

# Detect and decode hex-encoded strings from macOS Keychain
# macOS `security find-generic-password -w` can return hex when the stored
# value contains non-ASCII or was written by a Rust keyring crate.
maybe_decode_hex() {
    local input="$1"
    # Check if it looks like hex: even length, only hex chars, starts with 7b ({)
    if [[ ${#input} -ge 4 && $((${#input} % 2)) -eq 0 && "$input" =~ ^[0-9a-fA-F]+$ ]]; then
        local first_two="${input:0:2}"
        if [[ "$first_two" == "7b" || "$first_two" == "7B" ]]; then
            # Looks like hex-encoded JSON — decode it
            local decoded
            decoded=$(printf '%s' "$input" | xxd -r -p 2>/dev/null)
            if [[ $? -eq 0 ]] && echo "$decoded" | jq . >/dev/null 2>&1; then
                printf '%s' "$decoded"
                return
            fi
        fi
    fi
    # Not hex or decode failed — return as-is
    printf '%s' "$input"
}

# Basic validation that JSON is valid
validate_json() {
    local file="$1"
    if ! jq . "$file" >/dev/null 2>&1; then
        echo "Error: Invalid JSON in $file"
        return 1
    fi
}

# Email validation function
validate_email() {
    local email="$1"
    if [[ "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        return 0
    else
        return 1
    fi
}

# Account identifier validation (email or apikey-XXXX format)
validate_account_identifier() {
    local identifier="$1"
    if [[ "$identifier" =~ ^[0-9]+$ ]]; then
        return 0
    fi
    if validate_email "$identifier"; then
        return 0
    fi
    if [[ "$identifier" =~ ^apikey- ]]; then
        return 0
    fi
    return 1
}

# Account identifier resolution function
resolve_account_identifier() {
    local identifier="$1"
    if [[ "$identifier" =~ ^[0-9]+$ ]]; then
        echo "$identifier"
    else
        local account_num
        account_num=$(jq -r --arg email "$identifier" '.accounts | to_entries[] | select(.value.email == $email) | .key' "$SEQUENCE_FILE" 2>/dev/null)
        if [[ -n "$account_num" && "$account_num" != "null" ]]; then
            echo "$account_num"
        else
            echo ""
        fi
    fi
}

# Resolve a managed account number from an email address
get_account_number_by_email() {
    local email="$1"
    jq -r --arg email "$email" '.accounts | to_entries[] | select(.value.email == $email) | .key' "$SEQUENCE_FILE" 2>/dev/null
}

# Safe JSON write with validation
write_json() {
    local file="$1"
    local content="$2"
    local temp_file
    temp_file=$(mktemp "${file}.XXXXXX")

    printf '%s\n' "$content" > "$temp_file"
    if ! jq . "$temp_file" >/dev/null 2>&1; then
        rm -f "$temp_file"
        echo "Error: Generated invalid JSON"
        return 1
    fi

    mv "$temp_file" "$file"
    chmod 600 "$file"
}

# Check Bash version (3.2+ required)
check_bash_version() {
    local major minor
    major=${BASH_VERSINFO[0]:-0}
    minor=${BASH_VERSINFO[1]:-0}
    if (( major < 3 || (major == 3 && minor < 2) )); then
        echo "Error: Bash 3.2+ required (found ${BASH_VERSION:-unknown})"
        exit 1
    fi
}

# Check dependencies
check_dependencies() {
    for cmd in jq; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "Error: Required command '$cmd' not found"
            echo "Install with: apt install $cmd (Linux) or brew install $cmd (macOS)"
            exit 1
        fi
    done
}

# Setup backup directories
setup_directories() {
    mkdir -p "$BACKUP_DIR"/credentials
    chmod 700 "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"/credentials
}

# Codex CLI process detection
is_codex_running() {
    ps -eo pid,comm,args | awk '$2 == "codex" || $3 == "codex" {exit 0} END {exit 1}'
}

# Wait for Codex CLI to close (no timeout - user controlled)
wait_for_codex_close() {
    if ! is_codex_running; then
        return 0
    fi

    echo "Codex CLI is running. Please close it first."
    echo "Waiting for Codex CLI to close..."

    while is_codex_running; do
        sleep 1
    done

    echo "Codex CLI closed. Continuing..."
}

# Get current account info from auth.json
get_current_account() {
    local auth_path
    auth_path=$(get_codex_auth_path)

    if [[ ! -f "$auth_path" ]]; then
        echo "none"
        return
    fi

    if ! validate_json "$auth_path" >/dev/null 2>&1; then
        echo "none"
        return
    fi

    local auth_mode
    auth_mode=$(jq -r '.auth_mode // empty' "$auth_path" 2>/dev/null)

    case "$auth_mode" in
        chatgpt|chatgptAuthTokens)
            local id_token email
            id_token=$(jq -r '.tokens.id_token // empty' "$auth_path" 2>/dev/null)
            if [[ -n "$id_token" ]]; then
                email=$(decode_jwt_payload "$id_token" | jq -r '.email // empty' 2>/dev/null)
            fi
            echo "${email:-none}"
            ;;
        apikey)
            local key
            key=$(jq -r '.OPENAI_API_KEY // empty' "$auth_path" 2>/dev/null)
            if [[ -n "$key" && ${#key} -ge 4 ]]; then
                echo "apikey-${key: -4}"
            else
                echo "none"
            fi
            ;;
        *)
            echo "none"
            ;;
    esac
}

# Read credentials based on platform
read_credentials() {
    local platform
    platform=$(detect_platform)

    case "$platform" in
        macos)
            local keyring_account creds
            keyring_account=$(get_keyring_account)
            creds=$(security find-generic-password -s "$DEFAULT_KEYCHAIN_SERVICE" -a "$keyring_account" -w 2>/dev/null || true)
            if [[ -n "$creds" ]]; then
                maybe_decode_hex "$creds"
                return
            fi
            # Fall back to file
            local auth_path
            auth_path=$(get_codex_auth_path)
            if [[ -f "$auth_path" ]]; then
                cat "$auth_path"
            else
                echo ""
            fi
            ;;
        linux|wsl)
            local auth_path
            auth_path=$(get_codex_auth_path)
            if [[ -f "$auth_path" ]]; then
                cat "$auth_path"
            else
                echo ""
            fi
            ;;
    esac
}

# Write credentials based on platform
write_credentials() {
    local credentials="$1"
    local platform
    platform=$(detect_platform)

    case "$platform" in
        macos)
            # Write to keychain
            local keyring_account
            keyring_account=$(get_keyring_account)
            security add-generic-password -U -s "$DEFAULT_KEYCHAIN_SERVICE" -a "$keyring_account" -w "$credentials" 2>/dev/null || true
            # Also write to file for fallback
            local auth_path
            auth_path=$(get_codex_auth_path)
            mkdir -p "$(dirname "$auth_path")"
            printf '%s' "$credentials" > "$auth_path"
            chmod 600 "$auth_path"
            ;;
        linux|wsl)
            local auth_path
            auth_path=$(get_codex_auth_path)
            mkdir -p "$(dirname "$auth_path")"
            printf '%s' "$credentials" > "$auth_path"
            chmod 600 "$auth_path"
            ;;
    esac
}

# Read account credentials from backup
read_account_credentials() {
    local account_num="$1"
    local email="$2"
    local platform
    platform=$(detect_platform)

    case "$platform" in
        macos)
            local acct_creds
            acct_creds=$(security find-generic-password -s "Codex Auth-Account-${account_num}-${email}" -w 2>/dev/null || true)
            if [[ -n "$acct_creds" ]]; then
                maybe_decode_hex "$acct_creds"
            else
                echo ""
            fi
            ;;
        linux|wsl)
            local cred_file="$BACKUP_DIR/credentials/.codex-auth-${account_num}-${email}.json"
            if [[ -f "$cred_file" ]]; then
                cat "$cred_file"
            else
                echo ""
            fi
            ;;
    esac
}

# Write account credentials to backup
write_account_credentials() {
    local account_num="$1"
    local email="$2"
    local credentials="$3"
    local platform
    platform=$(detect_platform)

    case "$platform" in
        macos)
            security add-generic-password -U -s "Codex Auth-Account-${account_num}-${email}" -a "$USER" -w "$credentials" 2>/dev/null
            ;;
        linux|wsl)
            local cred_file="$BACKUP_DIR/credentials/.codex-auth-${account_num}-${email}.json"
            printf '%s' "$credentials" > "$cred_file"
            chmod 600 "$cred_file"
            ;;
    esac
}

# Initialize sequence.json if it doesn't exist
init_sequence_file() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        local init_content='{
  "activeAccountNumber": null,
  "lastUpdated": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'",
  "sequence": [],
  "accounts": {}
}'
        write_json "$SEQUENCE_FILE" "$init_content"
    fi
}

# Get next account number
get_next_account_number() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "1"
        return
    fi

    local max_num
    max_num=$(jq -r '.accounts | keys | map(tonumber) | max // 0' "$SEQUENCE_FILE")
    echo $((max_num + 1))
}

# Check if account exists by email
account_exists() {
    local email="$1"
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        return 1
    fi

    jq -e --arg email "$email" '.accounts[] | select(.email == $email)' "$SEQUENCE_FILE" >/dev/null 2>&1
}

# Add account
cmd_add_account() {
    setup_directories
    init_sequence_file

    local current_email
    current_email=$(get_current_account)

    if [[ "$current_email" == "none" ]]; then
        echo "Error: No active Codex account found. Please log in first with 'codex login'."
        exit 1
    fi

    if account_exists "$current_email"; then
        echo "Account $current_email is already managed."
        exit 0
    fi

    local account_num
    account_num=$(get_next_account_number)

    # Read current credentials
    local current_creds
    current_creds=$(read_credentials)

    if [[ -z "$current_creds" ]]; then
        echo "Error: No credentials found for current account"
        exit 1
    fi

    # Get user ID from auth.json (decode JWT to extract chatgpt_user_id)
    local user_id auth_path id_token
    auth_path=$(get_codex_auth_path)
    user_id="unknown"
    id_token=$(jq -r '.tokens.id_token // empty' "$auth_path" 2>/dev/null)
    if [[ -n "$id_token" ]]; then
        user_id=$(decode_jwt_payload "$id_token" | jq -r '."https://api.openai.com/auth".chatgpt_user_id // .sub // "unknown"' 2>/dev/null || echo "unknown")
    fi
    if [[ "$user_id" == "unknown" ]]; then
        user_id=$(jq -r '.tokens.account_id // "unknown"' "$auth_path" 2>/dev/null || echo "unknown")
    fi

    # Store backup
    write_account_credentials "$account_num" "$current_email" "$current_creds"

    # Update sequence.json
    local updated_sequence
    updated_sequence=$(jq --arg num "$account_num" --arg email "$current_email" --arg uid "$user_id" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        .accounts[$num] = {
            email: $email,
            userId: $uid,
            added: $now
        } |
        .sequence += [$num | tonumber] |
        .activeAccountNumber = ($num | tonumber) |
        .lastUpdated = $now
    ' "$SEQUENCE_FILE")

    write_json "$SEQUENCE_FILE" "$updated_sequence"

    echo "Added Account $account_num: $current_email"
}

# Remove account
cmd_remove_account() {
    if [[ $# -eq 0 ]]; then
        echo "Usage: $0 --remove-account <account_number|email>"
        exit 1
    fi

    local identifier="$1"
    local account_num

    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "Error: No accounts are managed yet"
        exit 1
    fi

    # Handle email vs numeric identifier
    if [[ "$identifier" =~ ^[0-9]+$ ]]; then
        account_num="$identifier"
    else
        if ! validate_account_identifier "$identifier"; then
            echo "Error: Invalid identifier: $identifier"
            exit 1
        fi

        account_num=$(resolve_account_identifier "$identifier")
        if [[ -z "$account_num" ]]; then
            echo "Error: No account found with identifier: $identifier"
            exit 1
        fi
    fi

    local account_info
    account_info=$(jq -r --arg num "$account_num" '.accounts[$num] // empty' "$SEQUENCE_FILE")

    if [[ -z "$account_info" ]]; then
        echo "Error: Account-$account_num does not exist"
        exit 1
    fi

    local email
    email=$(echo "$account_info" | jq -r '.email')

    local active_account
    active_account=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")

    if [[ "$active_account" == "$account_num" ]]; then
        echo "Warning: Account-$account_num ($email) is currently active"
    fi

    echo -n "Are you sure you want to permanently remove Account-$account_num ($email)? [y/N] "
    read -r confirm

    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "Cancelled"
        exit 0
    fi

    # Remove backup files
    local platform
    platform=$(detect_platform)
    case "$platform" in
        macos)
            security delete-generic-password -s "Codex Auth-Account-${account_num}-${email}" 2>/dev/null || true
            ;;
        linux|wsl)
            rm -f "$BACKUP_DIR/credentials/.codex-auth-${account_num}-${email}.json"
            ;;
    esac

    # Update sequence.json
    local updated_sequence
    updated_sequence=$(jq --arg num "$account_num" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        del(.accounts[$num]) |
        .sequence = (.sequence | map(select(. != ($num | tonumber)))) |
        .lastUpdated = $now
    ' "$SEQUENCE_FILE")

    write_json "$SEQUENCE_FILE" "$updated_sequence"

    echo "Account-$account_num ($email) has been removed"
}

# First-run setup workflow
first_run_setup() {
    local current_email
    current_email=$(get_current_account)

    if [[ "$current_email" == "none" ]]; then
        echo "No active Codex account found. Please log in first with 'codex login'."
        return 1
    fi

    echo -n "No managed accounts found. Add current account ($current_email) to managed list? [Y/n] "
    read -r response

    if [[ "$response" == "n" || "$response" == "N" ]]; then
        echo "Setup cancelled. You can run '$0 --add-account' later."
        return 1
    fi

    cmd_add_account
    return 0
}

# List accounts
cmd_list() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "No accounts are managed yet."
        first_run_setup
        exit 0
    fi

    # Get current active account from auth.json
    local current_email
    current_email=$(get_current_account)

    # Find which account number corresponds to the current email
    local active_account_num=""
    if [[ "$current_email" != "none" ]]; then
        active_account_num=$(get_account_number_by_email "$current_email")
    fi

    echo "Accounts:"
    jq -r --arg active "$active_account_num" '
        .sequence[] as $num |
        .accounts["\($num)"] |
        if "\($num)" == $active then
            "  \($num): \(.email) (active)"
        else
            "  \($num): \(.email)"
        end
    ' "$SEQUENCE_FILE"
}

# Switch to next account
cmd_switch() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "Error: No accounts are managed yet"
        exit 1
    fi

    local current_email
    current_email=$(get_current_account)

    if [[ "$current_email" == "none" ]]; then
        echo "Error: No active Codex account found"
        exit 1
    fi

    # Check if current account is managed
    if ! account_exists "$current_email"; then
        echo "Notice: Active account '$current_email' was not managed."
        cmd_add_account
        local account_num
        account_num=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
        echo "It has been automatically added as Account-$account_num."
        echo "Please run './cdxswitch.sh --switch' again to switch to the next account."
        exit 0
    fi

    wait_for_codex_close

    local active_account sequence
    active_account=$(get_account_number_by_email "$current_email")
    sequence=($(jq -r '.sequence[]' "$SEQUENCE_FILE"))

    # Find next account in sequence
    local next_account current_index=0
    for i in "${!sequence[@]}"; do
        if [[ "${sequence[i]}" == "$active_account" ]]; then
            current_index=$i
            break
        fi
    done

    next_account="${sequence[$(((current_index + 1) % ${#sequence[@]}))]}"

    perform_switch "$next_account"
}

# Switch to specific account
cmd_switch_to() {
    if [[ $# -eq 0 ]]; then
        echo "Usage: $0 --switch-to <account_number|email>"
        exit 1
    fi

    local identifier="$1"
    local target_account

    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "Error: No accounts are managed yet"
        exit 1
    fi

    # Handle email vs numeric identifier
    if [[ "$identifier" =~ ^[0-9]+$ ]]; then
        target_account="$identifier"
    else
        if ! validate_account_identifier "$identifier"; then
            echo "Error: Invalid identifier: $identifier"
            exit 1
        fi

        target_account=$(resolve_account_identifier "$identifier")
        if [[ -z "$target_account" ]]; then
            echo "Error: No account found with identifier: $identifier"
            exit 1
        fi
    fi

    local account_info
    account_info=$(jq -r --arg num "$target_account" '.accounts[$num] // empty' "$SEQUENCE_FILE")

    if [[ -z "$account_info" ]]; then
        echo "Error: Account-$target_account does not exist"
        exit 1
    fi

    wait_for_codex_close
    perform_switch "$target_account"
}

# Perform the actual account switch
perform_switch() {
    local target_account="$1"

    # Get current and target account info
    local current_account target_email current_email
    current_email=$(get_current_account)
    current_account=$(get_account_number_by_email "$current_email")
    target_email=$(jq -r --arg num "$target_account" '.accounts[$num].email' "$SEQUENCE_FILE")

    if [[ -z "$current_account" || "$current_account" == "null" ]]; then
        echo "Error: Current account '$current_email' is not managed. Add it first with --add-account."
        exit 1
    fi

    # Step 1: Backup current account credentials
    local current_creds
    current_creds=$(read_credentials)

    if [[ -z "$current_creds" ]]; then
        echo "Error: Unable to read credentials for current account ($current_email)"
        exit 1
    fi

    write_account_credentials "$current_account" "$current_email" "$current_creds"

    # Step 2: Retrieve target account credentials
    local target_creds
    target_creds=$(read_account_credentials "$target_account" "$target_email")

    if [[ -z "$target_creds" ]]; then
        echo "Error: Missing backup data for Account-$target_account"
        exit 1
    fi

    # Step 3: Activate target account
    write_credentials "$target_creds"

    # Step 4: Update state
    local updated_sequence
    updated_sequence=$(jq --arg num "$target_account" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        .activeAccountNumber = ($num | tonumber) |
        .lastUpdated = $now
    ' "$SEQUENCE_FILE")

    write_json "$SEQUENCE_FILE" "$updated_sequence"

    echo "Switched to Account-$target_account ($target_email)"
    # Display updated account list
    cmd_list
    echo ""
    echo "Please restart Codex CLI to use the new authentication."
    echo ""

}

# Show usage
show_usage() {
    echo "Multi-Account Switcher for Codex CLI"
    echo "Usage: $0 [COMMAND]"
    echo ""
    echo "Commands:"
    echo "  --add-account                    Add current account to managed accounts"
    echo "  --remove-account <num|email>    Remove account by number or email"
    echo "  --list                           List all managed accounts"
    echo "  --switch                         Rotate to next account in sequence"
    echo "  --switch-to <num|email>          Switch to specific account number or email"
    echo "  --help                           Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 --add-account"
    echo "  $0 --list"
    echo "  $0 --switch"
    echo "  $0 --switch-to 2"
    echo "  $0 --switch-to user@example.com"
    echo "  $0 --remove-account user@example.com"
}

# Main script logic
main() {
    # Basic checks - allow root execution in containers
    if [[ $EUID -eq 0 ]] && ! is_running_in_container; then
        echo "Error: Do not run this script as root (unless running in a container)"
        exit 1
    fi

    check_bash_version
    check_dependencies

    case "${1:-}" in
        --add-account)
            cmd_add_account
            ;;
        --remove-account)
            shift
            cmd_remove_account "$@"
            ;;
        --list)
            cmd_list
            ;;
        --switch)
            cmd_switch
            ;;
        --switch-to)
            shift
            cmd_switch_to "$@"
            ;;
        --help)
            show_usage
            ;;
        "")
            show_usage
            ;;
        *)
            echo "Error: Unknown command '$1'"
            show_usage
            exit 1
            ;;
    esac
}

# Check if script is being sourced or executed
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
