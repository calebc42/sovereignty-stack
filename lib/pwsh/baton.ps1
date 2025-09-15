# Sovereignty Stack – shared baton helpers
# Import with: Import-Module $PSScriptRoot\..\..\lib\pwsh\Baton.psm1 -Force

function Save-Baton {
    param($JsonPath, $Name, $Sha256, $Url, $Version, $Verified, $ChecksumFile, $Size)
    @{
        schema_version = 1
        step           = (Split-Path (Split-Path $PSScriptRoot -Parent) -Leaf)
        created_at     = (Get-Date -Format o)
        artefacts      = @{
            $Name = @{
                sha256       = $Sha256
                sha512       = $null
                url          = $Url
                version      = $Version
                verified     = $Verified
                location     = (Get-Location).Path
                size_bytes   = $Size
                checksum_file = if ($ChecksumFile) { $ChecksumFile } else { $null }
            }
        }
    } | ConvertTo-Json -Depth 3 | Out-File $JsonPath -Encoding UTF8
}

function Load-Baton {
    param($JsonPath)
    if (-not (Test-Path $JsonPath)) { throw "Baton not found: $JsonPath" }
    $b = Get-Content $JsonPath | ConvertFrom-Json
    $artefact = $b.artefacts.PSObject.Properties.Name
    @{
        IsoFile = $artefact
        IsoSha256 = $b.artefacts.$artefact.sha256
    }
}