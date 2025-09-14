#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$step = "debian-host"
$jsonPath = "sovereignty-chain.$step.json"

function Log {
    param([string]$Message, [string]$Color = "White")
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Message" -ForegroundColor $Color
}

function Remove-SafelyWithConfirmation {
    param([string]$Path, [string]$Description)
    
    if (Test-Path $Path) {
        Log "Found $Description`: $Path" "Yellow"
        
        if ($Force) {
            Log "Removing $Description (forced)..." "Red"
            Remove-Item $Path -Force
            Log "Removed: $Path" "Green"
            return $true
        } else {
            $response = Read-Host "Remove $Description? (y/N)"
            if ($response -match '^[yY]') {
                Remove-Item $Path -Force
                Log "Removed: $Path" "Green"
                return $true
            } else {
                Log "Skipped: $Path" "Cyan"
                return $false
            }
        }
    } else {
        Log "$Description not found: $Path" "Gray"
        return $false
    }
}

# Parse command line arguments
param(
    [switch]$Force,
    [switch]$Help
)

if ($Help) {
    Write-Host @"
Rollback script for $step

Usage: .\rollback.ps1 [-Force] [-Help]

Options:
  -Force    Remove files without confirmation
  -Help     Show this help message

This script reads sovereignty-chain.$step.json to determine what files to remove.
Without -Force, it will ask for confirmation before removing each file.
"@
    exit 0
}

try {
    Log "Starting rollback for step: $step"
    
    # Check if baton file exists
    if (-not (Test-Path $jsonPath)) {
        Log "No baton file found: $jsonPath" "Yellow"
        Log "Nothing to rollback - step may not have been completed" "Yellow"
        exit 0
    }
    
    # Read and parse baton
    Log "Reading baton file: $jsonPath"
    $baton = Get-Content $jsonPath -Raw | ConvertFrom-Json
    
    if (-not $baton.artefacts) {
        Log "No artefacts found in baton file" "Yellow"
        exit 0
    }
    
    Log "Found $($baton.artefacts.PSObject.Properties.Count) artefact(s) to potentially remove"
    
    # Track what we actually remove
    $removedFiles = @()
    $skippedFiles = @()
    
    # Remove each artefact
    foreach ($artefactName in $baton.artefacts.PSObject.Properties.Name) {
        $artefact = $baton.artefacts.$artefactName
        
        # Try different possible locations
        $possiblePaths = @(
            $artefactName,  # Current directory
            (Join-Path (Get-Location) $artefactName),  # Explicit current directory
            $artefact.location ? (Join-Path $artefact.location $artefactName) : $null  # Location from baton
        ) | Where-Object { $_ -ne $null }
        
        $found = $false
        foreach ($path in $possiblePaths) {
            if (Test-Path $path) {
                if (Remove-SafelyWithConfirmation $path "ISO file") {
                    $removedFiles += $path
                } else {
                    $skippedFiles += $path
                }
                $found = $true
                break
            }
        }
        
        if (-not $found) {
            Log "Artefact not found in any expected location: $artefactName" "Gray"
        }
    }
    
    # Remove checksum files (common patterns)
    $checksumFiles = @("SHA256SUMS", "SHA512SUMS")
    foreach ($checksumFile in $checksumFiles) {
        if (Remove-SafelyWithConfirmation $checksumFile "checksum file") {
            $removedFiles += $checksumFile
        } else {
            $skippedFiles += $checksumFile
        }
    }
    
    # Remove the baton file itself
    if (Remove-SafelyWithConfirmation $jsonPath "baton file") {
        $removedFiles += $jsonPath
    } else {
        $skippedFiles += $jsonPath
    }
    
    # Summary
    Log "" 
    Log "Rollback completed!" "Green"
    Log "Removed files: $($removedFiles.Count)" "Green"
    if ($removedFiles.Count -gt 0) {
        $removedFiles | ForEach-Object { Log "  - $_" "Green" }
    }
    
    if ($skippedFiles.Count -gt 0) {
        Log "Skipped files: $($skippedFiles.Count)" "Yellow"
        $skippedFiles | ForEach-Object { Log "  - $_" "Yellow" }
    }

} catch {
    Log "Error during rollback: $($_.Exception.Message)" "Red"
    exit 1
}