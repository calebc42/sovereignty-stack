#!/usr/bin/env bash
set -euo pipefail
slug="$1"
dst="steps/$slug"
mkdir -p "$dst"/manual
cp -r templates/step-starter/* "$dst"/
for f in "$dst"/*.stub; do mv "$f" "${f%.stub}"; done
sed -i "s/__STEP__/$slug/g" "$dst"/*.{sh,ps1,yml}
chmod +x "$dst"/*.sh
echo "✅ Scaffold created at $dst"
