#!/usr/bin/env bash
set -euo pipefail

# ---------- metadata ----------
STEP="download-debian"
BASE_URL="https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/"

# ---------- functions ----------
log() {
    echo "[$(date '+%H:%M:%S')] $*" >&2
}

error() {
    echo "[ERROR] $*" >&2
    exit 1
}

discover_latest_iso() {
    log "Discovering latest Debian version..." >&2  # Send log to stderr, not stdout
    local index_page
    if ! index_page=$(curl -fsSL --connect-timeout 30 "$BASE_URL"); then
        error "Failed to fetch directory listing from $BASE_URL"
    fi
    
    # Find all netinst ISOs and sort by version
    local iso_candidates
    iso_candidates=$(echo "$index_page" | grep -oE 'debian-[0-9.]*-amd64-netinst\.iso' | sort -V | tail -1)
    
    if [[ -z "$iso_candidates" ]]; then
        error "Could not find any Debian netinst ISO in directory listing"
    fi
    
    echo "$iso_candidates"  # Only this should go to stdout
}

check_existing_file() {
    local file="$1"
    local url="$2"
    
    if [[ ! -f "$file" ]]; then
        return 1  # File doesn't exist
    fi
    
    log "File exists: $file, checking integrity..."
    
    # Check file size against server
    local server_size local_size
    if server_size=$(curl -fsSL --head "$url" | grep -i content-length | cut -d' ' -f2 | tr -d '\r'); then
        local_size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null || echo "0")
        
        if [[ "$server_size" == "$local_size" ]]; then
            log "File size matches server ($(numfmt --to=iec "$local_size"))"
            return 0  # File is complete
        else
            log "File size mismatch (local: $(numfmt --to=iec "$local_size"), server: $(numfmt --to=iec "$server_size"))"
            rm -f "$file"
            return 1  # File is incomplete
        fi
    else
        log "Warning: Could not verify file size with server"
        return 1  # Can't verify, re-download
    fi
}

download_with_resume() {
    local url="$1"
    local output="$2"
    local temp_file="${output}.tmp"
    
    log "Downloading: $(basename "$output")"
    
    # Use curl with progress bar (remove -s flag to show progress)
    if ! curl -fL --connect-timeout 30 --max-time 3600 \
              --progress-bar -C - \
              -o "$temp_file" "$url"; then
        rm -f "$temp_file"
        error "Download failed: $url"
    fi
    
    # Move completed download to final location
    mv "$temp_file" "$output"
    
    local file_size
    file_size=$(stat -c%s "$output" 2>/dev/null || stat -f%z "$output" 2>/dev/null || echo "0")
    log "Download completed: $(numfmt --to=iec "$file_size")"
}

download_checksums() {
    local base_url="$1"
    local hash_file=""
    local hash_algo=""
    
    # Try SHA512SUMS first (more secure), fallback to SHA256SUMS
    for hash_type in "SHA512SUMS" "SHA256SUMS"; do
        log "Trying to download $hash_type..."
        local checksum_url="${base_url}${hash_type}"
        log "URL: $checksum_url"
        
        if curl -fsSL --connect-timeout 15 -o "$hash_type" "$checksum_url"; then
            hash_file="$hash_type"
            hash_algo="${hash_type%SUMS}"
            log "Downloaded: $hash_type"
            
            # Try to download signature file with more verbose error reporting
            local sign_url="${base_url}${hash_type}.sign"
            log "Trying to download signature file from: $sign_url"
            
            if curl -fsSL --connect-timeout 30 -o "${hash_type}.sign" "$sign_url"; then
                log "Downloaded: ${hash_type}.sign"
            else
                local curl_exit_code=$?
                log "Warning: Could not download ${hash_type}.sign (exit code: $curl_exit_code)"
                log "This may be due to network issues or the file may not be available"
                
                # Try to get more info about what went wrong
                log "Testing connectivity to signature URL..."
                if curl -I --connect-timeout 10 "$sign_url" 2>&1 | head -5; then
                    log "URL is reachable, but download failed"
                else
                    log "URL appears unreachable"
                fi
            fi
            
            break
        else
            log "Could not download $hash_type, trying next option..."
        fi
    done
    
    if [[ -z "$hash_file" ]]; then
        log "Warning: No checksum files available for verification"
        return 1
    fi
    
    echo "$hash_file:$hash_algo"
}

verify_checksum() {
    local file="$1"
    local hash_file="$2"
    local hash_algo="$3"
    
    if [[ ! -f "$hash_file" ]]; then
        log "Warning: Checksum file not found: $hash_file"
        return 1
    fi
    
    log "Verifying $hash_algo checksum..."
    
    local hash_line expected_hash actual_hash
    if ! hash_line=$(grep "$(basename "$file")" "$hash_file"); then
        log "Warning: Could not find hash for $(basename "$file") in $hash_file"
        return 1
    fi
    
    expected_hash=$(echo "$hash_line" | cut -d' ' -f1)
    
    case "$hash_algo" in
        "SHA512") actual_hash=$(sha512sum "$file" | cut -d' ' -f1) ;;
        "SHA256") actual_hash=$(sha256sum "$file" | cut -d' ' -f1) ;;
        *) error "Unknown hash algorithm: $hash_algo" ;;
    esac
    
    if [[ "$expected_hash" == "$actual_hash" ]]; then
        log "$hash_algo verification PASSED"
        return 0
    else
        error "$hash_algo mismatch: expected $expected_hash, got $actual_hash"
    fi
}

