# Validation summary reports (Reports\<serial>\...) and the history read back
# from them: latest summary, fingerprint, configuration name, MAC records.

function Get-SerialReportFolder {
    param([string]$SerialNumber)

    return [string](Join-Path $script:ReportDir $SerialNumber)
}

function Get-LatestSummary {
    param([string]$SerialNumber)

    $folder = Get-SerialReportFolder -SerialNumber $SerialNumber

    if (-not (Test-Path $folder)) {
        return $null
    }

    return Get-ChildItem -Path $folder -Filter "*_Hardware_Validation_Summary.txt" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}

function Get-SummaryFieldValue {
    param(
        [string]$Path,
        [string]$FieldPattern
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path $Path)) {
        return $null
    }

    foreach ($line in Get-Content -Path $Path -ErrorAction Stop) {
        if ($line -match "^$FieldPattern\s*:\s*(.+)$") {
            $value = $matches[1].Trim()
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                return [string]$value
            }
        }
    }

    return $null
}

function Get-HardwareFingerprintFromSummary {
    param([string]$Path)

    $value = Get-SummaryFieldValue -Path $Path -FieldPattern 'Hardware Fingerprint'
    if ($null -eq $value) { return $null }
    return $value.ToUpperInvariant()
}

function Get-ConfigurationNameFromSummary {
    param([string]$Path)
    return Get-SummaryFieldValue -Path $Path -FieldPattern 'Configuration'
}

function Get-MacsFromSummary {
    param([string]$Path)

    $records = [System.Collections.Generic.List[string]]::new()
    $lines = @(Get-Content -Path $Path -ErrorAction Stop)

    foreach ($line in $lines) {
        if ($line -match '^MAC RECORD\s*:\s*(.+)$') {
            $records.Add($matches[1].Trim().ToUpperInvariant())
        }
    }

    # Older summaries only had the human-readable "MAC ADDRESS" lines.
    if ($records.Count -eq 0) {
        foreach ($line in $lines) {
            if ($line -match '^\s*MAC ADDRESS\s*:\s*(.+)$') {
                $records.Add(("MAC|" + $matches[1].Trim()).ToUpperInvariant())
            }
        }
    }

    return @($records | Sort-Object -Unique)
}

function Get-CurrentMacRecords {
    param($Snapshot)

    $records = [System.Collections.Generic.List[string]]::new()

    foreach ($a in @($Snapshot.Network.Adapters)) {
        $description = ([string]$a.InterfaceDescription).Trim()
        $mac = ([string]$a.MacAddress).Trim().ToUpperInvariant()
        $records.Add(("$description|$mac").ToUpperInvariant())
    }

    return @($records | Sort-Object -Unique)
}

function Compare-MacsToLatestSummary {
    param(
        [string]$SerialNumber,
        $Snapshot
    )

    $section = "MAC HISTORY"
    $check = "Previous summary comparison"
    $previousSummary = Get-LatestSummary -SerialNumber $SerialNumber

    if ($null -eq $previousSummary) {
        return New-CheckResult $section $check "INFO" "No previous summary exists for this serial number. Current MAC addresses will become the baseline."
    }

    $previousRecords = @(Get-MacsFromSummary -Path $previousSummary.FullName)
    $currentRecords = @(Get-CurrentMacRecords -Snapshot $Snapshot)

    if ($previousRecords.Count -eq 0) {
        return New-CheckResult $section $check "WARN" "A previous summary exists, but no MAC records could be read from '$($previousSummary.Name)'."
    }

    $previousIsLegacy = @($previousRecords | Where-Object { $_ -like "MAC|*" }).Count -gt 0

    if ($previousIsLegacy) {
        $previousMacs = @($previousRecords | ForEach-Object { ($_ -split '\|',2)[1] } | Sort-Object -Unique)
        $currentMacs = @(
            $Snapshot.Network.Adapters |
            ForEach-Object { ([string]$_.MacAddress).Trim().ToUpperInvariant() } |
            Sort-Object -Unique
        )

        $difference = @(Compare-Object -ReferenceObject $previousMacs -DifferenceObject $currentMacs)
        $oldDisplay = $previousMacs -join ", "
        $newDisplay = $currentMacs -join ", "
    }
    else {
        $difference = @(Compare-Object -ReferenceObject $previousRecords -DifferenceObject $currentRecords)
        $oldDisplay = $previousRecords -join "; "
        $newDisplay = $currentRecords -join "; "
    }

    if ($difference.Count -eq 0) {
        return New-CheckResult $section $check "PASS" "MAC addresses match the most recent summary ($($previousSummary.Name))."
    }

    return New-CheckResult $section $check "FAIL" "MAC mismatch versus latest summary '$($previousSummary.Name)'. Previous: $oldDisplay | Current: $newDisplay"
}

