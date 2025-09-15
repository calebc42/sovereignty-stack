#!/usr/bin/env pwsh
# SPDX-License-Identifier: ISC
#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------- metadata ----------
$STEP = "download-host"
$STEP_NUMBER = 1
$SCRIPT_VERSION = "1.0.0"
$CHECKPOINT_FILE = "$STEP.checkpoint.json"

# ---------- constants ----------
$CHECKPOINT_SCHEMA_VERSION = 1

# ---------- options ----------
$script:ForceMode = $false
$script:DryRun = $false
$script:Verbose = $false

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
function Format-Bytes {
    param([long]$Bytes)
    
    if ($Bytes -gt 1GB) {
        return "$([math]::Round($Bytes / 1GB, 2)) GB"
    } elseif ($Bytes -gt 1MB) {
        return "$([math]::Round($Bytes / 1MB, 2)) MB"
    } elseif ($Bytes -gt 1KB) {
        return "$([math]::Round($Bytes / 1KB, 2)) KB"
    } else {
        return "$Bytes B"
    }
}

function Test-Dependencies {
    # No required dependencies for rollback
    Write-LogDebug "All dependencies satisfied"
}

# ---------- checkpoint functions ----------
function Read-Checkpoint {
    param([string]$CheckpointFile)
    
    if (-not (Test-Path $CheckpointFile)) {
        return $null
    }
    
    try {
        $content = Get-Content $CheckpointFile -Raw | ConvertFrom-Json
        
        # Validate schema version
        if ($content.schema_version -ne $CHECKPOINT_SCHEMA_VERSION) {
            Write-LogWarning "Checkpoint schema version mismatch (expected: $CHECKPOINT_SCHEMA_VERSION, found: $($content.schema_version))"
        }
        
        return $content
    } catch {
        Write-LogWarning "Invalid JSON in checkpoint file: $CheckpointFile"
        return $null
    }
}

function Get-ArtifactFiles {
    param([object]$Checkpoint)
    
    if (-not $Checkpoint -or -not $Checkpoint.artifacts) {
        return @()
    }
    
    $files = @()
    
    # Extract artifact names from the checkpoint
    $artifactNames = $Checkpoint.artifacts | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name
    foreach ($name in $artifactNames) {
        $files += $name
    }
    
    return $files
}

# ---------- rollback functions ----------
function Confirm-Removal {
    param(
        [string]$File,
        [string]$Description
    )
    
    if ($script:ForceMode) {
        return $true
    }
    
    $response = Read-Host "Remove $Description '$File'? [y/N]"
    return $response -match '^[yY]([eE][sS])?$'
}

function Remove-FileSafely {
    param(
        [string]$File,
        [string]$Description
    )
    
    if (-not (Test-Path $File)) {
        Write-LogDebug "$Description not found: $File"
        return @{
            Success = $false
            SizeRemoved = 0
            Action = "NotFound"
        }
    }
    
    if ((Get-Item $File).PSIsContainer) {
        Write-LogWarning "Skipping directory: $File"
        return @{
            Success = $false
            SizeRemoved = 0
            Action = "Skipped"
        }
    }
    
    # Get file size for statistics
    $fileSize = (Get-Item $File).Length
    
    Write-LogInfo "Found $Description`: $File ($(Format-Bytes $fileSize))"
    
    if (Confirm-Removal -File $File -Description $Description) {
        if ($script:DryRun) {
            Write-LogInfo "[DRY RUN] Would remove: $File"
            return @{
                Success = $true
                SizeRemoved = $fileSize
                Action = "DryRun"
            }
        } else {
            try {
                Remove-Item $File -Force
                Write-LogSuccess "Removed: $File"
                return @{
                    Success = $true
                    SizeRemoved = $fileSize
                    Action = "Removed"
                }
            } catch {
                Write-LogError "Failed to remove: $File - $_"
                return @{
                    Success = $false
                    SizeRemoved = 0
                    Action = "Failed"
                }
            }
        }
    } else {
        Write-LogInfo "Skipped: $File"
        return @{
            Success = $false
            SizeRemoved = 0
            Action = "Skipped"
        }
    }
}