baton_save() {
    local iso_name="$1"
    local iso_version="$2"
    local iso_url="$3"
    local sha256_hash="$4"
    local sha512_hash="$5"
    local verified="$6"
    local hash_file="$7"
    
    local json="sovereignty-chain.${STEP}.json"
    local iso_size
    iso_size=$(stat -c%s "$iso_name" 2>/dev/null || stat -f%z "$iso_name" 2>/dev/null || echo "0")
    
    # Build JSON using only coreutils (cat with heredoc)
    cat > "$json" <<EOF
{
  "schema_version": 1,
  "step": "$STEP",
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "artefacts": {
    "$iso_name": {
      "sha256": "$sha256_hash",
      "sha512": $(if [[ -n "$sha512_hash" ]]; then echo "\"$sha512_hash\""; else echo "null"; fi),
      "url": "$iso_url",
      "version": "$iso_version",
      "verified": $verified,
      "location": "$(pwd)",
      "size_bytes": $iso_size,
      "checksum_file": $(if [[ -n "$hash_file" ]]; then echo "\"$hash_file\""; else echo "null"; fi)
    }
  }
}
EOF
    
    log "Baton saved: $json"
}

# ---------- main workflow ----------
main() {
    # Discover latest ISO
    local ISO_NAME ISO_URL ISO_VERSION
    ISO_NAME=$(discover_latest_iso)
    ISO_URL="${BASE_URL}${ISO_NAME}"
    ISO_VERSION=$(echo "$ISO_NAME" | sed -E 's/^debian-([0-9.]+)-.*/\1/')
    
    log "Found: $ISO_NAME (version $ISO_VERSION)"
    
    # Check if ISO already exists and is complete
    local skip_download=false
    if check_existing_file "$ISO_NAME" "$ISO_URL"; then
        skip_download=true
    fi
    
    # Download ISO if needed
    if [[ "$skip_download" == "false" ]]; then
        download_with_resume "$ISO_URL" "$ISO_NAME"
    fi
    
    # Check for existing valid checksum files
    local hash_file=""
    local hash_algo=""
    local skip_checksum=false
    
    for hash_type in "SHA512SUMS" "SHA256SUMS"; do
        if [[ -f "$hash_type" ]] && grep -q "$(basename "$ISO_NAME")" "$hash_type" 2>/dev/null; then
            hash_file="$hash_type"
            hash_algo="${hash_type%SUMS}"
            skip_checksum=true
            log "Found valid checksum file: $hash_file"
            break
        fi
    done
    
    # Download checksums if needed
    if [[ "$skip_checksum" == "false" ]]; then
        if checksum_result=$(download_checksums "$BASE_URL"); then
            hash_file="${checksum_result%:*}"
            hash_algo="${checksum_result#*:}"
        fi
    fi
    
    # Verify checksum
    local verified="false"
    if [[ -n "$hash_file" ]] && verify_checksum "$ISO_NAME" "$hash_file" "$hash_algo"; then
        verified="true"
    fi
    
    # Calculate hashes for baton
    local sha256_hash sha512_hash=""
    sha256_hash=$(sha256sum "$ISO_NAME" | cut -d' ' -f1)
    
    if [[ "$hash_algo" == "SHA512" ]]; then
        sha512_hash=$(sha512sum "$ISO_NAME" | cut -d' ' -f1)
    fi
    
    # Create baton
    baton_save "$ISO_NAME" "$ISO_VERSION" "$ISO_URL" "$sha256_hash" "$sha512_hash" "$verified" "$hash_file"
    
    # Final status
    local file_size
    file_size=$(stat -c%s "$ISO_NAME" 2>/dev/null || stat -f%z "$ISO_NAME" 2>/dev/null || echo "0")
    
    echo
    log "SUCCESS: Process completed: $ISO_NAME"
    log "Version: $ISO_VERSION"
    log "Size: $(numfmt --to=iec "$file_size")"
    log "Verified: $(if [[ "$verified" == "true" ]]; then echo "Yes"; else echo "No"; fi)"
    log "Location: $(pwd)"
    log "Files: $ISO_NAME$(if [[ -n "$hash_file" ]]; then echo ", $hash_file"; fi), sovereignty-chain.${STEP}.json"
}

# ---------- dependency checks ----------
for cmd in curl sha256sum sha512sum; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        error "Required command not found: $cmd"
    fi
done

# Check for numfmt (part of coreutils, may not be available on all systems)
if ! command -v numfmt >/dev/null 2>&1; then
    # Fallback function for systems without numfmt
    numfmt() {
        if [[ "$1" == "--to=iec" ]]; then
            local size=$2
            if [[ $size -gt 1073741824 ]]; then
                echo "$((size / 1073741824))G"
            elif [[ $size -gt 1048576 ]]; then
                echo "$((size / 1048576))M"
            elif [[ $size -gt 1024 ]]; then
                echo "$((size / 1024))K"
            else
                echo "${size}B"
            fi
        else
            echo "$2"
        fi
    }
fi

# ---------- execute ----------
main "$@"
