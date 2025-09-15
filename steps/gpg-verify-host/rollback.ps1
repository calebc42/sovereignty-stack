#!/usr/bin/env pwsh
# SPDX-License-Identifier: ISC
#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------- metadata ----------
$STEP = "gpg-verify-host"
$STEP_NUMBER = 2
$SCRIPT_VERSION = "1.0.0"
$CHECKPOINT_FILE = "$STEP.checkpoint.json"
$PREV_CHECKPOINT = "download-host.checkpoint.json"

# ---------- constants ----------
$CHECKPOINT_SCHEMA_VERSION = 1

# GPG keys that might have been imported
$DEBIAN_SIGNING_KEYS = @(
    "988021A964E6EA7D",  # Debian CD signing key
    "DA87E80D6294BE9B",  # Debian CD signing key
    "42468F4009EA8AC3"   # Debian Testing CDs Automatic Signing Key
)

# ---------- options ----------
$script:ForceMode = $false
$script:DryRun = $false
$script:Verbose = $false
$script:RemoveGPGKeys = $false

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

# ---------- utility functions ----------
function Test-Dependencies {
    $optionalMissing = @()
    
    if (-not (Get-Command gpg -ErrorAction SilentlyContinue)) {
        $optionalMissing += "gpg"
        Write-LogDebug "gpg not found - GPG key management unavailable"
    }
    
    if ($optionalMissing.Count -gt 0) {
        Write-LogDebug "Optional dependencies missing: $($optionalMissing -join ', ')"
    }
}

function Test-GpgInstalled {
    return (Get-Command gpg -ErrorAction SilentlyContinue) -ne $null
}

function Test-GpgKeyExists {
    param([string]$KeyId)
    
    if (-not (Test-GpgInstalled)) {
        return $false
    }
    
    try {
        $output = & gpg --list-keys $KeyId 2>&1
        return $LASTEXITCODE -eq 0
    } catch {
        return $false
    }
}

# ---------- rollback functions ----------
function Confirm-Action {
    param([string]$Action)
    
    if ($script:ForceMode) {
        return $true
    }
    
    $response = Read-Host "$Action [y/N]"
    return $response -match '^[yY]([eE][sS])?$'
}

function Remove-FileSafely {
    param(
        [string]$File,
        [string]$Description
    )
    
    if (-not (Test-Path $File)) {
        Write-LogDebug "$Description not found: $File"
        return @{ Success = $false; Action = "NotFound" }
    }
    
    if ((Get-Item $File).PSIsContainer) {
        Write-LogWarning "Skipping directory: $File"
        return @{ Success = $false; Action = "Skipped" }
    }
    
    Write-LogInfo "Found $Description`: $File"
    
    if (Confirm-Action -Action "Remove $Description '$File'?") {
        if ($script:DryRun) {
            Write-LogInfo "[DRY RUN] Would remove: $File"
            return @{ Success = $true; Action = "DryRun" }
        } else {
            try {
                Remove-Item $File -Force
                Write-LogSuccess "Removed: $File"
                return @{ Success = $true; Action = "Removed" }
            } catch {
                Write-LogError "Failed to remove: $File - $_"
                return @{ Success = $false; Action = "Failed" }
            }
        }
    } else {
        Write-LogInfo "Skipped: $File"
        return @{ Success = $false; Action = "Skipped" }
    }
}