function Find-OrphanedFiles {
    $orphaned = @()
    
    # Check for common artifact patterns
    $patterns = @(
        "debian-*.iso",
        "SHA256SUMS",
        "SHA256SUMS.sign",
        "SHA512SUMS",
        "SHA512SUMS.sign"
    )
    
    foreach ($pattern in $patterns) {
        $files = Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue
        if ($files) {
            $orphaned += $files
        }
    }
    
    return $orphaned
}

# ---------- argument parsing ----------
function Parse-Arguments {
    param(
        [switch]$Force,
        [switch]$DryRun,
        [switch]$Verbose,
        [switch]$Help
    )
    
    if ($Help) {
        Show-Help
        exit 0
    }
    
    $script:ForceMode = $Force
    $script:DryRun = $DryRun
    $script:Verbose = $Verbose
    
    if ($script:ForceMode) {
        Write-LogInfo "Force mode enabled - no confirmation prompts"
    }
    
    if ($script:DryRun) {
        Write-LogInfo "Dry run mode - no files will be removed"
    }
}

function Show-Help {
    Write-Host @"
Rollback script for $STEP (v$SCRIPT_VERSION)

Usage: .\rollback.ps1 [OPTIONS]

Options:
    -Force      Remove files without confirmation prompts
    -DryRun     Show what would be removed without actually removing
    -Verbose    Enable verbose output
    -Help       Show this help message

Description:
    This script removes all artifacts created by the $STEP step.
    It reads the checkpoint file to determine what files to remove.
    
Files that will be removed:
    - Downloaded ISO file
    - Checksum files (SHA256SUMS, SHA512SUMS)
    - Signature files (*.sign)
    - Checkpoint file ($CHECKPOINT_FILE)

Safety features:
    - Confirmation prompt for each file (unless -Force is used)
    - Dry run mode to preview changes
    - Only removes files, not directories
    - Validates checkpoint before processing

Examples:
    .\rollback.ps1                    # Interactive mode with confirmations
    .\rollback.ps1 -Force             # Remove all files without confirmation
    .\rollback.ps1 -DryRun            # Preview what would be removed
    .\rollback.ps1 -Force -Verbose    # Force removal with detailed output

"@
}

