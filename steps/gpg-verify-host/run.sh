#!/usr/bin/env bash
# SPDX-License-Identifier: ISC
set -euo pipefail

# ---------- metadata ----------
STEP="gpg-verify-host"
STEP_NUMBER="2"
SCRIPT_VERSION="1.0.0"
PREV_STEP="download-host"

# ---------- constants ----------
DEFAULT_CONNECT_TIMEOUT=30
CHECKPOINT_SCHEMA_VERSION=1

# Official Debian CD signing keys (verify at: https://www.debian.org/CD/verify)
DEBIAN_SIGNING_KEYS=(
    "988021A964E6EA7D"  # Debian CD signing key
    "DA87E80D6294BE9B"  # Debian CD signing key
    "42468F4009EA8AC3"  # Debian Testing CDs Automatic Signing Key
)

KEYSERVERS=(
    "keyserver.ubuntu.com"
    "keys.openpgp.org"
    "pgp.mit.edu"
)

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

error() {
    log_error "$*"
    exit 1
}

log_success() {
    echo "[$(date '+%H:%M:%S')] [SUCCESS] $*" >&2
}

# ---------- checkpoint functions ----------
checkpoint_load() {
    local checkpoint_file="$1"
    
    if [[ ! -f "$checkpoint_file" ]]; then
        error "Checkpoint file not found: $checkpoint_file"
    fi
    
    # Validate checkpoint
    if ! checkpoint_validate "$checkpoint_file"; then
        error "Invalid checkpoint file: $checkpoint_file"
    fi
    
    log "Loaded checkpoint: $checkpoint_file"
}

checkpoint_validate() {
    local checkpoint_file="$1"
    
    if [[ ! -f "$checkpoint_file" ]]; then
        return 1
    fi
    
    # Validate JSON structure
    if command -v jq >/dev/null 2>&1; then
        if ! jq empty "$checkpoint_file" 2>/dev/null; then
            log_warning "Invalid JSON in checkpoint file: $checkpoint_file"
            return 1
        fi
        
        # Check schema version
        local schema_version
        schema_version=$(jq -r '.schema_version' "$checkpoint_file")
        if [[ "$schema_version" != "$CHECKPOINT_SCHEMA_VERSION" ]]; then
            log_warning "Checkpoint schema version mismatch (expected: $CHECKPOINT_SCHEMA_VERSION, found: $schema_version)"
            return 1
        fi
    else
        # Basic validation without jq
        if ! grep -q '"schema_version"' "$checkpoint_file"; then
            log_warning "Missing schema_version in checkpoint"
            return 1
        fi
    fi
    
    return 0
}