function Save-Summary {
    param(
        [string]$SerialNumber,
        [string]$TestPhase,
        [string]$AppMode,
        [string]$ConfigBaseName,
        $Config,
        $Snapshot,
        $RenameInfo,
        $Results
    )

    $folder = Get-SerialReportFolder -SerialNumber $SerialNumber
    New-Item -ItemType Directory -Path $folder -Force | Out-Null

    $safePhase = ($TestPhase -replace '[^A-Za-z0-9-]','_')
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $fileName = "${SerialNumber}_${safePhase}_${timestamp}_Hardware_Validation_Summary.txt"
    $path = Join-Path $folder $fileName

    $overall = Get-OverallResult -Results $Results -RenameInfo $RenameInfo

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("="*72)
    $lines.Add("HARDWARE VALIDATION SUMMARY")
    $lines.Add("="*72)
    $lines.Add("Date/Time      : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    $lines.Add("Serial Number  : $SerialNumber")
    $lines.Add("Test Phase     : $TestPhase")
    $lines.Add("Application Mode : $AppMode")
    $lines.Add("Configuration  : $([string]$Config.Name)")
    $lines.Add("BurnInTest Config : $ConfigBaseName.bitcfg")
    $lines.Add("Hardware Fingerprint : $([string]$Snapshot.System.HardwareFingerprint)")
    $lines.Add("System UUID          : $([string]$Snapshot.System.SystemUUID)")
    $lines.Add("BIOS Serial          : $([string]$Snapshot.System.BiosSerial)")
    $lines.Add("Baseboard Serial     : $([string]$Snapshot.System.BaseboardSerial)")
    $lines.Add("Previous Name  : $([string]$RenameInfo.PreviousName)")
    $lines.Add("Requested Name : $([string]$RenameInfo.RequestedName)")
    $lines.Add("Rename Status  : $([string]$RenameInfo.Detail)")
    $lines.Add("Overall Result : $overall")
    $lines.Add("")
    $lines.Add("CPU            : $([string]$Snapshot.CPU.Model)")
    $lines.Add("CPU Cores      : $([int]$Snapshot.CPU.CoreCount)")
    $lines.Add("Logical CPUs   : $([int]$Snapshot.CPU.LogicalProcessors)")
    $lines.Add("RAM            : $([double]$Snapshot.Memory.TotalGB) GB")
    $lines.Add("DIMM Count     : $([int]$Snapshot.Memory.DimmCount)")
    $lines.Add("")
    $lines.Add("NETWORK / MAC ADDRESSES")
    $lines.Add("-"*72)

    foreach ($a in @($Snapshot.Network.Adapters)) {
        $description = ([string]$a.InterfaceDescription).Trim()
        $mac = ([string]$a.MacAddress).Trim().ToUpperInvariant()

        $lines.Add("$description")
        $lines.Add("  Friendly Name : $([string]$a.Name)")
        $lines.Add("  Status        : $([string]$a.Status)")
        $lines.Add("  Link Speed    : $([string]$a.LinkSpeed)")
        $lines.Add("  MAC ADDRESS   : $mac")
        # Machine-readable record used for cross-phase verification.
        $lines.Add("MAC RECORD     : $description|$mac")
        $lines.Add("")
    }

    $lines.Add("VALIDATION RESULTS")
    $lines.Add("-"*72)

    foreach ($r in @($Results)) {
        $lines.Add("[$([string]$r.Status)] $([string]$r.Section) - $([string]$r.Check): $([string]$r.Detail)")
    }

    $lines.Add("")
    $lines.Add("OVERALL RESULT: $overall")
    $lines.Add("REBOOT REQUIRED: $(if ($RenameInfo.RebootRequired) {'YES'} else {'NO'})")

    $lines | Set-Content -Path $path -Encoding UTF8
    return [string]$path
}
