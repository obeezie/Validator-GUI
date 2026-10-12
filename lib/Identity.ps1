# Physical hardware identity (fingerprint of system UUID, BIOS serial and
# baseboard serial) and approval of intentional hardware replacement.

function Test-UsableHardwareIdValue {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    $v = $Value.Trim().ToUpperInvariant()

    $placeholders = @(
        "TO BE FILLED BY O.E.M.",
        "TO BE FILLED BY OEM",
        "DEFAULT STRING",
        "SYSTEM SERIAL NUMBER",
        "NONE",
        "N/A",
        "NA",
        "UNKNOWN",
        "NOT SPECIFIED",
        "NOT APPLICABLE"
    )

    if ($placeholders -contains $v) {
        return $false
    }

    # Reject UUID/serial values that are effectively all zeros or all Fs.
    $compact = ($v -replace '[^A-F0-9]','')
    if ($compact.Length -ge 8) {
        if ($compact -match '^0+$' -or $compact -match '^F+$') {
            return $false
        }
    }

    return $true
}

function New-HardwareIdentity {
    param(
        [string]$SystemUUID,
        [string]$BiosSerial,
        [string]$BaseboardSerial
    )

    $uuid = ([string]$SystemUUID).Trim().ToUpperInvariant()
    $bios = ([string]$BiosSerial).Trim().ToUpperInvariant()
    $board = ([string]$BaseboardSerial).Trim().ToUpperInvariant()

    $parts = [System.Collections.Generic.List[string]]::new()
    if (Test-UsableHardwareIdValue $uuid) { $parts.Add("UUID=$uuid") }
    if (Test-UsableHardwareIdValue $bios) { $parts.Add("BIOS=$bios") }
    if (Test-UsableHardwareIdValue $board) { $parts.Add("BOARD=$board") }

    $fingerprint = ""

    if ($parts.Count -gt 0) {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]::Join("|", $parts))
            $fingerprint = ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-","")
        }
        finally {
            $sha.Dispose()
        }
    }

    return [pscustomobject]@{
        SystemUUID = $uuid
        BiosSerial = $bios
        BaseboardSerial = $board
        Fingerprint = $fingerprint
        UsableComponentCount = [int]$parts.Count
    }
}