checkpoint_save() {
    local checkpoint_file="${STEP}.checkpoint.json"
    local prev_checkpoint="$1"
    local iso_file="$2"
    local checksum_file="$3"
    local gpg_verified="$4"
    local signing_key="${5:-}"
    
    # Extract artifacts from previous checkpoint
    local artifacts_json
    if command -v jq >/dev/null 2>&1; then
        artifacts_json=$(jq '.artifacts' "$prev_checkpoint")
    else
        # Fallback: extract artifacts section manually
        artifacts_json=$(grep -A100 '"artifacts":' "$prev_checkpoint" | tail -n +2)
    fi
    
    cat > "$checkpoint_file" <<EOF
{
  "schema_version": $CHECKPOINT_SCHEMA_VERSION,
  "step": "$STEP",
  "step_number": $STEP_NUMBER,
  "script_version": "$SCRIPT_VERSION",
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "hostname": "$(hostname)",
  "previous_step": "$PREV_STEP",
  "verification": {
    "gpg_verified": $gpg_verified,
    "checksum_file": "$checksum_file",
    "signing_key": $(if [[ -n "$signing_key" ]]; then echo "\"$signing_key\""; else echo "null"; fi),
    "verified_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  },
  "artifacts": $artifacts_json
}
EOF
    
    # Update verified status in artifacts if GPG passed
    if [[ "$gpg_verified" == "true" ]] && command -v jq >/dev/null 2>&1; then
        local temp_file="${checkpoint_file}.tmp"
        jq '.artifacts[][] |= . + {verified: true}' "$checkpoint_file" > "$temp_file"
        mv "$temp_file" "$checkpoint_file"
    fi
    
    log "Checkpoint saved: $checkpoint_file"
}

# ---------- utility functions ----------
format_bytes() {
    local bytes="$1"
    if command -v numfmt >/dev/null 2>&1; then
        numfmt --to=iec "$bytes"
    else
        # Fallback for systems without numfmt
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
    local missing_deps=()
    local optional_missing=()
    
    # Required dependencies
    for cmd in sha256sum sha512sum; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_deps+=("$cmd")
        fi
    done
    
    # Optional but recommended
    if ! command -v jq >/dev/null 2>&1; then
        optional_missing+=("jq")
        log_warning "jq not found - checkpoint operations will be limited"
    fi
    
    if ! command -v gpg >/dev/null 2>&1; then
        optional_missing+=("gpg")
        log_warning "gpg not found - signature verification will not be available"
    fi
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        error "Missing required dependencies: ${missing_deps[*]}"
    fi
    
    if [[ ${#optional_missing[@]} -gt 0 ]]; then
        log_warning "Optional dependencies missing: ${optional_missing[*]}"
        log_warning "Some features may not be available"
    fi
}

# ---------- GPG functions ----------
import_gpg_keys() {
    log "Importing Debian CD signing keys..."
    
    local keys_imported=0
    local keys_failed=0
    
    for key in "${DEBIAN_SIGNING_KEYS[@]}"; do
        local key_imported=false
        
        for keyserver in "${KEYSERVERS[@]}"; do
            log "Attempting to import key $key from $keyserver..."
            
            if gpg --keyserver "$keyserver" --recv-keys "$key" 2>/dev/null; then
                log "Successfully imported key: $key"
                key_imported=true
                ((keys_imported++))
                break
            fi
        done
        
        if [[ "$key_imported" == "false" ]]; then
            log_warning "Failed to import key: $key"
            ((keys_failed++))
        fi
    done
    
    if [[ $keys_imported -eq 0 ]]; then
        error "Could not import any GPG keys. Check network connectivity and keyserver availability"
    fi
    
    log "Imported $keys_imported keys, $keys_failed failed"
    return 0
}

verify_gpg_signature() {
    local checksum_file="$1"
    local signature_file="${checksum_file}.sign"
    
    if [[ ! -f "$signature_file" ]]; then
        log_warning "Signature file not found: $signature_file"
        return 1
    fi
    
    log "Verifying GPG signature for: $checksum_file"
    
    # Capture GPG output for analysis
    local gpg_output
    gpg_output=$(gpg --verify "$signature_file" "$checksum_file" 2>&1)
    
    if echo "$gpg_output" | grep -q "Good signature"; then
        log_success "GPG signature verification PASSED"
        
        # Extract the key ID used for signing
        local key_id
        key_id=$(echo "$gpg_output" | grep -oP 'using RSA key [A-F0-9]{16,}' | awk '{print $NF}')
        
        if [[ -n "$key_id" ]]; then
            log "Signed with key: $key_id"
            echo "$key_id"
        fi
        
        return 0
    else
        log_error "GPG signature verification FAILED"
        echo "$gpg_output" | grep -E "(Bad signature|No public key)" | while read -r line; do
            log_error "  $line"
        done
        return 1
    fi
}

# ---------- argument parsing ----------
parse_arguments() {
    SKIP_GPG=false
    FORCE_VERIFY=false
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-gpg|--skip-gpg)
                SKIP_GPG=true
                log_warning "GPG verification will be skipped (--no-gpg flag)"
                ;;
            --force)
                FORCE_VERIFY=true
                log "Force mode enabled - will attempt verification even with warnings"
                ;;
            --help|-h)
                cat <<EOF
Usage: $0 [OPTIONS]

Options:
    --no-gpg, --skip-gpg    Skip GPG signature verification
    --force                 Continue even if some verifications fail
    --help, -h              Show this help message

This script verifies the GPG signature of the Debian ISO downloaded in the
previous step. It requires the checkpoint file from the download-host step.

EOF
                exit 0
                ;;
            *)
                log_warning "Unknown argument: $1"
                ;;
        esac
        shift
    done
}

