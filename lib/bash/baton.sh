#!/usr/bin/env bash
# Sovereignty Stack – shared baton helpers
# Source with: source "$(dirname "$0")/../../lib/bash/baton.sh"

set -euo pipefail

# Usage: baton::save <json-path> <iso-name> <sha256> <url> <version> <verified> <checksum-file> <size>
baton::save() {
  local json="$1" name="$2" sha256="$3" url="$4" version="$5" verified="$6" cfile="$7" size="$8"
  cat > "$json" <<EOF
{
  "schema_version": 1,
  "step": "$(basename "$(dirname "$(realpath "$0")")")",
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "artefacts": {
    "$name": {
      "sha256": "$sha256",
      "sha512": null,
      "url": "$url",
      "version": "$version",
      "verified": $verified,
      "location": "$(pwd)",
      "size_bytes": $size,
      "checksum_file": ${cfile:+\"$cfile\"}${cfile:-null}
    }
  }
}
EOF
}

# Usage: baton::load <json-path> → exports ISO_FILE ISO_SHA256
baton::load() {
  local json="$1"
  if [[ ! -f "$json" ]]; then echo "Baton not found: $json" >&2; exit 1; fi
  export ISO_FILE=$(jq -r '.artefacts | keys[0]' "$json")
  export ISO_SHA256=$(jq -r ".artefacts[\"$ISO_FILE\"].sha256" "$json")
}
