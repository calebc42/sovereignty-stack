#!/usr/bin/env bash
set -euo pipefail

STEP="debian-host"
JSON_PATH="sovereignty-chain.${STEP}.json"
FORCE=false

log() {
    echo "[$(date '+%H:%M:%S')] $*"
}

error() {
    echo "[ERROR] $*" >&2
    exit 1
}

remove_safely_with_confirmation() {
    local path="$1"
    local description="$2"
    
    if [[ -f "$path" ]]; then
        log "Found $description: $path"
        
        if [[ "$FORCE" == "true" ]]; then
            log "Removing $description (forced)..."
            rm -f "$path"
            log "Removed: $path"
            echo "$path"
            return 0
        else
            echo -n "Remove $description? (y/N): "
            read -r response
            if [[ "$response" =~ ^[yY] ]]; then
                rm -f "$path"
                log "Removed: $path"
                echo "$path"
                return 0
            else
                log "Skipped: $path"
                return 1
            fi
        fi
    else
        log "$description not found: $path"
        return 1
    fi
}

show_help() {
    cat << EOF
Rollback script for $STEP

Usage: $0 [-f|--force] [-h|--help]

Options:
  -f, --force    Remove files without confirmation
  -h, --help     Show this help message

This script reads sovereignty-chain.$STEP.json to determine what files to remove.
Without --force, it will ask for confirmation before removing each file.
EOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -f|--force)
            FORCE=true
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            ;;
    esac
done

# Check dependencies
if ! command -v jq >/dev/null 2>&1; then
    error "Required command not found: jq"
fi

main() {
    log "Starting rollback for step: $STEP"
    
    # Check if baton file exists
    if [[ ! -f "$JSON_PATH" ]]; then
        log "No baton file found: $JSON_PATH"
        log "Nothing to rollback - step may not have been completed"
        exit 0
    fi
    
    # Read and parse baton
    log "Reading baton file: $JSON_PATH"
    
    if ! jq -e '.artefacts' "$JSON_PATH" >/dev/null 2>&1; then
        log "No artefacts found in baton file"
        exit 0
    fi
    
    local artefact_count
    artefact_count=$(jq -r '.artefacts | keys | length' "$JSON_PATH")
    log "Found $artefact_count artefact(s) to potentially remove"
    
    # Arrays to track results
    local removed_files=()
    local skipped_files=()
    
    # Remove each artefact
    while IFS= read -r artefact_name; do
        if [[ -z "$artefact_name" ]]; then
            continue
        fi
        
        # Try different possible locations
        local found=false
        local possible_paths=("$artefact_name")
        
        # Add location from baton if available
        local baton_location
        if baton_location=$(jq -r --arg name "$artefact_name" '.artefacts[$name].location // empty' "$JSON_PATH" 2>/dev/null); then
            if [[ -n "$baton_location" ]]; then
                possible_paths+=("${baton_location}/${artefact_name}")
            fi
        fi
        
        for path in "${possible_paths[@]}"; do
            if [[ -f "$path" ]]; then
                if result=$(remove_safely_with_confirmation "$path" "ISO file"); then
                    removed_files+=("$result")
                else
                    skipped_files+=("$path")
                fi
                found=true
                break
            fi
        done
        
        if [[ "$found" == "false" ]]; then
            log "Artefact not found in any expected location: $artefact_name"
        fi
        
    done < <(jq -r '.artefacts | keys[]' "$JSON_PATH" 2>/dev/null || true)
    
    # Remove checksum files (common patterns)
    for checksum_file in "SHA256SUMS" "SHA512SUMS"; do
        if result=$(remove_safely_with_confirmation "$checksum_file" "checksum file"); then
            removed_files+=("$result")
        else
            skipped_files+=("$checksum_file")
        fi
    done
    
    # Remove the baton file itself
    if result=$(remove_safely_with_confirmation "$JSON_PATH" "baton file"); then
        removed_files+=("$result")
    else
        skipped_files+=("$JSON_PATH")
    fi
    
    # Summary
    echo
    log "Rollback completed!"
    log "Removed files: ${#removed_files[@]}"
    
    if [[ ${#removed_files[@]} -gt 0 ]]; then
        for file in "${removed_files[@]}"; do
            log "  - $file"
        done
    fi
    
    if [[ ${#skipped_files[@]} -gt 0 ]]; then
        log "Skipped files: ${#skipped_files[@]}"
        for file in "${skipped_files[@]}"; do
            log "  - $file"
        done
    fi
}

main "$@"