# ---------- main workflow ----------
main() {
    log "Starting $STEP (v$SCRIPT_VERSION)"
    log "Working directory: $(pwd)"
    
    # Parse command-line arguments
    parse_arguments "$@"
    
    # Check dependencies
    check_dependencies
    
    # Load previous checkpoint
    local prev_checkpoint="${PREV_STEP}.checkpoint.json"
    checkpoint_load "$prev_checkpoint"
    
    # Extract ISO filename from previous checkpoint
    local iso_file
    if command -v jq >/dev/null 2>&1; then
        iso_file=$(jq -r '.artifacts | keys[0]' "$prev_checkpoint")
    else
        # Fallback: grep for ISO filename
        iso_file=$(grep -oP '"debian-[^"]*\.iso"' "$prev_checkpoint" | head -1 | tr -d '"')
    fi
    
    if [[ -z "$iso_file" ]]; then
        error "Could not find ISO filename in previous checkpoint"
    fi
    
    log "ISO to verify: $iso_file"
    
    # Verify required files exist
    if [[ ! -f "$iso_file" ]]; then
        error "ISO file not found: $iso_file"
    fi
    
    # Determine which checksum file we have
    local checksum_file=""
    if [[ -f "SHA512SUMS" ]]; then
        checksum_file="SHA512SUMS"
    elif [[ -f "SHA256SUMS" ]]; then
        checksum_file="SHA256SUMS"
    else
        error "No checksum files found (need SHA512SUMS or SHA256SUMS)"
    fi
    
    log "Using checksum file: $checksum_file"
    
    # GPG verification
    local gpg_verified="false"
    local signing_key=""
    
    if [[ "$SKIP_GPG" == "false" ]]; then
        if ! command -v gpg >/dev/null 2>&1; then
            log_error "GPG is not installed but is required for signature verification"
            log "Install GPG with:"
            log "  Ubuntu/Debian: sudo apt-get install gnupg"
            log "  RHEL/Fedora: sudo dnf install gnupg2"
            log "  macOS: brew install gnupg"
            log "Or use --no-gpg flag to skip verification"
            
            if [[ "$FORCE_VERIFY" == "false" ]]; then
                error "Cannot proceed without GPG"
            fi
        else
            # Import keys and verify
            if import_gpg_keys; then
                if signing_key=$(verify_gpg_signature "$checksum_file"); then
                    gpg_verified="true"
                else
                    if [[ "$FORCE_VERIFY" == "false" ]]; then
                        error "GPG verification failed. Use --force to continue anyway"
                    fi
                fi
            fi
        fi
    else
        log "Skipping GPG verification as requested"
    fi
    
    # Re-verify checksum for completeness
    log "Re-verifying checksum integrity..."
    local checksum_algo="${checksum_file%SUMS}"
    local expected_hash actual_hash
    
    if hash_line=$(grep "$(basename "$iso_file")" "$checksum_file"); then
        expected_hash=$(echo "$hash_line" | cut -d' ' -f1)
        
        case "$checksum_algo" in
            "SHA512") actual_hash=$(sha512sum "$iso_file" | cut -d' ' -f1) ;;
            "SHA256") actual_hash=$(sha256sum "$iso_file" | cut -d' ' -f1) ;;
        esac
        
        if [[ "$expected_hash" == "$actual_hash" ]]; then
            log_success "Checksum verification PASSED ($checksum_algo)"
        else
            error "Checksum verification FAILED"
        fi
    else
        error "Could not find checksum for $iso_file"
    fi
    
    # Save checkpoint
    checkpoint_save "$prev_checkpoint" "$iso_file" "$checksum_file" "$gpg_verified" "$signing_key"
    
    # Final summary
    echo
    log_success "Step completed successfully"
    log "ISO verified: $iso_file"
    log "Checksum file: $checksum_file"
    log "Checksum verification: PASSED"
    log "GPG verification: $(if [[ "$gpg_verified" == "true" ]]; then echo "PASSED"; else echo "SKIPPED"; fi)"
    [[ -n "$signing_key" ]] && log "Signing key: $signing_key"
    log "Output files:"
    log "  - ${STEP}.checkpoint.json"
    
    # Exit with appropriate code
    if [[ "$gpg_verified" == "false" ]] && [[ "$SKIP_GPG" == "false" ]] && [[ "$FORCE_VERIFY" == "false" ]]; then
        exit 1
    fi
}

# ---------- execute ----------
main "$@" || exit 1
exit 0
