#!/usr/bin/env pwsh
# SPDX-License-Identifier: ISC
#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------- metadata ----------
$STEP = "download-host"
$STEP_NUMBER = 1
$SCRIPT_VERSION = "1.0.0"
$BASE_URL = "https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/"

# ---------- constants ----------
$DEFAULT_CONNECT_TIMEOUT = 30
$DEFAULT_MAX_TIME = 3600
$CHECKPOINT_SCHEMA_VERSION = 1
$CHECKPOINT_FILE = "$STEP.checkpoint.json"

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
    $missingDeps = @()
    
    # Check for required PowerShell version
    if ($PSVersionTable.PSVersion.Major -lt 5) {
        $missingDeps += "PowerShell 5.0+"
    }
    
    # Check for optional commands
    $optionalCommands = @{
        "jq" = "JSON processing will use PowerShell native methods"
    }
    
    foreach ($cmd in $optionalCommands.Keys) {
        if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
            Write-LogDebug "$cmd not found - $($optionalCommands[$cmd])"
        }
    }
    
    if ($missingDeps.Count -gt 0) {
        Exit-WithError "Missing required dependencies: $($missingDeps -join ', ')"
    }
}

# ---------- checkpoint functions ----------
function Save-Checkpoint {
    param(
        [string]$IsoName,
        [string]$IsoVersion,
        [string]$IsoUrl,
        [string]$Sha256Hash,
        [string]$Sha512Hash = $null,
        [bool]$Verified = $false,
        [string]$ChecksumFile = $null
    )
    
    $isoSize = if (Test-Path $IsoName) {
        (Get-Item $IsoName).Length
    } else {
        0
    }
    
    $checkpoint = @{
        schema_version = $CHECKPOINT_SCHEMA_VERSION
        step = $STEP
        step_number = $STEP_NUMBER
        script_version = $SCRIPT_VERSION
        created_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        hostname = $env:COMPUTERNAME
        artifacts = @{
            $IsoName = @{
                type = "debian-iso"
                sha256 = $Sha256Hash.ToLower()
                sha512 = if ($Sha512Hash) { $Sha512Hash.ToLower() } else { $null }
                url = $IsoUrl
                version = $IsoVersion
                verified = $Verified
                checksum_file = $ChecksumFile
                location = (Get-Location).Path
                size_bytes = $isoSize
                size_human = Format-Bytes $isoSize
            }
        }
        metadata = @{
            base_url = $BASE_URL
            download_completed = $true
        }
    }
    
    $checkpoint | ConvertTo-Json -Depth 10 | Out-File -FilePath $CHECKPOINT_FILE -Encoding UTF8 -NoNewline
    Write-LogInfo "Checkpoint saved: $CHECKPOINT_FILE"
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

# ---------- download functions ----------
function Find-LatestIso {
    Write-LogInfo "Discovering latest Debian ISO from: $BASE_URL"
    
    try {
        $response = Invoke-WebRequest -Uri $BASE_URL -UseBasicParsing -TimeoutSec $DEFAULT_CONNECT_TIMEOUT
        $indexPage = $response.Content
    } catch {
        Exit-WithError "Failed to fetch directory listing from $BASE_URL : $_"
    }
    
    $isoMatches = $indexPage | Select-String -Pattern 'debian-[0-9.]*-amd64-netinst\.iso' -AllMatches
    
    if (-not $isoMatches -or $isoMatches.Matches.Count -eq 0) {
        Exit-WithError "Could not find any Debian netinst ISO in directory listing"
    }
    
    # Sort by version number properly
    $isoName = $isoMatches.Matches | 
               Sort-Object { 
                   $version = $_.Value -replace 'debian-([0-9.]+)-.*', '$1'
                   [version]$version 
               } -Descending |
               Select-Object -First 1 -ExpandProperty Value
    
    Write-LogInfo "Discovered: $isoName"
    return $isoName
}

function Test-ExistingFile {
    param(
        [string]$File,
        [string]$Url
    )
    
    if (-not (Test-Path $File)) {
        return $false
    }
    
    Write-LogInfo "Found existing file: $File"
    Write-LogInfo "Verifying file integrity..."
    
    try {
        $headResponse = Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing -TimeoutSec $DEFAULT_CONNECT_TIMEOUT
        $expectedSize = [long]$headResponse.Headers.'Content-Length'[0]
        $actualSize = (Get-Item $File).Length
        
        if ($actualSize -eq $expectedSize) {
            Write-LogInfo "File size matches server ($(Format-Bytes $actualSize))"
            return $true
        } else {
            Write-LogWarning "File size mismatch (local: $(Format-Bytes $actualSize), server: $(Format-Bytes $expectedSize))"
            Write-LogInfo "Removing incomplete file and re-downloading..."
            Remove-Item $File -Force
            return $false
        }
    } catch {
        Write-LogWarning "Could not verify file size with server - will re-download"
        return $false
    }
}

function Invoke-DownloadWithProgress {
    param(
        [string]$Url,
        [string]$OutputFile
    )
    
    $tempFile = "$OutputFile.downloading"
    
    Write-LogInfo "Starting download: $(Split-Path $OutputFile -Leaf)"
    Write-LogInfo "Source URL: $Url"
    
    $webClient = New-Object System.Net.WebClient
    
    try {
        # Register progress event
        $progressEvent = Register-ObjectEvent -InputObject $webClient -EventName "DownloadProgressChanged" -Action {
            $percent = $Event.SourceEventArgs.ProgressPercentage
            $received = $Event.SourceEventArgs.BytesReceived
            $total = $Event.SourceEventArgs.TotalBytesToReceive
            
            $receivedStr = Format-Bytes $received
            $totalStr = Format-Bytes $total
            
            Write-Progress -Activity "Downloading $(Split-Path $OutputFile -Leaf)" `
                          -Status "$receivedStr / $totalStr" `
                          -PercentComplete $percent
        }
        
        $webClient.DownloadFile($Url, (Join-Path (Get-Location) $tempFile))
        Write-Progress -Activity "Downloading $(Split-Path $OutputFile -Leaf)" -Completed
        
        # Atomic move to final location
        Move-Item $tempFile $OutputFile -Force
        
        $finalSize = (Get-Item $OutputFile).Length
        Write-LogInfo "Download completed: $(Format-Bytes $finalSize)"
    } catch {
        if (Test-Path $tempFile) { 
            Remove-Item $tempFile -Force 
        }
        Exit-WithError "Download failed: $Url - $_"
    } finally {
        $webClient.Dispose()
        if ($progressEvent) {
            Unregister-Event -SourceIdentifier $progressEvent.Name -ErrorAction SilentlyContinue
        }
        Get-EventSubscriber | Where-Object { $_.SourceObject -is [System.Net.WebClient] } | Unregister-Event -ErrorAction SilentlyContinue
    }
}

function Get-Checksums {
    param([string]$BaseUrl)
    
    $checksumFile = $null
    $checksumAlgo = $null
    
    # Try SHA512SUMS first (more secure), then SHA256SUMS
    foreach ($hashType in @("SHA512SUMS", "SHA256SUMS")) {
        Write-LogInfo "Attempting to download: $hashType"
        $checksumUrl = "$BaseUrl$hashType"
        
        try {
            Invoke-WebRequest -Uri $checksumUrl -OutFile $hashType -UseBasicParsing -TimeoutSec $DEFAULT_CONNECT_TIMEOUT
            $checksumFile = $hashType
            $checksumAlgo = $hashType -replace 'SUMS', ''
            Write-LogInfo "Successfully downloaded: $hashType"
            
            # Try to download signature file
            $signUrl = "$checksumUrl.sign"
            Write-LogInfo "Attempting to download signature: $hashType.sign"
            
            try {
                Invoke-WebRequest -Uri $signUrl -OutFile "$hashType.sign" -UseBasicParsing -TimeoutSec $DEFAULT_CONNECT_TIMEOUT
                Write-LogInfo "Successfully downloaded: $hashType.sign"
            } catch {
                Write-LogWarning "Could not download signature file: $hashType.sign"
                Write-LogWarning "GPG verification will not be available without signature"
            }
            
            break
        } catch {
            Write-LogWarning "Could not download: $hashType"
        }
    }
    
    if (-not $checksumFile) {
        Write-LogWarning "No checksum files could be downloaded"
        return $null
    }
    
    return @{
        File = $checksumFile
        Algorithm = $checksumAlgo
    }
}

function Test-Checksum {
    param(
        [string]$File,
        [string]$ChecksumFile,
        [string]$Algorithm
    )
    
    if (-not (Test-Path $ChecksumFile)) {
        Write-LogWarning "Checksum file not found: $ChecksumFile"
        return $false
    }
    
    Write-LogInfo "Verifying $Algorithm checksum for: $(Split-Path $File -Leaf)"
    
    $hashLine = Get-Content $ChecksumFile | Where-Object { $_ -match [regex]::Escape((Split-Path $File -Leaf)) }
    
    if (-not $hashLine) {
        Write-LogWarning "Could not find checksum for $(Split-Path $File -Leaf) in $ChecksumFile"
        return $false
    }
    
    $expectedHash = ($hashLine -split '\s+')[0].ToLower()
    $actualHash = (Get-FileHash -Algorithm $Algorithm $File).Hash.ToLower()
    
    if ($expectedHash -eq $actualHash) {
        Write-LogSuccess "Checksum verification PASSED ($Algorithm)"
        return $true
    } else {
        Write-LogError "Checksum verification FAILED ($Algorithm)"
        Write-LogError "Expected: $expectedHash"
        Write-LogError "Actual:   $actualHash"
        return $false
    }
}

# ---------- main workflow ----------
function Main {
    Write-LogInfo "Starting $STEP (v$SCRIPT_VERSION)"
    Write-LogInfo "Working directory: $(Get-Location)"
    
    # Check dependencies
    Test-Dependencies
    
    # Discover latest ISO
    $isoName = Find-LatestIso
    $isoUrl = "$BASE_URL$isoName"
    $isoVersion = $isoName -replace '^debian-([0-9.]+)-.*', '$1'
    
    Write-LogInfo "Target ISO: $isoName (version $isoVersion)"
    
    # Check if ISO already exists and is complete
    $needDownload = -not (Test-ExistingFile -File $isoName -Url $isoUrl)
    
    if (-not $needDownload) {
        Write-LogInfo "Using existing ISO file"
    }
    
    # Download ISO if needed
    if ($needDownload) {
        Invoke-DownloadWithProgress -Url $isoUrl -OutputFile $isoName
    }
    
    # Check for existing valid checksum files
    $checksumInfo = $null
    $needChecksum = $true
    
    foreach ($hashType in @("SHA512SUMS", "SHA256SUMS")) {
        if ((Test-Path $hashType)) {
            $content = Get-Content $hashType -ErrorAction SilentlyContinue
            if ($content -and ($content | Where-Object { $_ -match [regex]::Escape($isoName) })) {
                $checksumInfo = @{
                    File = $hashType
                    Algorithm = $hashType -replace 'SUMS', ''
                }
                $needChecksum = $false
                Write-LogInfo "Found existing checksum file: $hashType"
                break
            }
        }
    }
    
    # Download checksums if needed
    if ($needChecksum) {
        $checksumInfo = Get-Checksums -BaseUrl $BASE_URL
    }
    
    # Verify checksum
    $verified = $false
    if ($checksumInfo) {
        $verified = Test-Checksum -File $isoName `
                                  -ChecksumFile $checksumInfo.File `
                                  -Algorithm $checksumInfo.Algorithm
    }
    
    # Calculate hashes for checkpoint
    $sha256Hash = (Get-FileHash -Algorithm SHA256 $isoName).Hash
    $sha512Hash = $null
    
    if ($checksumInfo.Algorithm -eq 'SHA512' -or (Test-Path "SHA512SUMS")) {
        $sha512Hash = (Get-FileHash -Algorithm SHA512 $isoName).Hash
    }
    
    # Save checkpoint
    Save-Checkpoint -IsoName $isoName `
                    -IsoVersion $isoVersion `
                    -IsoUrl $isoUrl `
                    -Sha256Hash $sha256Hash `
                    -Sha512Hash $sha512Hash `
                    -Verified $verified `
                    -ChecksumFile $checksumInfo.File
    
    # Final summary
    $fileSize = (Get-Item $isoName).Length
    
    Write-Host
    Write-LogSuccess "Step completed successfully"
    Write-LogInfo "ISO file: $isoName"
    Write-LogInfo "Version: $isoVersion"
    Write-LogInfo "Size: $(Format-Bytes $fileSize)"
    Write-LogInfo "Checksum verified: $(if ($verified) { 'Yes' } else { 'No' })"
    Write-LogInfo "Output files:"
    Write-LogInfo "  - $isoName"
    if ($checksumInfo) {
        Write-LogInfo "  - $($checksumInfo.File)"
        if (Test-Path "$($checksumInfo.File).sign") {
            Write-LogInfo "  - $($checksumInfo.File).sign"
        }
    }
    Write-LogInfo "  - $CHECKPOINT_FILE"
}

# ---------- execute ----------
$script:Verbose = $false
Main