#!/usr/bin/env pwsh
#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------- metadata ----------
$STEP = "gpg-verify-debian"

# ---------- functions ----------
function Log {
    param([string]$Message)
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Message" -ForegroundColor Yellow
}

# ---------- rollback ----------
Log "Rolling back $STEP..."

# Remove only the files created by this step
$FilesToRemove = @(
    "sovereignty-chain.$STEP.json"
)

foreach ($file in $FilesToRemove) {
    if (Test-Path $file) {
        Log "Removing: $file"
        Remove-Item $file -Force
    }
}

# Optionally remove GPG keys (commented out by default)
# Uncomment if you want to remove the imported Debian keys
# Log "Removing imported GPG keys..."
# $KeysToRemove = @("988021A964E6EA7D", "DA87E80D6294BE9B", "42468F4009EA8AC3")
# foreach ($key in $KeysToRemove) {
#     try {
#         & gpg --delete-keys --batch --yes $key 2>$null
#     } catch {
#         # Key might not exist, that's fine
#     }
# }

Log "Rollback complete. Verification state reset."
Log "Note: GPG keys remain in keyring (remove manually if needed)"