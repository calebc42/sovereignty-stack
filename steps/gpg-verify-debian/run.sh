#!/usr/bin/env bash
set -euo pipefail

# ---------- metadata ----------
STEP="gpg-verify-debian"
PREV_STEP="debian-download"

# ---------- functions ----------
log() {
    echo "[$(date '+%H:%M:%S')] $*" >&2
}

error() {
    echo "[ERROR] $*" >&2
    exit 1
}

# ---------- parse arguments ----------
SKIP_GPG=false
for arg in "$@"; do
    case $arg in
        --no-gpg)
            SKIP_GPG=true
            log "Warning: Skipping GPG verification (--no-gpg flag used)"
            ;;
    esac
done

# ---------- load previous baton ----------
PREV_BATON="sovereignty-chain.${PREV_STEP}.json"
if [[ ! -f "$PREV_BATON" ]]; then
    error "Previous baton not found: $PREV_BATON"
    error "Run the debian-download step first"
fi

log "Loading baton from previous step: $PREV_BATON"

# Extract ISO filename from previous baton
ISO_FILE=$(grep -oP '"debian-[^"]*\.iso"' "$PREV_BATON" | head -1 | tr -d '"')
if [[ -z "$ISO_FILE" ]]; then
    error "Could not find ISO filename in previous baton"
fi

log "ISO to verify: $ISO_FILE"

# ---------- check required files ----------
if [[ ! -f "$ISO_FILE" ]]; then
    error "ISO file not found: $ISO_FILE"
fi

if [[ ! -f "SHA512SUMS" ]] && [[ ! -f "SHA256SUMS" ]]; then
    error "No checksum files found (need SHA512SUMS or SHA256SUMS)"
fi

# Determine which checksum file we have
CHECKSUM_FILE=""
if [[ -f "SHA512SUMS" ]]; then
    CHECKSUM_FILE="SHA512SUMS"
elif [[ -f "SHA256SUMS" ]]; then
    CHECKSUM_FILE="SHA256SUMS"
fi

log "Using checksum file: $CHECKSUM_FILE"

# ---------- GPG verification ----------
GPG_VERIFIED="false"

if [[ "$SKIP_GPG" == "false" ]]; then
    # Check if GPG is installed
    if ! command -v gpg >/dev/null 2>&1; then
        log "GPG not installed. Install with:"
        log "  Ubuntu/Debian: sudo apt-get install gnupg"
        log "  macOS: brew install gnupg"
        log "  Or use --no-gpg flag to skip verification"
        error "GPG required for signature verification"
    fi
    
    # Check for signature file
    if [[ ! -f "${CHECKSUM_FILE}.sign" ]]; then
        log "Warning: Signature file ${CHECKSUM_FILE}.sign not found"
        log "Cannot perform GPG verification without signature"
        if [[ "$SKIP_GPG" == "false" ]]; then
            error "Use --no-gpg flag to skip GPG verification"
        fi
    else
        log "Importing Debian CD signing keys..."
        
        # These are the official Debian CD signing keys as of 2024
        # Verify at: https://www.debian.org/CD/verify
        DEBIAN_KEYS=(
            "988021A964E6EA7D"  # Debian CD signing key <debian-cd@lists.debian.org>
            "DA87E80D6294BE9B"  # Debian CD signing key <debian-cd@lists.debian.org>
            "42468F4009EA8AC3"  # Debian Testing CDs Automatic Signing Key
        )
        
        for key in "${DEBIAN_KEYS[@]}"; do
            log "Importing key: $key"
            if ! gpg --keyserver keyserver.ubuntu.com --recv-keys "$key" 2>/dev/null; then
                log "Warning: Could not import key $key from keyserver"
                # Try alternative keyserver
                if ! gpg --keyserver keys.openpgp.org --recv-keys "$key" 2>/dev/null; then
                    log "Warning: Could not import key $key from alternative keyserver"
                fi
            fi
        done
        
        log "Verifying GPG signature..."
        if gpg --verify "${CHECKSUM_FILE}.sign" "$CHECKSUM_FILE" 2>&1 | grep -q "Good signature"; then
            GPG_VERIFIED="true"
            log "GPG signature verification PASSED"
            
            # Show which key was used
            KEY_USED=$(gpg --verify "${CHECKSUM_FILE}.sign" "$CHECKSUM_FILE" 2>&1 | grep "using RSA key" | grep -oP '[A-F0-9]{16,}')
            if [[ -n "$KEY_USED" ]]; then
                log "Signed with key: $KEY_USED"
            fi
        else
            error "GPG signature verification FAILED"
        fi
    fi
else
    log "Skipping GPG verification as requested"
fi

# ---------- update baton ----------
log "Updating baton with verification status..."

# Read the previous baton
PREV_CONTENT=$(cat "$PREV_BATON")

# Create new baton with GPG verification status
NEW_BATON="sovereignty-chain.${STEP}.json"

# Parse the previous baton and add gpg_verified field
cat > "$NEW_BATON" <<EOF
{
  "schema_version": 1,
  "step": "$STEP",
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "previous_step": "$PREV_STEP",
  "gpg_verified": $GPG_VERIFIED,
  "checksum_file": "$CHECKSUM_FILE",
  "artefacts": $(echo "$PREV_CONTENT" | grep -A100 '"artefacts":' | tail -n +2)
EOF

# Update the verified field in artefacts if GPG passed
if [[ "$GPG_VERIFIED" == "true" ]]; then
    sed -i 's/"verified": false/"verified": true/g' "$NEW_BATON"
fi

log "Baton saved: $NEW_BATON"

# ---------- final status ----------
echo
log "SUCCESS: Verification completed"
log "ISO: $ISO_FILE"
log "Checksum file: $CHECKSUM_FILE"
log "GPG verified: $GPG_VERIFIED"
log "Output: $NEW_BATON"

if [[ "$GPG_VERIFIED" == "false" ]] && [[ "$SKIP_GPG" == "false" ]]; then
    exit 1
fi
