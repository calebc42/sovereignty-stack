#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$step = "download-debian"
# Change your base URL to a different mirror:
$baseUrl = "http://mirror.keystealth.org/debian-cd/current/amd64/iso-cd/"

function Write-Log {
    param([string]$Message)
    Write-Host "[$((Get-Date).ToString('HH:mm:ss'))] $Message"
}

function Write-Error-Log {
    param([string]$Message)
    Write-Host "[$((Get-Date).ToString('HH:mm:ss'))] [ERROR] $Message" -ForegroundColor Red
}

try {
    # --- discover latest version ---
    Write-Log "Discovering latest Debian version..."
    $indexPage = (Invoke-WebRequest -Uri $baseUrl -UseBasicParsing -TimeoutSec 30).Content
    $isoMatches = $indexPage | Select-String -Pattern 'debian-[0-9.]*-amd64-netinst\.iso' -AllMatches
    
    if (-not $isoMatches -or $isoMatches.Matches.Count -eq 0) {
        throw "Could not find Debian netinst ISO in directory listing"
    }
    
    # Get the latest version (sort by version number properly)
    $isoName = $isoMatches.Matches | 
               Sort-Object { 
                   $version = $_.Value -replace 'debian-([0-9.]+)-.*', '$1'
                   [version]$version 
               } -Descending |
               Select-Object -First 1 -ExpandProperty Value
    
    $isoUrl = $baseUrl + $isoName
    $isoVersion = $isoName -replace '^debian-([0-9.]+)-.*', '$1'
    Write-Log "Found: $isoName (version $isoVersion)"
    
    # --- check existing files and their integrity ---
    $skipDownload = $false
    $skipChecksum = $false
    
    if (Test-Path $isoName) {
        Write-Log "File exists: $isoName, checking integrity..."
        
        # Check file size against server
        try {
            $headResponse = Invoke-WebRequest -Uri $isoUrl -Method Head -UseBasicParsing -TimeoutSec 30
            $expectedSize = [long]$headResponse.Headers.'Content-Length'[0]
            $actualSize = (Get-Item $isoName).Length
            
            if ($actualSize -eq $expectedSize) {
                $sizeStr = if ($actualSize -gt 1GB) { "$([math]::Round($actualSize / 1GB, 1))G" }
                          elseif ($actualSize -gt 1MB) { "$([math]::Round($actualSize / 1MB))M" }
                          elseif ($actualSize -gt 1KB) { "$([math]::Round($actualSize / 1KB))K" }
                          else { "${actualSize}B" }
                Write-Log "File size matches server ($sizeStr)"
                $skipDownload = $true
            } else {
                $localSize = if ($actualSize -gt 1GB) { "$([math]::Round($actualSize / 1GB, 1))G" }
                            elseif ($actualSize -gt 1MB) { "$([math]::Round($actualSize / 1MB))M" }
                            else { "${actualSize}B" }
                $serverSize = if ($expectedSize -gt 1GB) { "$([math]::Round($expectedSize / 1GB, 1))G" }
                             elseif ($expectedSize -gt 1MB) { "$([math]::Round($expectedSize / 1MB))M" }
                             else { "${expectedSize}B" }
                Write-Log "File size mismatch (local: $localSize, server: $serverSize)"
                Remove-Item $isoName -Force
            }
        }
        catch {
            Write-Log "Warning: Could not verify file size with server"
            return $false  # Re-download
        }
    }
    
    # Check if we have valid checksum files
    $hashFile = $null
    $hashAlgorithm = $null
    
    foreach ($hash in @("SHA512SUMS", "SHA256SUMS")) {
        if (Test-Path $hash) {
            $content = Get-Content $hash -ErrorAction SilentlyContinue
            if ($content -and ($content | Where-Object { $_ -match [regex]::Escape($isoName) })) {
                $hashFile = $hash
                $hashAlgorithm = $hash -replace 'SUMS', ''
                $skipChecksum = $true
                Write-Log "Found valid checksum file: $hashFile"
                break
            }
        }
    }
    
    # --- download ISO with progress and resume support ---
    if (-not $skipDownload) {
        Write-Log "Downloading: $isoName"
        
        $tempFile = "$isoName.tmp"
        $webClient = New-Object System.Net.WebClient
        try {
            # Register progress event
            Register-ObjectEvent -InputObject $webClient -EventName "DownloadProgressChanged" -Action {
                $percent = $Event.SourceEventArgs.ProgressPercentage
                $received = $Event.SourceEventArgs.BytesReceived
                $total = $Event.SourceEventArgs.TotalBytesToReceive
                $receivedStr = if ($received -gt 1GB) { "$([math]::Round($received / 1GB, 1)) GB" }
                              elseif ($received -gt 1MB) { "$([math]::Round($received / 1MB, 1)) MB" }
                              else { "$([math]::Round($received / 1KB, 1)) KB" }
                $totalStr = if ($total -gt 1GB) { "$([math]::Round($total / 1GB, 1)) GB" }
                           elseif ($total -gt 1MB) { "$([math]::Round($total / 1MB, 1)) MB" }
                           else { "$([math]::Round($total / 1KB, 1)) KB" }
                Write-Progress -Activity "Downloading $isoName" -Status "$receivedStr / $totalStr" -PercentComplete $percent
            } | Out-Null
            
            $webClient.DownloadFile($isoUrl, (Join-Path (Get-Location) $tempFile))
            Write-Progress -Activity "Downloading $isoName" -Completed
            
            # Move completed download to final location
            Move-Item $tempFile $isoName
            
            $finalSize = (Get-Item $isoName).Length
            $sizeStr = if ($finalSize -gt 1GB) { "$([math]::Round($finalSize / 1GB, 1))G" }
                      elseif ($finalSize -gt 1MB) { "$([math]::Round($finalSize / 1MB))M" }
                      else { "${finalSize}B" }
            Write-Log "Download completed: $sizeStr"
        }
        catch {
            if (Test-Path $tempFile) { Remove-Item $tempFile -Force }
            throw "Download failed: $isoUrl"
        }
        finally {
            $webClient.Dispose()
            Get-EventSubscriber | Where-Object { $_.SourceObject -is [System.Net.WebClient] } | Unregister-Event
        }
    }
    
    # --- download checksums with signature files ---
    if (-not $skipChecksum) {
        Write-Log "Downloading checksums..."
        
        # Try SHA512SUMS first (more secure), fallback to SHA256SUMS
        foreach ($hash in @("SHA512SUMS", "SHA256SUMS")) {
            try {
                Write-Log "Trying to download $hash..."
                Invoke-WebRequest -Uri ($baseUrl + $hash) -OutFile $hash -UseBasicParsing -TimeoutSec 15
                $hashFile = $hash
                $hashAlgorithm = $hash -replace 'SUMS', ''
                Write-Log "Downloaded: $hash"
                
                # Try to download signature file
                try {
                    Write-Log "Trying to download $hash.sign..."
                    Invoke-WebRequest -Uri ($baseUrl + $hash + ".sign") -OutFile "$hash.sign" -UseBasicParsing -TimeoutSec 15
                    Write-Log "Downloaded: $hash.sign"
                }
                catch {
                    Write-Log "Warning: Could not download $hash.sign (signature file)"
                }
                
                break
            }
            catch {
                Write-Log "Could not download $hash, trying next option..."
                continue
            }
        }
        
        if (-not $hashFile) {
            Write-Log "Warning: No checksum files available for verification"
        }
    }
    
    # --- verify checksum ---
    $verified = $false
    $actualHashes = @{}
    
    if ($hashFile -and (Test-Path $hashFile)) {
        Write-Log "Verifying $hashAlgorithm checksum..."
        
        $hashLine = Get-Content $hashFile | Where-Object { $_ -match [regex]::Escape($isoName) }
        if ($hashLine) {
            $expected = ($hashLine -split '\s+')[0].ToLower()
            $actual = (Get-FileHash -Algorithm $hashAlgorithm $isoName).Hash.ToLower()
            $actualHashes[$hashAlgorithm.ToLower()] = $actual
            
            if ($expected -eq $actual) {
                Write-Log "$hashAlgorithm verification PASSED"
                $verified = $true
            } else {
                throw "$hashAlgorithm mismatch: expected $expected, got $actual"
            }
        }
        else {
            Write-Log "Warning: Could not find hash for $isoName in $hashFile"
        }
    }
    
    # Calculate hashes for baton
    if (-not $actualHashes.ContainsKey('sha256')) {
        $actualHashes['sha256'] = (Get-FileHash -Algorithm SHA256 $isoName).Hash.ToLower()
    }
    
    # Calculate SHA512 if we verified with SHA512
    if ($hashAlgorithm -eq 'SHA512' -and -not $actualHashes.ContainsKey('sha512')) {
        $actualHashes['sha512'] = (Get-FileHash -Algorithm SHA512 $isoName).Hash.ToLower()
    }
    
    # --- create baton ---
    $fileSize = (Get-Item $isoName).Length
    
    $baton = @{
        schema_version = 1
        step           = $step
        created_at     = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        artefacts      = @{
            $isoName = @{
                sha256 = $actualHashes['sha256']
                sha512 = if ($actualHashes.ContainsKey('sha512')) { $actualHashes['sha512'] } else { $null }
                url    = $isoUrl
                version = $isoVersion
                verified = $verified
                location = (Get-Location).Path
                size_bytes = $fileSize
                checksum_file = $hashFile
            }
        }
    }
    
    $jsonPath = "sovereignty-chain.$step.json"
    $baton | ConvertTo-Json -Depth 4 | Out-File -FilePath $jsonPath -Encoding UTF8 -NoNewline
    
    Write-Log "Baton saved: $jsonPath"
    
    # Final status
    $sizeStr = if ($fileSize -gt 1GB) { "$([math]::Round($fileSize / 1GB, 1))G" }
              elseif ($fileSize -gt 1MB) { "$([math]::Round($fileSize / 1MB))M" }
              else { "${fileSize}B" }
    
    Write-Host
    Write-Log "SUCCESS: Process completed: $isoName"
    Write-Log "Version: $isoVersion"
    Write-Log "Size: $sizeStr"
    Write-Log "Verified: $(if ($verified) { 'Yes' } else { 'No' })"
    Write-Log "Location: $(Get-Location)"
    $files = @($isoName)
    if ($hashFile) { $files += $hashFile }
    $files += $jsonPath
    Write-Log "Files: $($files -join ', ')"
    
} catch {
    Write-Error-Log $_.Exception.Message
    exit 1
}