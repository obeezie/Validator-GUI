# Shared paths and small helpers used by every other file.
# Must stay compatible with Windows PowerShell 5.1 (no PS7-only syntax).

function Initialize-ValidatorPaths {
    param([string]$Root)

    $script:ScriptRoot = $Root
    $script:ConfigDir = Join-Path $Root "Configs"
    $script:ReportDir = Join-Path $Root "Reports"
    $script:ConfigManifestName = "config_manifest.json"
    $script:ConfigManifestPath = Join-Path $script:ConfigDir $script:ConfigManifestName
    $script:ErrorLog = Join-Path $Root "HardwareValidator_Error.log"

    foreach ($dir in @($script:ConfigDir, $script:ReportDir)) {
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir | Out-Null
        }
    }
}

function Write-ErrorLog {
    param($ErrorRecord)
    $text = @"
============================================================
$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
MESSAGE:
$($ErrorRecord.Exception.Message)

TYPE:
$($ErrorRecord.Exception.GetType().FullName)

SCRIPT STACK:
$($ErrorRecord.ScriptStackTrace)

POSITION:
$($ErrorRecord.InvocationInfo.PositionMessage)

FULL ERROR:
$($ErrorRecord | Out-String)
============================================================

"@
    Add-Content -Path $script:ErrorLog -Value $text -Encoding UTF8
}

function Convert-LinkSpeedToMbps {
    param([string]$LinkSpeed)

    if ([string]::IsNullOrWhiteSpace($LinkSpeed)) {
        return $null
    }

    if ($LinkSpeed -match '([\d\.]+)\s*Gbps') {
        return [double]([math]::Round(([double]$matches[1]) * 1000, 2))
    }

    if ($LinkSpeed -match '([\d\.]+)\s*Mbps') {
        return [double]([math]::Round([double]$matches[1], 2))
    }

    if ($LinkSpeed -match '([\d\.]+)\s*Kbps') {
        return [double]([math]::Round(([double]$matches[1]) / 1000, 3))
    }

    return $null
}

# Case-insensitive literal substring test. Unlike -like, characters such as
# [ ] * ? in hardware names are not treated as wildcards.
function Test-ContainsText {
    param(
        [string]$Text,
        [string]$Fragment
    )

    if ([string]::IsNullOrEmpty($Fragment)) {
        return $true
    }

    if ($null -eq $Text) {
        return $false
    }

    return ($Text.IndexOf($Fragment, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
}

# Windows numbers duplicate adapter descriptions ("... Connection #2"), and the
# number can change between boots or phases. It is never part of a match.
function Remove-EnumerationSuffix {
    param([string]$Text)
    return (([string]$Text) -replace '\s+#\d+\s*$', '').Trim()
}

function ConvertTo-InvariantDouble {
    param([string]$Text)

    $value = 0.0
    $ok = [double]::TryParse(
        ([string]$Text).Trim(),
        [System.Globalization.NumberStyles]::Float,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [ref]$value
    )

    if ($ok) { return $value }
    return $null
}

function Set-FileReadOnlyState {
    param(
        [string]$Path,
        [bool]$ReadOnly
    )

    if (Test-Path $Path) {
        try { (Get-Item $Path).IsReadOnly = $ReadOnly } catch {}
    }
}