# ---------- main workflow ----------
function Main {
    param(
        [switch]$Force,
        [switch]$DryRun,
        [switch]$Verbose,
        [switch]$Help
    )
    
    # Parse arguments
    Parse-Arguments -Force:$Force -DryRun:$DryRun -Verbose:$Verbose -Help:$Help
    
    Write-LogInfo "Starting rollback for $STEP"
    
    if ($script:DryRun) {
        Write-LogInfo "DRY RUN MODE - No files will actually be removed"
    }
    
    # Check dependencies
    Test-Dependencies
    
    # Initialize statistics
    $stats = @{
        RemovedCount = 0
        SkippedCount = 0
        FailedCount = 0
        NotFoundCount = 0
        TotalSizeRemoved = 0
    }
    
    # Check if checkpoint exists
    if (-not (Test-Path $CHECKPOINT_FILE)) {
        Write-LogInfo "No checkpoint file found: $CHECKPOINT_FILE"
        Write-LogInfo "Step may not have been completed - checking for orphaned files..."
        
        # Check for orphaned files
        $orphanedFiles = Find-OrphanedFiles
        
        if ($orphanedFiles.Count -gt 0) {
            Write-LogWarning "Found $($orphanedFiles.Count) file(s) that might be from this step:"
            foreach ($file in $orphanedFiles) {
                Write-LogInfo "  - $($file.Name)"
            }
            Write-LogInfo ""
            Write-LogInfo "To remove these files, run:"
            Write-LogInfo "  .\rollback.ps1 -Force"
            Write-LogInfo "after creating a checkpoint or manually review each file"
        } else {
            Write-LogInfo "No orphaned files found - nothing to rollback"
        }
        
        exit 0
    }
    
    # Load checkpoint
    Write-LogInfo "Loading checkpoint: $CHECKPOINT_FILE"
    $checkpoint = Read-Checkpoint -CheckpointFile $CHECKPOINT_FILE
    
    if (-not $checkpoint) {
        Write-LogWarning "Could not validate checkpoint file"
        if (-not $script:ForceMode) {
            if (-not (Confirm-Removal -File $CHECKPOINT_FILE -Description "invalid checkpoint file")) {
                Exit-WithError "Aborting rollback due to invalid checkpoint"
            }
        }
    }
    
    # Process artifacts from checkpoint
    Write-LogInfo "Processing artifacts from checkpoint..."
    $artifactFiles = Get-ArtifactFiles -Checkpoint $checkpoint
    
    foreach ($artifact in $artifactFiles) {
        if (-not $artifact) { continue }
        
        # Try to find the artifact in different locations
        $possibleLocations = @(
            $artifact,
            (Join-Path (Get-Location) $artifact)
        )
        
        # Add location from checkpoint if available
        if ($checkpoint.artifacts.$artifact.location) {
            $possibleLocations += (Join-Path $checkpoint.artifacts.$artifact.location $artifact)
        }
        
        $found = $false
        foreach ($location in $possibleLocations) {
            if (Test-Path $location) {
                $result = Remove-FileSafely -File $location -Description "ISO artifact"
                
                switch ($result.Action) {
                    "Removed" { $stats.RemovedCount++; $stats.TotalSizeRemoved += $result.SizeRemoved }
                    "DryRun" { $stats.RemovedCount++; $stats.TotalSizeRemoved += $result.SizeRemoved }
                    "Skipped" { $stats.SkippedCount++ }
                    "Failed" { $stats.FailedCount++ }
                }
                
                $found = $true
                break
            }
        }
        
        if (-not $found) {
            Write-LogDebug "Artifact not found in any location: $artifact"
            $stats.NotFoundCount++
        }
    }
    
    # Remove checksum and signature files
    Write-LogInfo "Processing checksum and signature files..."
    $additionalFiles = @("SHA256SUMS", "SHA256SUMS.sign", "SHA512SUMS", "SHA512SUMS.sign")
    
    foreach ($file in $additionalFiles) {
        if (Test-Path $file) {
            $result = Remove-FileSafely -File $file -Description "checksum/signature file"
            
            switch ($result.Action) {
                "Removed" { $stats.RemovedCount++; $stats.TotalSizeRemoved += $result.SizeRemoved }
                "DryRun" { $stats.RemovedCount++; $stats.TotalSizeRemoved += $result.SizeRemoved }
                "Skipped" { $stats.SkippedCount++ }
                "Failed" { $stats.FailedCount++ }
            }
        }
    }
    
    # Remove checkpoint file last
    if (Test-Path $CHECKPOINT_FILE) {
        $result = Remove-FileSafely -File $CHECKPOINT_FILE -Description "checkpoint file"
        
        switch ($result.Action) {
            "Removed" { $stats.RemovedCount++ }
            "DryRun" { $stats.RemovedCount++ }
            "Skipped" { $stats.SkippedCount++ }
            "Failed" { $stats.FailedCount++ }
        }
    }
    
    # Summary
    Write-Host
    Write-LogSuccess "Rollback completed"
    Write-LogInfo "Files removed: $($stats.RemovedCount)"
    Write-LogInfo "Files skipped: $($stats.SkippedCount)"
    
    if ($stats.FailedCount -gt 0) {
        Write-LogWarning "Files failed: $($stats.FailedCount)"
    }
    
    if ($stats.NotFoundCount -gt 0) {
        Write-LogDebug "Files not found: $($stats.NotFoundCount)"
    }
    
    if ($stats.RemovedCount -gt 0) {
        Write-LogInfo "Total space freed: $(Format-Bytes $stats.TotalSizeRemoved)"
    }
    
    if ($script:DryRun) {
        Write-LogInfo ""
        Write-LogInfo "This was a dry run - no files were actually removed"
        Write-LogInfo "Run without -DryRun to perform the actual rollback"
    }
}

# ---------- execute ----------
# Call Main with script parameters
Main @PSBoundParameters
exit 0