function Get-HardwareIdentity {
    $product = Get-CimInstance Win32_ComputerSystemProduct | Select-Object -First 1
    $bios = Get-CimInstance Win32_BIOS | Select-Object -First 1
    $baseboard = Get-CimInstance Win32_BaseBoard | Select-Object -First 1

    return New-HardwareIdentity `
        -SystemUUID ([string]$product.UUID) `
        -BiosSerial ([string]$bios.SerialNumber) `
        -BaseboardSerial ([string]$baseboard.SerialNumber)
}

function New-IdentityState {
    param(
        [string]$Status,
        [bool]$TrustedHistory,
        [string]$UnitSerial,
        $CurrentIdentity,
        [string]$PreviousFingerprint,
        [string]$SummaryPath,
        [string]$Detail
    )

    return [pscustomobject]@{
        Status = $Status
        TrustedHistory = $TrustedHistory
        UnitSerial = $UnitSerial
        CurrentIdentity = $CurrentIdentity
        PreviousFingerprint = $PreviousFingerprint
        SummaryPath = $SummaryPath
        Detail = $Detail
    }
}

# Compares the motherboard the validator is running on with the latest report
# filed under a Unit Serial. History belongs to the Unit Serial, not to the
# Windows computer name: a shared Boot Drive carries the previous unit's name
# (a Stale Name) to the next unit, and that must not look like a Hardware Change.
#   NEW        - no report exists for this Unit Serial
#   UNVERIFIED - a report exists but fingerprints cannot be compared
#   MATCH      - same motherboard as the latest report (history is trusted)
#   MISMATCH   - different motherboard: a Hardware Change, or the wrong serial
function Get-UnitIdentityState {
    param(
        [string]$UnitSerial,
        $CurrentIdentity
    )

    $serial = ([string]$UnitSerial).Trim()
    $summary = Get-LatestSummary -SerialNumber $serial

    if ($null -eq $summary) {
        return New-IdentityState -Status "NEW" -TrustedHistory $false -UnitSerial $serial `
            -CurrentIdentity $CurrentIdentity -PreviousFingerprint "" -SummaryPath "" `
            -Detail "No previous report exists for unit '$serial'."
    }

    $summaryPath = [string]$summary.FullName
    $previousFingerprint = [string](Get-HardwareFingerprintFromSummary -Path $summaryPath)

    if ([string]::IsNullOrWhiteSpace($previousFingerprint)) {
        return New-IdentityState -Status "UNVERIFIED" -TrustedHistory $false -UnitSerial $serial `
            -CurrentIdentity $CurrentIdentity -PreviousFingerprint "" -SummaryPath $summaryPath `
            -Detail "Previous report found, but it predates hardware fingerprint tracking. Configuration history will not be trusted automatically."
    }

    if ([string]::IsNullOrWhiteSpace([string]$CurrentIdentity.Fingerprint)) {
        return New-IdentityState -Status "UNVERIFIED" -TrustedHistory $false -UnitSerial $serial `
            -CurrentIdentity $CurrentIdentity -PreviousFingerprint $previousFingerprint -SummaryPath $summaryPath `
            -Detail "This unit does not expose enough usable motherboard identifiers to verify the previous report."
    }

    if ([string]$CurrentIdentity.Fingerprint -ieq $previousFingerprint) {
        return New-IdentityState -Status "MATCH" -TrustedHistory $true -UnitSerial $serial `
            -CurrentIdentity $CurrentIdentity -PreviousFingerprint $previousFingerprint -SummaryPath $summaryPath `
            -Detail "Motherboard matches the previous report for unit '$serial'."
    }

    return New-IdentityState -Status "MISMATCH" -TrustedHistory $false -UnitSerial $serial `
        -CurrentIdentity $CurrentIdentity -PreviousFingerprint $previousFingerprint -SummaryPath $summaryPath `
        -Detail "Unit '$serial' has previous test history recorded on a different motherboard."
}

function Get-HardwareIdentityFieldsFromSummary {
    param([string]$Path)

    $values = @{
        Fingerprint = ""
        SystemUUID = ""
        BiosSerial = ""
        BaseboardSerial = ""
    }

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path $Path)) {
        return [pscustomobject]$values
    }

    foreach ($line in Get-Content -Path $Path -ErrorAction Stop) {
        if ($line -match '^Hardware Fingerprint\s*:\s*(.*)$') {
            $values.Fingerprint = $matches[1].Trim().ToUpperInvariant()
        }
        elseif ($line -match '^System UUID\s*:\s*(.*)$') {
            $values.SystemUUID = $matches[1].Trim().ToUpperInvariant()
        }
        elseif ($line -match '^BIOS Serial\s*:\s*(.*)$') {
            $values.BiosSerial = $matches[1].Trim().ToUpperInvariant()
        }
        elseif ($line -match '^Baseboard Serial\s*:\s*(.*)$') {
            $values.BaseboardSerial = $matches[1].Trim().ToUpperInvariant()
        }
    }

    return [pscustomobject]$values
}

function Get-HardwareChangeDetails {
    param($IdentityState)

    if ($null -eq $IdentityState -or $IdentityState.Status -ne "MISMATCH") {
        return @()
    }

    if ([string]::IsNullOrWhiteSpace([string]$IdentityState.SummaryPath)) {
        return @()
    }

    $previous = Get-HardwareIdentityFieldsFromSummary -Path $IdentityState.SummaryPath
    $current = $IdentityState.CurrentIdentity
    $changes = [System.Collections.Generic.List[string]]::new()

    $fields = @(
        @{ Label = "System UUID"; Key = "SystemUUID" },
        @{ Label = "BIOS serial"; Key = "BiosSerial" },
        @{ Label = "Baseboard serial"; Key = "BaseboardSerial" }
    )

    foreach ($f in $fields) {
        $old = [string]$previous.($f.Key)
        $new = [string]$current.($f.Key)

        if (-not [string]::IsNullOrWhiteSpace($old) -and $old -ine $new) {
            $changes.Add("$($f.Label) changed:`n  Previous: $old`n  Current:  $new")
        }
    }

    return @($changes)
}

function Save-HardwareChangeApproval {
    param(
        [string]$UnitSerial,
        [string]$Reason,
        [string]$ApprovedByMode,
        $IdentityState
    )

    $folder = Join-Path $script:ReportDir $UnitSerial
    New-Item -ItemType Directory -Path $folder -Force | Out-Null

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $path = Join-Path $folder "${UnitSerial}_Hardware_Change_Approval_${timestamp}.txt"

    $old = Get-HardwareIdentityFieldsFromSummary -Path $IdentityState.SummaryPath
    $current = $IdentityState.CurrentIdentity

    @(
        "HARDWARE CHANGE APPROVAL"
        "========================"
        "Date/Time            : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        "Unit Serial          : $UnitSerial"
        "Approved In Mode     : $ApprovedByMode"
        "Change Reason        : $Reason"
        ""
        "PREVIOUS HARDWARE"
        "Fingerprint          : $([string]$old.Fingerprint)"
        "System UUID          : $([string]$old.SystemUUID)"
        "BIOS Serial          : $([string]$old.BiosSerial)"
        "Baseboard Serial     : $([string]$old.BaseboardSerial)"
        ""
        "CURRENT HARDWARE"
        "Fingerprint          : $([string]$current.Fingerprint)"
        "System UUID          : $([string]$current.SystemUUID)"
        "BIOS Serial          : $([string]$current.BiosSerial)"
        "Baseboard Serial     : $([string]$current.BaseboardSerial)"
    ) | Set-Content -Path $path -Encoding UTF8

    return $path
}

# Returns only the fingerprints listed under CURRENT HARDWARE in an approval
# file. The PREVIOUS HARDWARE fingerprint must never count as approved,
# otherwise swapping the original hardware back in would be auto-approved.
function Get-ApprovedFingerprintsFromApproval {
    param([string]$Path)

    $approved = [System.Collections.Generic.List[string]]::new()
    $section = ""

    foreach ($line in Get-Content -Path $Path -ErrorAction SilentlyContinue) {
        $trimmed = ([string]$line).Trim()

        if ($trimmed -eq "PREVIOUS HARDWARE") { $section = "PREVIOUS"; continue }
        if ($trimmed -eq "CURRENT HARDWARE") { $section = "CURRENT"; continue }

        if ($section -eq "CURRENT" -and $trimmed -match '^Fingerprint\s*:\s*(.+)$') {
            $approved.Add($matches[1].Trim().ToUpperInvariant())
        }
    }

    return @($approved)
}

function Test-HardwareChangeApprovalForCurrentIdentity {
    param($IdentityState)

    if ($null -eq $IdentityState -or $IdentityState.Status -ne "MISMATCH") {
        return $false
    }

    $folder = Join-Path $script:ReportDir ([string]$IdentityState.UnitSerial)

    if (-not (Test-Path $folder)) {
        return $false
    }

    $currentFingerprint = ([string]$IdentityState.CurrentIdentity.Fingerprint).ToUpperInvariant()

    if ([string]::IsNullOrWhiteSpace($currentFingerprint)) {
        return $false
    }

    foreach ($file in Get-ChildItem -Path $folder -Filter "*_Hardware_Change_Approval_*.txt" -File -ErrorAction SilentlyContinue) {
        if (@(Get-ApprovedFingerprintsFromApproval -Path $file.FullName) -contains $currentFingerprint) {
            return $true
        }
    }

    return $false
}