function Remove-GpgKey {
    param([string]$KeyId)
    
    if (-not (Test-GpgInstalled)) {
        Write-LogDebug "Cannot remove GPG key - gpg not installed"
        return @{ Success = $false; Action = "NoGpg" }
    }
    
    if (-not (Test-GpgKeyExists -KeyId $KeyId)) {
        Write-LogDebug "GPG key not in keyring: $KeyId"
        return @{ Success = $false; Action = "NotFound" }
    }
    
    Write-LogInfo "Found GPG key in keyring: $KeyId"
    
    if (Confirm-Action -Action "Remove GPG key $KeyId?") {
        if ($script:DryRun) {
            Write-LogInfo "[DRY RUN] Would remove GPG key: $KeyId"
            return @{ Success = $true; Action = "DryRun" }
        } else {
            try {
                & gpg --batch --yes --delete-keys $KeyId 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    Write-LogSuccess "Removed GPG key: $KeyId"
                    return @{ Success = $true; Action = "Removed" }
                } else {
                    Write-LogError "Failed to remove GPG key: $KeyId"
                    return @{ Success = $false; Action = "Failed" }
                }
            } catch {
                Write-LogError "Failed to remove GPG key: $KeyId - $_"
                return @{ Success = $false; Action = "Failed" }
            }
        }
    } else {
        Write-LogInfo "Skipped GPG key: $KeyId"
        return @{ Success = $false; Action = "Skipped" }
    }
}

# ---------- argument parsing ----------
function Parse-Arguments {
    param(
        [switch]$Force,
        [switch]$DryRun,
        [switch]$Verbose,
        [switch]$RemoveGPGKeys,
        [switch]$Help
    )
    
    if ($Help) {
        Show-Help
        exit 0
    }
    
    $script:ForceMode = $Force
    $script:DryRun = $DryRun
    $script:Verbose = $Verbose
    $script:RemoveGPGKeys = $RemoveGPGKeys
    
    if ($script:ForceMode) {
        Write-LogInfo "Force mode enabled - no confirmation prompts"
    }
    
    if ($script:DryRun) {
        Write-LogInfo "Dry run mode - no changes will be made"
    }
    
    if ($script:RemoveGPGKeys) {
        Write-LogInfo "Will attempt to remove imported GPG keys"
    }
}

function Show-Help {
    Write-Host @"
Rollback script for $STEP (v$SCRIPT_VERSION)

Usage: .\rollback.ps1 [OPTIONS]

Options:
    -Force           Remove files without confirmation prompts
    -DryRun          Show what would be removed without actually removing
    -Verbose         Enable verbose output
    -RemoveGPGKeys   Also remove imported Debian GPG keys
    -Help            Show this help message

Description:
    This script removes artifacts created by the $STEP step.
    By default, it only removes the checkpoint file created by this step.
    
Files removed:
    - Checkpoint file ($CHECKPOINT_FILE)
    
Optional removals (with -RemoveGPGKeys):
    - Debian CD signing GPG keys imported during verification
    
Note:
    This step does not create new files, it only verifies existing ones.
    The main artifact is the checkpoint file that records verification status.
    GPG keys are preserved by default as they may be useful for other operations.

Safety features:
    - Confirmation prompt for each action (unless -Force is used)
    - Dry run mode to preview changes
    - GPG keys preserved by default

Examples:
    .\rollback.ps1                         # Interactive mode
    .\rollback.ps1 -Force                  # Remove checkpoint without confirmation
    .\rollback.ps1 -RemoveGPGKeys          # Also remove GPG keys
    .\rollback.ps1 -DryRun -RemoveGPGKeys  # Preview all changes

"@
}

