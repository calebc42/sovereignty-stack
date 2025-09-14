#!/usr/bin/env bash
set -euo pipefail
# Fail fast if any required tool is missing
for cmd in curl jq sha256sum sha512sum shellcheck; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "❌ Missing: $cmd" >&2
    exit 1
  fi
done
echo "✅ All tools present"
echo "=== Preflight for $(basename $PWD) ==="
command -v shellcheck >/dev/null || { echo "Install shellcheck"; exit 1; }
command -v git >/dev/null          || { echo "Install git"; exit 1; }
[[ -f run.sh ]]                    || { echo "Missing run.sh"; exit 1; }
shellcheck run.sh
echo "✅ Ready to commit"
