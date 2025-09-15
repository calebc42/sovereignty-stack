#!/usr/bin/env bash
# SPDX-License-Identifier: ISC
set -euo pipefail

# ---------- metadata ----------
STEP="download-host"
STEP_NUMBER="1"
SCRIPT_VERSION="1.0.0"
CHECKPOINT_FILE="${STEP}.checkpoint.json"

# ---------- constants ----------
CHECKPOINT_SCHEMA_VERSION=1

# ---------- options ----------
FORCE_MODE=false
DRY_RUN=false
VERBOSE=false

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
format_bytes() {
    local bytes="$1"
    if command -v numfmt >/dev/null 2>&1; then
        numfmt --to=iec "$bytes"
    else
        if [[ $bytes -gt 1073741824 ]]; then
            echo "$((bytes / 1073741824))G"
        elif [[ $bytes -gt 1048576 ]]; then
            echo "$((bytes / 1048576))M"
        elif [[ $bytes -gt 1024 ]]; then
            echo "$((bytes / 1024))K"
        else
            echo "${bytes}B"
        fi
    fi
}

check_dependencies() {
    local optional_missing=()
    
    if ! command -v jq >/dev/null 2>&1; then
        optional_missing+=("jq")
        log_warning "jq not found - will use fallback methods for JSON parsing"
    fi
    
    if [[ ${#optional_missing[@]} -gt 0 ]]; then
        log_verbose "Optional dependencies missing: ${optional_missing[*]}"
    fi
}

# ---------- rollback functions ----------
confirm_removal() {
    local file="$1"
    local description="$2"
    
    if [[ "$FORCE_MODE" == "true" ]]; then
        return 0
    fi
    
    echo -n "Remove $description '$file'? [y/N]: "
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
    
    # Get file size for logging
    local file_size
    file_size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null || echo "0")
    
    log "Found $description: $file ($(format_bytes "$file_size"))"
    
    if confirm_removal "$file" "$description"; then
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

load_checkpoint() {
    local checkpoint="$1"
    
    if [[ ! -f "$checkpoint" ]]; then
        return 1
    fi
    
    # Validate checkpoint if jq is available
    if command -v jq >/dev/null 2>&1; then
        if ! jq empty "$checkpoint" 2>/dev/null; then
            log_warning "Invalid JSON in checkpoint file"
            return 1
        fi
        
        # Check schema version
        local schema_version
        schema_version=$(jq -r '.schema_version // 0' "$checkpoint")
        if [[ "$schema_version" != "$CHECKPOINT_SCHEMA_VERSION" ]]; then
            log_warning "Checkpoint schema version mismatch (expected: $CHECKPOINT_SCHEMA_VERSION, found: $schema_version)"
        fi
    fi
    
    return 0
}

extract_artifacts() {
    local checkpoint="$1"
    
    if command -v jq >/dev/null 2>&1; then
        jq -r '.artifacts | keys[]' "$checkpoint" 2>/dev/null || true
    else
        # Fallback: use grep to extract artifact names
        grep -oP '"debian-[^"]*\.iso"' "$checkpoint" 2>/dev/null | tr -d '"' || true
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
                log "Dry run mode - no files will be removed"
                ;;
            -v|--verbose)
                VERBOSE=true
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
    -f, --force     Remove files without confirmation prompts
    -n, --dry-run   Show what would be removed without actually removing
    -v, --verbose   Enable verbose output
    -h, --help      Show this help message

Description:
    This script removes all artifacts created by the $STEP step.
    It reads the checkpoint file to determine what files to remove.
    
Files that will be removed:
    - Downloaded ISO file
    - Checksum files (SHA256SUMS, SHA512SUMS)
    - Signature files (*.sign)
    - Checkpoint file (${CHECKPOINT_FILE})

Safety features:
    - Confirmation prompt for each file (unless --force is used)
    - Dry run mode to preview changes
    - Only removes files, not directories
    - Validates checkpoint before processing

EOF
}

# ---------- main workflow ----------
main() {
    log "Starting rollback for $STEP"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "DRY RUN MODE - No files will actually be removed"
    fi
    
    # Check dependencies
    check_dependencies
    
    # Check if checkpoint exists
    if [[ ! -f "$CHECKPOINT_FILE" ]]; then
        log "No checkpoint file found: $CHECKPOINT_FILE"
        log "Step may not have been completed - nothing to rollback"
        
        # Still check for common files that might exist
        log "Checking for orphaned files..."
        local orphaned_found=false
        
        for pattern in "debian-*.iso" "SHA256SUMS" "SHA512SUMS" "*.sign"; do
            if ls $pattern 2>/dev/null | head -1 >/dev/null; then
                orphaned_found=true
                break
            fi
        done
        
        if [[ "$orphaned_found" == "true" ]]; then
            log_warning "Found files that might be from this step"
            log "Consider manual cleanup of:"
            ls debian-*.iso SHA*SUMS *.sign 2>/dev/null || true
        fi
        
        exit 0
    fi
    
    # Load and validate checkpoint
    log "Loading checkpoint: $CHECKPOINT_FILE"
    if ! load_checkpoint "$CHECKPOINT_FILE"; then
        log_warning "Could not validate checkpoint file"
        if [[ "$FORCE_MODE" != "true" ]]; then
            if ! confirm_removal "$CHECKPOINT_FILE" "invalid checkpoint file"; then
                error "Aborting rollback due to invalid checkpoint"
            fi
        fi
    fi
    
    # Track removal statistics
    local removed_count=0
    local skipped_count=0
    local failed_count=0
    local total_size_removed=0
    
    # Extract and remove artifacts
    log "Processing artifacts from checkpoint..."
    while IFS= read -r artifact; do
        if [[ -z "$artifact" ]]; then
            continue
        fi
        
        if [[ -f "$artifact" ]]; then
            local size_before
            size_before=$(stat -c%s "$artifact" 2>/dev/null || stat -f%z "$artifact" 2>/dev/null || echo "0")
            
            if remove_file_safely "$artifact" "ISO artifact"; then
                ((removed_count++))
                ((total_size_removed += size_before))
            else
                ((skipped_count++))
            fi
        else
            log_verbose "Artifact not found: $artifact"
        fi
    done < <(extract_artifacts "$CHECKPOINT_FILE")
    
    # Remove checksum and signature files
    log "Processing checksum and signature files..."
    for file in SHA256SUMS SHA256SUMS.sign SHA512SUMS SHA512SUMS.sign; do
        if [[ -f "$file" ]]; then
            local size_before
            size_before=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null || echo "0")
            
            if remove_file_safely "$file" "checksum/signature file"; then
                ((removed_count++))
                ((total_size_removed += size_before))
            else
                ((skipped_count++))
            fi
        fi
    done
    
    # Remove checkpoint file last
    if [[ -f "$CHECKPOINT_FILE" ]]; then
        if remove_file_safely "$CHECKPOINT_FILE" "checkpoint file"; then
            ((removed_count++))
        else
            ((skipped_count++))
        fi
    fi
    
    # Summary
    echo
    log_success "Rollback completed"
    log "Files removed: $removed_count"
    log "Files skipped: $skipped_count"
    if [[ $failed_count -gt 0 ]]; then
        log_warning "Files failed: $failed_count"
    fi
    if [[ $removed_count -gt 0 ]]; then
        log "Total space freed: $(format_bytes "$total_size_removed")"
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "This was a dry run - no files were actually removed"
    fi
}

# ---------- execute ----------
parse_arguments "$@"
main
exit 0
