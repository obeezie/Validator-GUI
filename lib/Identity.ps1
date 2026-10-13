# Hardware Fingerprint: the identity of a unit's motherboard, from its
# system UUID, BIOS serial and baseboard serial. Comparing it with a unit's
# history is done in UnitHistory.ps1.

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