# ---------- main workflow ----------
function Main {
    param(
        [switch]$Force,
        [switch]$DryRun,
        [switch]$Verbose,
        [switch]$RemoveGPGKeys,
        [switch]$Help
    )
    
    # Parse arguments
    Parse-Arguments -Force:$Force -DryRun:$DryRun -Verbose:$Verbose -RemoveGPGKeys:$RemoveGPGKeys -Help:$Help
    
    Write-LogInfo "Starting rollback for $STEP"
    
    if ($script:DryRun) {
        Write-LogInfo "DRY RUN MODE - No changes will actually be made"
    }
    
    # Check dependencies
    Test-Dependencies
    
    # Initialize statistics
    $stats = @{
        FilesRemoved = 0
        FilesSkipped = 0
        FilesFailed = 0
        GPGKeysRemoved = 0
        GPGKeysSkipped = 0
        GPGKeysFailed = 0
    }
    
    # Remove checkpoint file
    if (Test-Path $CHECKPOINT_FILE) {
        $result = Remove-FileSafely -File $CHECKPOINT_FILE -Description "checkpoint file"
        
        switch ($result.Action) {
            "Removed" { $stats.FilesRemoved++ }
            "DryRun" { $stats.FilesRemoved++ }
            "Skipped" { $stats.FilesSkipped++ }
            "Failed" { $stats.FilesFailed++ }
        }
    } else {
        Write-LogInfo "No checkpoint file found: $CHECKPOINT_FILE"
        Write-LogInfo "Step may not have been completed"
    }
    
    # Optionally remove GPG keys
    if ($script:RemoveGPGKeys) {
        Write-LogInfo ""
        Write-LogInfo "Processing GPG keys..."
        
        if (-not (Test-GpgInstalled)) {
            Write-LogWarning "Cannot remove GPG keys - gpg not installed"
        } else {
            foreach ($keyId in $DEBIAN_SIGNING_KEYS) {
                $result = Remove-GpgKey -KeyId $keyId
                
                switch ($result.Action) {
                    "Removed" { $stats.GPGKeysRemoved++ }
                    "DryRun" { $stats.GPGKeysRemoved++ }
                    "Skipped" { $stats.GPGKeysSkipped++ }
                    "Failed" { $stats.GPGKeysFailed++ }
                    "NotFound" { Write-LogDebug "Key not in keyring: $keyId" }
                }
            }
        }
    } else {
        Write-LogDebug "Preserving GPG keys (use -RemoveGPGKeys to remove them)"
    }
    
    # Check if any GPG keys remain (for informational purposes)
    $remainingKeys = @()
    if ((Test-GpgInstalled) -and (-not $script:RemoveGPGKeys)) {
        foreach ($keyId in $DEBIAN_SIGNING_KEYS) {
            if (Test-GpgKeyExists -KeyId $keyId) {
                $remainingKeys += $keyId
            }
        }
    }
    
    # Summary
    Write-Host
    Write-LogSuccess "Rollback completed"
    
    # File statistics
    if (($stats.FilesRemoved + $stats.FilesSkipped + $stats.FilesFailed) -gt 0) {
        Write-LogInfo "Files removed: $($stats.FilesRemoved)"
        if ($stats.FilesSkipped -gt 0) {
            Write-LogInfo "Files skipped: $($stats.FilesSkipped)"
        }
        if ($stats.FilesFailed -gt 0) {
            Write-LogWarning "Files failed: $($stats.FilesFailed)"
        }
    }
    
    # GPG key statistics
    if ($script:RemoveGPGKeys) {
        Write-LogInfo "GPG keys removed: $($stats.GPGKeysRemoved)"
        if ($stats.GPGKeysSkipped -gt 0) {
            Write-LogInfo "GPG keys skipped: $($stats.GPGKeysSkipped)"
        }
        if ($stats.GPGKeysFailed -gt 0) {
            Write-LogWarning "GPG keys failed: $($stats.GPGKeysFailed)"
        }
    }
    
    if ($script:DryRun) {
        Write-LogInfo ""
        Write-LogInfo "This was a dry run - no changes were actually made"
        Write-LogInfo "Run without -DryRun to perform the actual rollback"
    }
    
    # Note about remaining GPG keys
    if ($remainingKeys.Count -gt 0) {
        Write-LogInfo ""
        Write-LogInfo "Note: $($remainingKeys.Count) Debian GPG key(s) remain in keyring"
        Write-LogInfo "To remove them, run: .\rollback.ps1 -RemoveGPGKeys"
    }
}

# ---------- execute ----------
# Call Main with script parameters
Main @PSBoundParameters
exit 0