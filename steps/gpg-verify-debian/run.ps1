#!/usr/bin/env pwsh
#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------- metadata ----------
$STEP = "gpg-verify-debian"
$PREV_STEP = "debian-download"

# ---------- functions ----------
function Log {
    param([string]$Message)
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Message" -ForegroundColor Cyan
}

function Error-Exit {
    param([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
    exit 1
}

# ---------- parse arguments ----------
$SkipGPG = $false
foreach ($arg in $args) {
    switch ($arg) {
        "--no-gpg" {
            $SkipGPG = $true
            Log "Warning: Skipping GPG verification (--no-gpg flag used)"
        }
    }
}

# ---------- load previous baton ----------
$PrevBaton = "sovereignty-chain.$PREV_STEP.json"
if (-not (Test-Path $PrevBaton)) {
    Error-Exit "Previous baton not found: $PrevBaton`nRun the debian-download step first"
}

Log "Loading baton from previous step: $PrevBaton"

# Extract ISO filename from previous baton
$BatonContent = Get-Content $PrevBaton -Raw
$IsoMatch = [regex]::Match($BatonContent, '"(debian-[^"]*\.iso)"')
if (-not $IsoMatch.Success) {
    Error-Exit "Could not find ISO filename in previous baton"
}
$IsoFile = $IsoMatch.Groups[1].Value

Log "ISO to verify: $IsoFile"

# ---------- check required files ----------
if (-not (Test-Path $IsoFile)) {
    Error-Exit "ISO file not found: $IsoFile"
}

if (-not ((Test-Path "SHA512SUMS") -or (Test-Path "SHA256SUMS"))) {
    Error-Exit "No checksum files found (need SHA512SUMS or SHA256SUMS)"
}

# Determine which checksum file we have
$ChecksumFile = ""
if (Test-Path "SHA512SUMS") {
    $ChecksumFile = "SHA512SUMS"
} elseif (Test-Path "SHA256SUMS") {
    $ChecksumFile = "SHA256SUMS"
}

Log "Using checksum file: $ChecksumFile"

# ---------- GPG verification ----------
$GpgVerified = $false

if (-not $SkipGPG) {
    # Check if GPG is installed
    try {
        $null = Get-Command gpg -ErrorAction Stop
    } catch {
        Log "GPG not installed. Install with:"
        Log "  Windows: winget install GnuPG.GnuPG"
        Log "  Or use --no-gpg flag to skip verification"
        Error-Exit "GPG required for signature verification"
    }
    
    # Check for signature file
    $SignatureFile = "$ChecksumFile.sign"
    if (-not (Test-Path $SignatureFile)) {
        Log "Warning: Signature file $SignatureFile not found"
        Log "Cannot perform GPG verification without signature"
        Error-Exit "Use --no-gpg flag to skip GPG verification"
    } else {
        Log "Importing Debian CD signing keys..."
        
        # These are the official Debian CD signing keys as of 2024
        # Verify at: https://www.debian.org/CD/verify
        $DebianKeys = @(
            "988021A964E6EA7D",  # Debian CD signing key
            "DA87E80D6294BE9B",  # Debian CD signing key
            "42468F4009EA8AC3"   # Debian Testing CDs Automatic Signing Key
        )
        
        foreach ($key in $DebianKeys) {
            Log "Importing key: $key"
            try {
                & gpg --keyserver keyserver.ubuntu.com --recv-keys $key 2>$null
            } catch {
                Log "Warning: Could not import key $key from keyserver"
                # Try alternative keyserver
                try {
                    & gpg --keyserver keys.openpgp.org --recv-keys $key 2>$null
                } catch {
                    Log "Warning: Could not import key $key from alternative keyserver"
                }
            }
        }
        
        Log "Verifying GPG signature..."
        $VerifyOutput = & gpg --verify $SignatureFile $ChecksumFile 2>&1 | Out-String
        
        if ($VerifyOutput -match "Good signature") {
            $GpgVerified = $true
            Log "GPG signature verification PASSED"
            
            # Show which key was used
            if ($VerifyOutput -match "using RSA key ([A-F0-9]{16,})") {
                $KeyUsed = $Matches[1]
                Log "Signed with key: $KeyUsed"
            }
        } else {
            Error-Exit "GPG signature verification FAILED"
        }
    }
} else {
    Log "Skipping GPG verification as requested"
}

# ---------- update baton ----------
Log "Updating baton with verification status..."

# Read the previous baton
$PrevContent = Get-Content $PrevBaton -Raw | ConvertFrom-Json

# Create new baton with GPG verification status
$NewBaton = "sovereignty-chain.$STEP.json"

# Extract artefacts from previous baton
$Artefacts = $PrevContent.artefacts

# Update verified field if GPG passed
if ($GpgVerified -and $Artefacts.$IsoFile) {
    $Artefacts.$IsoFile.verified = $true
}

# Create new baton object
$BatonObject = @{
    schema_version = 1
    step = $STEP
    created_at = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    previous_step = $PREV_STEP
    gpg_verified = $GpgVerified
    checksum_file = $ChecksumFile
    artefacts = $Artefacts
}

# Save new baton
$BatonObject | ConvertTo-Json -Depth 10 | Out-File $NewBaton -Encoding UTF8
Log "Baton saved: $NewBaton"

# ---------- final status ----------
Write-Host ""
Log "SUCCESS: Verification completed"
Log "ISO: $IsoFile"
Log "Checksum file: $ChecksumFile"
Log "GPG verified: $GpgVerified"
Log "Output: $NewBaton"

if ((-not $GpgVerified) -and (-not $SkipGPG)) {
    exit 1
}