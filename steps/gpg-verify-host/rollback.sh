#!/usr/bin/env bash
# SPDX-License-Identifier: ISC
set -euo pipefail

# ---------- metadata ----------
STEP="gpg-verify-host"
STEP_NUMBER="2"
SCRIPT_VERSION="1.0.0"
CHECKPOINT_FILE="${STEP}.checkpoint.json"
PREV_CHECKPOINT="download-host.checkpoint.json"

# ---------- constants ----------
CHECKPOINT_SCHEMA_VERSION=1

# GPG keys that might have been imported
DEBIAN_SIGNING_KEYS=(
    "988021A964E6EA7D"
    "DA87E80D6294BE9B"
    "42468F4009EA8AC3"
)

# ---------- options ----------
FORCE_MODE=false
DRY_RUN=false
VERBOSE=false
REMOVE_GPG_KEYS=false

# ---------- common functions ----------
log() {
    echo "[$(date '+%H:%M:%S')] [INFO] $*" >&2
}

log_warning() {
    echo "[$(date '+%H:%M:%S')] [WARNING] $*" >&2
}

log_error() {
    echo "[$(date '+%H:%M:%S')] [ERROR] $*" >&2
}

log_success() {
    echo "[$(date '+%H:%M:%S')] [SUCCESS] $*" >&2
}

log_verbose() {
    if [[ "$VERBOSE" == "true" ]]; then
        echo "[$(date '+%H:%M:%S')] [DEBUG] $*" >&2
    fi
}

error() {
    log_error "$*"
    exit 1
}

# ---------- utility functions ----------
check_dependencies() {
    local optional_missing=()
    
    if ! command -v jq >/dev/null 2>&1; then
        optional_missing+=("jq")
        log_warning "jq not found - will use fallback methods for JSON parsing"
    fi
    
    if ! command -v gpg >/dev/null 2>&1; then
        optional_missing+=("gpg")
        log_verbose "gpg not found - cannot manage GPG keys"
    fi
    
    if [[ ${#optional_missing[@]} -gt 0 ]]; then
        log_verbose "Optional dependencies missing: ${optional_missing[*]}"
    fi
}

# ---------- rollback functions ----------
confirm_action() {
    local action="$1"
    
    if [[ "$FORCE_MODE" == "true" ]]; then
        return 0
    fi
    
    echo -n "$action [y/N]: "
    read -r response
    if [[ "$response" =~ ^[yY]([eE][sS])?$ ]]; then
        return 0
    else
        return 1
    fi
}

remove_file_safely() {
    local file="$1"
    local description="$2"
    
    if [[ ! -e "$file" ]]; then
        log_verbose "$description not found: $file"
        return 1
    fi
    
    if [[ -d "$file" ]]; then
        log_warning "Skipping directory: $file"
        return 1
    fi
    
    log "Found $description: $file"
    
    if confirm_action "Remove $description '$file'?"; then
        if [[ "$DRY_RUN" == "true" ]]; then
            log "[DRY RUN] Would remove: $file"
            return 0
        else
            if rm -f "$file"; then
                log_success "Removed: $file"
                return 0
            else
                log_error "Failed to remove: $file"
                return 1
            fi
        fi
    else
        log "Skipped: $file"
        return 1
    fi
}

remove_gpg_key() {
    local key_id="$1"
    
    if ! command -v gpg >/dev/null 2>&1; then
        log_verbose "Cannot remove GPG key - gpg not installed"
        return 1
    fi
    
    # Check if key exists
    if ! gpg --list-keys "$key_id" &>/dev/null; then
        log_verbose "GPG key not in keyring: $key_id"
        return 1
    fi
    
    log "Found GPG key in keyring: $key_id"
    
    if confirm_action "Remove GPG key $key_id?"; then
        if [[ "$DRY_RUN" == "true" ]]; then
            log "[DRY RUN] Would remove GPG key: $key_id"
            return 0
        else
            if gpg --batch --yes --delete-keys "$key_id" 2>/dev/null; then
                log_success "Removed GPG key: $key_id"
                return 0
            else
                log_error "Failed to remove GPG key: $key_id"
                return 1
            fi
        fi
    else
        log "Skipped GPG key: $key_id"
        return 1
    fi
}

# ---------- argument parsing ----------
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f|--force)
                FORCE_MODE=true
                log "Force mode enabled - no confirmation prompts"
                ;;
            -n|--dry-run)
                DRY_RUN=true
                log "Dry run mode - no changes will be made"
                ;;
            -v|--verbose)
                VERBOSE=true
                ;;
            --remove-gpg-keys)
                REMOVE_GPG_KEYS=true
                log "Will attempt to remove imported GPG keys"
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                error "Unknown option: $1 (use --help for usage)"
                ;;
        esac
        shift
    done
}

