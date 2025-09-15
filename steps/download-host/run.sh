#!/usr/bin/env bash
# SPDX-License-Identifier: ISC
set -euo pipefail

# ---------- metadata ----------
STEP="download-host"
STEP_NUMBER="1"
SCRIPT_VERSION="1.0.0"
BASE_URL="https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/"

# ---------- constants ----------
DEFAULT_CONNECT_TIMEOUT=30
DEFAULT_MAX_TIME=3600
CHECKPOINT_SCHEMA_VERSION=1

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
checkpoint_save() {
    local checkpoint_file="${STEP}.checkpoint.json"
    local iso_name="$1"
    local iso_version="$2"
    local iso_url="$3"
    local sha256_hash="$4"
    local sha512_hash="${5:-}"
    local verified="${6:-false}"
    local checksum_file="${7:-}"
    
    local iso_size
    iso_size=$(stat -c%s "$iso_name" 2>/dev/null || stat -f%z "$iso_name" 2>/dev/null || echo "0")
    
    cat > "$checkpoint_file" <<EOF
{
  "schema_version": $CHECKPOINT_SCHEMA_VERSION,
  "step": "$STEP",
  "step_number": $STEP_NUMBER,
  "script_version": "$SCRIPT_VERSION",
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "hostname": "$(hostname)",
  "artifacts": {
    "$iso_name": {
      "type": "debian-iso",
      "sha256": "$sha256_hash",
      "sha512": $(if [[ -n "$sha512_hash" ]]; then echo "\"$sha512_hash\""; else echo "null"; fi),
      "url": "$iso_url",
      "version": "$iso_version",
      "verified": $verified,
      "checksum_file": $(if [[ -n "$checksum_file" ]]; then echo "\"$checksum_file\""; else echo "null"; fi),
      "location": "$(pwd)",
      "size_bytes": $iso_size,
      "size_human": "$(format_bytes "$iso_size")"
    }
  },
  "metadata": {
    "base_url": "$BASE_URL",
    "download_completed": true
  }
}
EOF
    
    log "Checkpoint saved: $checkpoint_file"
}

checkpoint_validate() {
    local checkpoint_file="$1"
    
    if [[ ! -f "$checkpoint_file" ]]; then
        return 1
    fi
    
    # Validate JSON structure
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
    
    return 0
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
    
    for cmd in curl sha256sum sha512sum; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_deps+=("$cmd")
        fi
    done
    
    # jq is optional but recommended
    if ! command -v jq >/dev/null 2>&1; then
        log_warning "jq not found - checkpoint validation will be limited"
    fi
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        error "Missing required dependencies: ${missing_deps[*]}"
    fi
}

# ---------- download functions ----------
discover_latest_iso() {
    log "Discovering latest Debian ISO from: $BASE_URL"
    
    local index_page
    if ! index_page=$(curl -fsSL --connect-timeout "$DEFAULT_CONNECT_TIMEOUT" "$BASE_URL"); then
        error "Failed to fetch directory listing from $BASE_URL"
    fi
    
    # Find all netinst ISOs and sort by version
    local iso_file
    iso_file=$(echo "$index_page" | grep -oE 'debian-[0-9.]*-amd64-netinst\.iso' | sort -V | tail -1)
    
    if [[ -z "$iso_file" ]]; then
        error "Could not find any Debian netinst ISO in directory listing"
    fi
    
    log "Discovered: $iso_file"
    echo "$iso_file"
}

check_existing_file() {
    local file="$1"
    local url="$2"
    
    if [[ ! -f "$file" ]]; then
        return 1
    fi
    
    log "Found existing file: $file"
    log "Verifying file integrity..."
    
    # Check file size against server
    local server_size local_size
    if server_size=$(curl -fsSL --head "$url" | grep -i content-length | cut -d' ' -f2 | tr -d '\r'); then
        local_size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null || echo "0")
        
        if [[ "$server_size" == "$local_size" ]]; then
            log "File size matches server ($(format_bytes "$local_size"))"
            return 0
        else
            log_warning "File size mismatch (local: $(format_bytes "$local_size"), server: $(format_bytes "$server_size"))"
            log "Removing incomplete file and re-downloading..."
            rm -f "$file"
            return 1
        fi
    else
        log_warning "Could not verify file size with server - will re-download"
        return 1
    fi
}

download_with_resume() {
    local url="$1"
    local output="$2"
    local temp_file="${output}.downloading"
    
    log "Starting download: $(basename "$output")"
    log "Source URL: $url"
    
    # Use curl with resume support and progress bar
    if ! curl -fL --connect-timeout "$DEFAULT_CONNECT_TIMEOUT" \
              --max-time "$DEFAULT_MAX_TIME" \
              --progress-bar -C - \
              -o "$temp_file" "$url"; then
        rm -f "$temp_file"
        error "Download failed: $url"
    fi
    
    # Atomic move to final location
    mv "$temp_file" "$output"
    
    local file_size
    file_size=$(stat -c%s "$output" 2>/dev/null || stat -f%z "$output" 2>/dev/null || echo "0")
    log "Download completed: $(format_bytes "$file_size")"
}

