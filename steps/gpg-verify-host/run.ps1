#!/usr/bin/env pwsh
# SPDX-License-Identifier: ISC
#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------- metadata ----------
$STEP = "gpg-verify-host"
$STEP_NUMBER = 2
$SCRIPT_VERSION = "1.0.0"
$PREV_STEP = "download-host"

# ---------- constants ----------
$CHECKPOINT_SCHEMA_VERSION = 1
$CHECKPOINT_FILE = "$STEP.checkpoint.json"
$PREV_CHECKPOINT = "$PREV_STEP.checkpoint.json"

# Official Debian CD signing keys (verify at: https://www.debian.org/CD/verify)
$DEBIAN_SIGNING_KEYS = @(
    "988021A964E6EA7D",  # Debian CD signing key
    "DA87E80D6294BE9B",  # Debian CD signing key
    "42468F4009EA8AC3"   # Debian Testing CDs Automatic Signing Key
)

$KEYSERVERS = @(
    "keyserver.ubuntu.com",
    "keys.openpgp.org",
    "pgp.mit.edu"
)

# ---------- options ----------
$script:SkipGPG = $false
$script:ForceVerify = $false

# ---------- common functions ----------
function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "HH:mm:ss"
    $color = switch ($Level) {
        "ERROR" { "Red" }
        "WARNING" { "Yellow" }
        "SUCCESS" { "Green" }
        "DEBUG" { "Gray" }
        default { "Cyan" }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

function Write-LogInfo {
    param([string]$Message)
    Write-Log -Message $Message -Level "INFO"
}

function Write-LogWarning {
    param([string]$Message)
    Write-Log -Message $Message -Level "WARNING"
}

function Write-LogError {
    param([string]$Message)
    Write-Log -Message $Message -Level "ERROR"
}

function Write-LogSuccess {
    param([string]$Message)
    Write-Log -Message $Message -Level "SUCCESS"
}

function Write-LogDebug {
    param([string]$Message)
    if ($script:Verbose) {
        Write-Log -Message $Message -Level "DEBUG"
    }
}

function Exit-WithError {
    param([string]$Message)
    Write-LogError $Message
    exit 1
}

# ---------- checkpoint functions ----------
function Read-Checkpoint {
    param([string]$CheckpointFile)
    
    if (-not (Test-Path $CheckpointFile)) {
        Exit-WithError "Checkpoint file not found: $CheckpointFile"
    }
    
    # Validate checkpoint
    if (-not (Test-Checkpoint -CheckpointFile $CheckpointFile)) {
        Exit-WithError "Invalid checkpoint file: $CheckpointFile"
    }
    
    Write-LogInfo "Loaded checkpoint: $CheckpointFile"
    
    return Get-Content $CheckpointFile -Raw | ConvertFrom-Json
}

function Test-Checkpoint {
    param([string]$CheckpointFile)
    
    if (-not (Test-Path $CheckpointFile)) {
        return $false
    }
    
    try {
        $content = Get-Content $CheckpointFile -Raw | ConvertFrom-Json
        
        # Check schema version
        if ($content.schema_version -ne $CHECKPOINT_SCHEMA_VERSION) {
            Write-LogWarning "Checkpoint schema version mismatch (expected: $CHECKPOINT_SCHEMA_VERSION, found: $($content.schema_version))"
            return $false
        }
        
        return $true
    } catch {
        Write-LogWarning "Invalid JSON in checkpoint file: $CheckpointFile"
        return $false
    }
}

function Save-Checkpoint {
    param(
        [object]$PreviousCheckpoint,
        [string]$IsoFile,
        [string]$ChecksumFile,
        [bool]$GpgVerified,
        [string]$SigningKey = $null
    )
    
    # Extract artifacts from previous checkpoint
    $artifacts = $PreviousCheckpoint.artifacts
    
    # Update verified status if GPG passed
    if ($GpgVerified -and $artifacts.$IsoFile) {
        $artifacts.$IsoFile.verified = $true
    }
    
    $checkpoint = @{
        schema_version = $CHECKPOINT_SCHEMA_VERSION
        step = $STEP
        step_number = $STEP_NUMBER
        script_version = $SCRIPT_VERSION
        created_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        hostname = $env:COMPUTERNAME
        previous_step = $PREV_STEP
        verification = @{
            gpg_verified = $GpgVerified
            checksum_file = $ChecksumFile
            signing_key = $SigningKey
            verified_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        }
        artifacts = $artifacts
    }
    
    $checkpoint | ConvertTo-Json -Depth 10 | Out-File -FilePath $CHECKPOINT_FILE -Encoding UTF8 -NoNewline
    Write-LogInfo "Checkpoint saved: $CHECKPOINT_FILE"
}

# ---------- utility functions ----------
function Test-Dependencies {
    $optionalMissing = @()
    
    # Check for GPG
    if (-not (Get-Command gpg -ErrorAction SilentlyContinue)) {
        $optionalMissing += "gpg"
        Write-LogWarning "gpg not found - signature verification will not be available"
    }
    
    if ($optionalMissing.Count -gt 0) {
        Write-LogWarning "Optional dependencies missing: $($optionalMissing -join ', ')"
        Write-LogWarning "Some features may not be available"
    }
}

# ---------- GPG functions ----------
function Import-GpgKeys {
    Write-LogInfo "Importing Debian CD signing keys..."
    
    $keysImported = 0
    $keysFailed = 0
    
    foreach ($keyId in $DEBIAN_SIGNING_KEYS) {
        $keyImported = $false
        
        foreach ($keyserver in $KEYSERVERS) {
            Write-LogInfo "Attempting to import key $keyId from $keyserver..."
            
            try {
                $output = & gpg --keyserver $keyserver --recv-keys $keyId 2>&1
                if ($LASTEXITCODE -eq 0) {
                    Write-LogInfo "Successfully imported key: $keyId"
                    $keyImported = $true
                    $keysImported++
                    break
                }
            } catch {
                Write-LogDebug "Failed to import from $keyserver : $_"
            }
        }
        
        if (-not $keyImported) {
            Write-LogWarning "Failed to import key: $keyId"
            $keysFailed++
        }
    }
    
    if ($keysImported -eq 0) {
        Exit-WithError "Could not import any GPG keys. Check network connectivity and keyserver availability"
    }
    
    Write-LogInfo "Imported $keysImported keys, $keysFailed failed"
    return $true
}

function Test-GpgSignature {
    param(
        [string]$ChecksumFile,
        [string]$SignatureFile
    )
    
    if (-not (Test-Path $SignatureFile)) {
        Write-LogWarning "Signature file not found: $SignatureFile"
        return @{ Verified = $false; KeyId = $null }
    }
    
    Write-LogInfo "Verifying GPG signature for: $ChecksumFile"
    
    # Capture GPG output
    $gpgOutput = & gpg --verify $SignatureFile $ChecksumFile 2>&1 | Out-String
    
    if ($gpgOutput -match "Good signature") {
        Write-LogSuccess "GPG signature verification PASSED"
        
        # Extract the key ID used for signing
        $keyId = $null
        if ($gpgOutput -match "using RSA key ([A-F0-9]{16,})") {
            $keyId = $Matches[1]
            Write-LogInfo "Signed with key: $keyId"
        }
        
        return @{ Verified = $true; KeyId = $keyId }
    } else {
        Write-LogError "GPG signature verification FAILED"
        if ($gpgOutput -match "(Bad signature|No public key)") {
            Write-LogError "  $($Matches[0])"
        }
        return @{ Verified = $false; KeyId = $null }
    }
}

# ---------- argument parsing ----------
function Parse-Arguments {
    param([array]$Args)
    
    foreach ($arg in $Args) {
        switch ($arg) {
            "--no-gpg" {
                $script:SkipGPG = $true
                Write-LogWarning "GPG verification will be skipped (--no-gpg flag)"
            }
            "--skip-gpg" {
                $script:SkipGPG = $true
                Write-LogWarning "GPG verification will be skipped (--skip-gpg flag)"
            }
            "--force" {
                $script:ForceVerify = $true
                Write-LogInfo "Force mode enabled - will attempt verification even with warnings"
            }
            "--help" {
                Show-Help
                exit 0
            }
            "-h" {
                Show-Help
                exit 0
            }
            default {
                Write-LogWarning "Unknown argument: $arg"
            }
        }
    }
}

function Show-Help {
    Write-Host @"
Usage: $($MyInvocation.MyCommand.Name) [OPTIONS]

Options:
    --no-gpg, --skip-gpg    Skip GPG signature verification
    --force                 Continue even if some verifications fail
    --help, -h              Show this help message

This script verifies the GPG signature of the Debian ISO downloaded in the
previous step. It requires the checkpoint file from the download-host step.

"@
}

# ---------- main workflow ----------
function Main {
    Write-LogInfo "Starting $STEP (v$SCRIPT_VERSION)"
    Write-LogInfo "Working directory: $(Get-Location)"
    
    # Check dependencies
    Test-Dependencies
    
    # Load previous checkpoint
    $prevCheckpoint = Read-Checkpoint -CheckpointFile $PREV_CHECKPOINT
    
    # Extract ISO filename from previous checkpoint
    $isoFile = $null
    $artifactNames = $prevCheckpoint.artifacts | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name
    foreach ($name in $artifactNames) {
        if ($name -match 'debian-.*\.iso$') {
            $isoFile = $name
            break
        }
    }
    
    if (-not $isoFile) {
        Exit-WithError "Could not find ISO filename in previous checkpoint"
    }
    
    Write-LogInfo "ISO to verify: $isoFile"
    
    # Verify required files exist
    if (-not (Test-Path $isoFile)) {
        Exit-WithError "ISO file not found: $isoFile"
    }
    
    # Determine which checksum file we have
    $checksumFile = $null
    if (Test-Path "SHA512SUMS") {
        $checksumFile = "SHA512SUMS"
    } elseif (Test-Path "SHA256SUMS") {
        $checksumFile = "SHA256SUMS"
    } else {
        Exit-WithError "No checksum files found (need SHA512SUMS or SHA256SUMS)"
    }
    
    Write-LogInfo "Using checksum file: $checksumFile"
    
    # GPG verification
    $gpgVerified = $false
    $signingKey = $null
    
    if (-not $script:SkipGPG) {
        if (-not (Get-Command gpg -ErrorAction SilentlyContinue)) {
            Write-LogError "GPG is not installed but is required for signature verification"
            Write-LogInfo "Install GPG with:"
            Write-LogInfo "  Windows: winget install GnuPG.GnuPG"
            Write-LogInfo "  Or use --no-gpg flag to skip verification"
            
            if (-not $script:ForceVerify) {
                Exit-WithError "Cannot proceed without GPG"
            }
        } else {
            # Import keys and verify
            if (Import-GpgKeys) {
                $signatureFile = "$checksumFile.sign"
                $result = Test-GpgSignature -ChecksumFile $checksumFile -SignatureFile $signatureFile
                
                if ($result.Verified) {
                    $gpgVerified = $true
                    $signingKey = $result.KeyId
                } elseif (-not $script:ForceVerify) {
                    Exit-WithError "GPG verification failed. Use --force to continue anyway"
                }
            }
        }
    } else {
        Write-LogInfo "Skipping GPG verification as requested"
    }
    
    # Re-verify checksum for completeness
    Write-LogInfo "Re-verifying checksum integrity..."
    $checksumAlgo = $checksumFile -replace 'SUMS', ''
    
    $hashLine = Get-Content $checksumFile | Where-Object { $_ -match [regex]::Escape($isoFile) }
    if ($hashLine) {
        $expectedHash = ($hashLine -split '\s+')[0].ToLower()
        $actualHash = (Get-FileHash -Algorithm $checksumAlgo $isoFile).Hash.ToLower()
        
        if ($expectedHash -eq $actualHash) {
            Write-LogSuccess "Checksum verification PASSED ($checksumAlgo)"
        } else {
            Exit-WithError "Checksum verification FAILED"
        }
    } else {
        Exit-WithError "Could not find checksum for $isoFile"
    }
    
    # Save checkpoint
    Save-Checkpoint -PreviousCheckpoint $prevCheckpoint `
                    -IsoFile $isoFile `
                    -ChecksumFile $checksumFile `
                    -GpgVerified $gpgVerified `
                    -SigningKey $signingKey
    
    # Final summary
    Write-Host
    Write-LogSuccess "Step completed successfully"
    Write-LogInfo "ISO verified: $isoFile"
    Write-LogInfo "Checksum file: $checksumFile"
    Write-LogInfo "Checksum verification: PASSED"
    Write-LogInfo "GPG verification: $(if ($gpgVerified) { 'PASSED' } else { 'SKIPPED' })"
    if ($signingKey) {
        Write-LogInfo "Signing key: $signingKey"
    }
    Write-LogInfo "Output files:"
    Write-LogInfo "  - $CHECKPOINT_FILE"
    
    # Exit with appropriate code
    if ((-not $gpgVerified) -and (-not $script:SkipGPG) -and (-not $script:ForceVerify)) {
        exit 1
    }
}

# ---------- execute ----------
Parse-Arguments -Args $args
Main