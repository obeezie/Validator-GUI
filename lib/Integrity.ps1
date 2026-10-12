# SHA-256 manifest that protects engineer-registered hardware configs
# against accidental edits. Format: { "<file name>": "<SHA-256>" }.

function Get-FileSha256 {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        return $null
    }

    return (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Get-HashManifest {
    param([string]$ManifestPath)

    if (-not (Test-Path $ManifestPath)) {
        return @{}
    }

    try {
        $raw = Get-Content -Path $ManifestPath -Raw | ConvertFrom-Json
        $table = @{}

        if ($null -ne $raw) {
            foreach ($p in $raw.PSObject.Properties) {
                $table[$p.Name] = [string]$p.Value
            }
        }

        return $table
    }
    catch {
        Write-ErrorLog $_
        return @{}
    }
}

function Save-HashManifest {
    param(
        [string]$ManifestPath,
        [hashtable]$Manifest
    )

    $obj = [ordered]@{}

    foreach ($key in ($Manifest.Keys | Sort-Object)) {
        $obj[$key] = $Manifest[$key]
    }

    Set-FileReadOnlyState -Path $ManifestPath -ReadOnly $false
    $obj | ConvertTo-Json -Depth 4 | Set-Content -Path $ManifestPath -Encoding UTF8
    Set-FileReadOnlyState -Path $ManifestPath -ReadOnly $true
}

function Register-FileIntegrity {
    param(
        [string]$ManifestPath,
        [string]$FilePath
    )

    $manifest = Get-HashManifest -ManifestPath $ManifestPath
    $manifest[[IO.Path]::GetFileName($FilePath)] = Get-FileSha256 -Path $FilePath
    Save-HashManifest -ManifestPath $ManifestPath -Manifest $manifest
    Set-FileReadOnlyState -Path $FilePath -ReadOnly $true
}

function Test-FileIntegrity {
    param(
        [string]$ManifestPath,
        [string]$FilePath,
        [string]$Label
    )

    $fileName = [IO.Path]::GetFileName($FilePath)

    if (-not (Test-Path $FilePath)) {
        return [pscustomobject]@{ Exists=$false; Valid=$false; Detail="$Label file '$fileName' is missing." }
    }

    $manifest = Get-HashManifest -ManifestPath $ManifestPath

    if (-not $manifest.ContainsKey($fileName)) {
        return [pscustomobject]@{ Exists=$true; Valid=$false; Detail="No engineer-generated integrity record exists for $Label '$fileName'." }
    }

    if ((Get-FileSha256 -Path $FilePath) -ieq [string]$manifest[$fileName]) {
        return [pscustomobject]@{ Exists=$true; Valid=$true; Detail="$Label integrity verified." }
    }

    return [pscustomobject]@{ Exists=$true; Valid=$false; Detail="$Label '$fileName' does not match the engineer-generated integrity record." }
}

function Register-ConfigIntegrity {
    param([string]$ConfigPath)
    Register-FileIntegrity -ManifestPath $script:ConfigManifestPath -FilePath $ConfigPath
}

function Test-ConfigIntegrity {
    param([string]$ConfigPath)
    return Test-FileIntegrity -ManifestPath $script:ConfigManifestPath -FilePath $ConfigPath -Label "Configuration"
}