download_checksums() {
    local base_url="$1"
    local checksum_file=""
    local checksum_algo=""
    
    # Try SHA512SUMS first (more secure), then SHA256SUMS
    for hash_type in "SHA512SUMS" "SHA256SUMS"; do
        log "Attempting to download: $hash_type"
        local checksum_url="${base_url}${hash_type}"
        
        if curl -fsSL --connect-timeout "$DEFAULT_CONNECT_TIMEOUT" -o "$hash_type" "$checksum_url"; then
            checksum_file="$hash_type"
            checksum_algo="${hash_type%SUMS}"
            log "Successfully downloaded: $hash_type"
            
            # Try to download signature file
            local sign_url="${base_url}${hash_type}.sign"
            log "Attempting to download signature: ${hash_type}.sign"
            
            if curl -fsSL --connect-timeout "$DEFAULT_CONNECT_TIMEOUT" -o "${hash_type}.sign" "$sign_url"; then
                log "Successfully downloaded: ${hash_type}.sign"
            else
                log_warning "Could not download signature file: ${hash_type}.sign"
                log_warning "GPG verification will not be available without signature"
            fi
            
            break
        else
            log_warning "Could not download: $hash_type"
        fi
    done
    
    if [[ -z "$checksum_file" ]]; then
        log_warning "No checksum files could be downloaded"
        return 1
    fi
    
    echo "${checksum_file}:${checksum_algo}"
}

verify_checksum() {
    local file="$1"
    local checksum_file="$2"
    local checksum_algo="$3"
    
    if [[ ! -f "$checksum_file" ]]; then
        log_warning "Checksum file not found: $checksum_file"
        return 1
    fi
    
    log "Verifying $checksum_algo checksum for: $(basename "$file")"
    
    local hash_line expected_hash actual_hash
    if ! hash_line=$(grep "$(basename "$file")" "$checksum_file"); then
        log_warning "Could not find checksum for $(basename "$file") in $checksum_file"
        return 1
    fi
    
    expected_hash=$(echo "$hash_line" | cut -d' ' -f1)
    
    case "$checksum_algo" in
        "SHA512") actual_hash=$(sha512sum "$file" | cut -d' ' -f1) ;;
        "SHA256") actual_hash=$(sha256sum "$file" | cut -d' ' -f1) ;;
        *) error "Unknown checksum algorithm: $checksum_algo" ;;
    esac
    
    if [[ "$expected_hash" == "$actual_hash" ]]; then
        log_success "Checksum verification PASSED ($checksum_algo)"
        return 0
    else
        log_error "Checksum verification FAILED ($checksum_algo)"
        log_error "Expected: $expected_hash"
        log_error "Actual:   $actual_hash"
        return 1
    fi
}

# ---------- main workflow ----------
main() {
    log "Starting $STEP (v$SCRIPT_VERSION)"
    log "Working directory: $(pwd)"
    
    # Check dependencies
    check_dependencies
    
    # Discover latest ISO
    local iso_name iso_url iso_version
    iso_name=$(discover_latest_iso)
    iso_url="${BASE_URL}${iso_name}"
    iso_version=$(echo "$iso_name" | sed -E 's/^debian-([0-9.]+)-.*/\1/')
    
    log "Target ISO: $iso_name (version $iso_version)"
    
    # Check if ISO already exists and is complete
    local need_download=true
    if check_existing_file "$iso_name" "$iso_url"; then
        need_download=false
        log "Using existing ISO file"
    fi
    
    # Download ISO if needed
    if [[ "$need_download" == "true" ]]; then
        download_with_resume "$iso_url" "$iso_name"
    fi
    
    # Check for existing valid checksum files
    local checksum_file=""
    local checksum_algo=""
    local need_checksum=true
    
    for hash_type in "SHA512SUMS" "SHA256SUMS"; do
        if [[ -f "$hash_type" ]] && grep -q "$(basename "$iso_name")" "$hash_type" 2>/dev/null; then
            checksum_file="$hash_type"
            checksum_algo="${hash_type%SUMS}"
            need_checksum=false
            log "Found existing checksum file: $checksum_file"
            break
        fi
    done
    
    # Download checksums if needed
    if [[ "$need_checksum" == "true" ]]; then
        if checksum_result=$(download_checksums "$BASE_URL"); then
            checksum_file="${checksum_result%:*}"
            checksum_algo="${checksum_result#*:}"
        fi
    fi
    
    # Verify checksum
    local verified="false"
    if [[ -n "$checksum_file" ]] && verify_checksum "$iso_name" "$checksum_file" "$checksum_algo"; then
        verified="true"
    fi
    
    # Calculate hashes for checkpoint
    local sha256_hash sha512_hash=""
    sha256_hash=$(sha256sum "$iso_name" | cut -d' ' -f1)
    
    if [[ "$checksum_algo" == "SHA512" ]] || [[ -f "SHA512SUMS" ]]; then
        sha512_hash=$(sha512sum "$iso_name" | cut -d' ' -f1)
    fi
    
    # Save checkpoint
    checkpoint_save "$iso_name" "$iso_version" "$iso_url" \
                   "$sha256_hash" "$sha512_hash" "$verified" "$checksum_file"
    
    # Final summary
    local file_size
    file_size=$(stat -c%s "$iso_name" 2>/dev/null || stat -f%z "$iso_name" 2>/dev/null || echo "0")
    
    echo
    log_success "Step completed successfully"
    log "ISO file: $iso_name"
    log "Version: $iso_version"
    log "Size: $(format_bytes "$file_size")"
    log "Checksum verified: $verified"
    log "Output files:"
    log "  - $iso_name"
    [[ -n "$checksum_file" ]] && log "  - $checksum_file"
    [[ -f "${checksum_file}.sign" ]] && log "  - ${checksum_file}.sign"
    log "  - ${STEP}.checkpoint.json"
}

# ---------- execute ----------
main "$@" || exit 1
exit 0
