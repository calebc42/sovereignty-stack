#!/usr/bin/env bash
set -euo pipefail
echo "=== Preflight for $(basename $PWD) ==="
command -v shellcheck >/dev/null || { echo "Install shellcheck"; exit 1; }
command -v git >/dev/null          || { echo "Install git"; exit 1; }
[[ -f run.sh ]]                    || { echo "Missing run.sh"; exit 1; }
shellcheck run.sh
echo "✅ Ready to commit"
