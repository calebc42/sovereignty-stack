#!/usr/bin/env bash
set -euo pipefail

# ---------- metadata ----------
STEP="gpg-verify-debian"

# ---------- functions ----------
log() {
    echo "[$(date '+%H:%M:%S')] $*" >&2
}

# ---------- rollback ----------
log "Rolling back $STEP..."

# Remove only the files created by this step
FILES_TO_REMOVE=(
    "sovereignty-chain.${STEP}.json"
)

for file in "${FILES_TO_REMOVE[@]}"; do
    if [[ -f "$file" ]]; then
        log "Removing: $file"
        rm -f "$file"
    fi
done

# Optionally remove GPG keys (commented out by default)
# Uncomment if you want to remove the imported Debian keys
# log "Removing imported GPG keys..."
# gpg --delete-keys --batch --yes 988021A964E6EA7D 2>/dev/null || true
# gpg --delete-keys --batch --yes DA87E80D6294BE9B 2>/dev/null || true
# gpg --delete-keys --batch --yes 42468F4009EA8AC3 2>/dev/null || true

log "Rollback complete. Verification state reset."
log "Note: GPG keys remain in keyring (remove manually if needed)"
