#!/usr/bin/env bash
set -euo pipefail
for f in debian-*.iso SHA512SUMS SHA512SUMS.sign; do
  [[ -f $f ]] || { echo "❌ $f missing"; exit 1; }
done
echo "✅ All files present"