show_help() {
    cat <<EOF
Rollback script for $STEP (v$SCRIPT_VERSION)

Usage: $0 [OPTIONS]

Options:
    -f, --force           Remove files without confirmation prompts
    -n, --dry-run         Show what would be removed without actually removing
    -v, --verbose         Enable verbose output
    --remove-gpg-keys     Also remove imported Debian GPG keys
    -h, --help            Show this help message

Description:
    This script removes artifacts created by the $STEP step.
    By default, it only removes the checkpoint file created by this step.
    
Files removed:
    - Checkpoint file (${CHECKPOINT_FILE})
    
Optional removals (with --remove-gpg-keys):
    - Debian CD signing GPG keys imported during verification
    
Note:
    This step does not create new files, it only verifies existing ones.
    The main artifact is the checkpoint file that records verification status.
    GPG keys are preserved by default as they may be useful for other operations.

Safety features:
    - Confirmation prompt for each action (unless --force is used)
    - Dry run mode to preview changes
    - GPG keys preserved by default

EOF
}

# ---------- main workflow ----------
main() {
    log "Starting rollback for $STEP"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "DRY RUN MODE - No changes will actually be made"
    fi
    
    # Check dependencies
    check_dependencies
    
    # Track removal statistics
    local removed_count=0
    local skipped_count=0
    local gpg_keys_removed=0
    
    # Remove checkpoint file
    if [[ -f "$CHECKPOINT_FILE" ]]; then
        if remove_file_safely "$CHECKPOINT_FILE" "checkpoint file"; then
            ((removed_count++))
        else
            ((skipped_count++))
        fi
    else
        log "No checkpoint file found: $CHECKPOINT_FILE"
        log "Step may not have been completed - nothing to rollback"
    fi
    
    # Optionally remove GPG keys
    if [[ "$REMOVE_GPG_KEYS" == "true" ]]; then
        log "Processing GPG keys..."
        
        if ! command -v gpg >/dev/null 2>&1; then
            log_warning "Cannot remove GPG keys - gpg not installed"
        else
            for key_id in "${DEBIAN_SIGNING_KEYS[@]}"; do
                if remove_gpg_key "$key_id"; then
                    ((gpg_keys_removed++))
                fi
            done
        fi
    else
        log_verbose "Preserving GPG keys (use --remove-gpg-keys to remove them)"
    fi
    
    # Summary
    echo
    log_success "Rollback completed"
    log "Files removed: $removed_count"
    log "Files skipped: $skipped_count"
    
    if [[ "$REMOVE_GPG_KEYS" == "true" ]]; then
        log "GPG keys removed: $gpg_keys_removed"
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "This was a dry run - no changes were actually made"
    fi
    
    # Note about GPG keys if not removed
    if [[ "$REMOVE_GPG_KEYS" != "true" ]] && command -v gpg >/dev/null 2>&1; then
        local keys_present=false
        for key_id in "${DEBIAN_SIGNING_KEYS[@]}"; do
            if gpg --list-keys "$key_id" &>/dev/null; then
                keys_present=true
                break
            fi
        done
        
        if [[ "$keys_present" == "true" ]]; then
            log ""
            log "Note: Debian GPG keys remain in keyring"
            log "To remove them, run: $0 --remove-gpg-keys"
        fi
    fi
}

# ---------- execute ----------
parse_arguments "$@"
main
exit 0
