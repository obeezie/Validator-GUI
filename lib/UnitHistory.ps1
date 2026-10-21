# Unit History: every Validation Run and Hardware Change recorded under one
# Unit Serial (Reports\<Unit Serial>\), and the Baseline the next run is
# compared against. See CONTEXT.md for the terms.
#
# The human-readable run report (.txt) is the only record. Reading it back is
# done here and nowhere else.
#
#   Get-UnitHistory            - load a unit's history
#   Get-UnitIdentityState      - compare the current motherboard with the Baseline
#   Compare-MacsToBaseline     - compare MAC addresses with the Traveler Confirmation
#   Get-HardwareChangeDetails  - what changed on the motherboard
#   Test-HardwareChangeApproved / Save-HardwareChangeApproval
#   Save-ValidationRun         - record a Validation Run (gets the next Run Number)

$script:RunReportSuffix = "_Hardware_Validation_Summary.txt"

function Get-UnitReportFolder {
    param([string]$UnitSerial)
    return [string](Join-Path $script:ReportDir $UnitSerial)
}

# MAC addresses are compared without separators or case: 40:1a:... = 40-1A-...
function ConvertTo-MacKey {
    param([string]$MacAddress)
    return (([string]$MacAddress).ToUpperInvariant() -replace '[^0-9A-F]', '')
}

function Format-MacKey {
    param([string]$MacKey)
    if ($MacKey.Length -ne 12) { return $MacKey }
    return (($MacKey -split '(..)' | Where-Object { $_ }) -join '-')
}

# The MAC addresses that make up a unit's identity: those of the network
# adapters its Config lists. Adapters the Config does not use are ignored.
# (Without a Config, every adapter on the unit counts.)
function Get-SnapshotMacKeys {
    param($Snapshot, $Config = $null)

    $adapters = if ($null -ne $Config) { @(Get-RequiredNetworkAdapters -Config $Config -Snapshot $Snapshot) } else { @($Snapshot.Network.Adapters) }
    return @(
        $adapters |
        ForEach-Object { ConvertTo-MacKey ([string]$_.MacAddress) } |
        Where-Object { $_ } |
        Sort-Object -Unique
    )
}

# Reads one run report, current or older format, into a run record.
function ConvertFrom-RunReport {
    param($File)

    $fields = @{}
    $macRecords = [System.Collections.Generic.List[string]]::new()
    $travelerMacs = [System.Collections.Generic.List[string]]::new()
    $macAddressLines = [System.Collections.Generic.List[string]]::new()
    $travelerConfirmed = $false

    foreach ($line in Get-Content -Path $File.FullName -ErrorAction Stop) {
        if ($line -match '^Traveler MAC\s*:\s*(.+)$') {
            $travelerMacs.Add($matches[1].Trim())
            continue
        }
        if ($line -match '^MAC RECORD\s*:\s*(.+)$') {
            $macRecords.Add((($matches[1] -split '\|')[-1]).Trim())
            continue
        }
        if ($line -match '^\s*MAC ADDRESS\s*:\s*(.+)$') {
            $macAddressLines.Add($matches[1].Trim())
            continue
        }
        if ($line -match '^Traveler Confirmation\s*:\s*Confirmed') {
            $travelerConfirmed = $true
            continue
        }
        # Header fields: the first occurrence wins.
        if ($line -match '^(Run Number|Configuration|Hardware Fingerprint|System UUID|BIOS Serial|Baseboard Serial|Overall Result)\s*:\s*(.*)$') {
            if (-not $fields.ContainsKey($matches[1])) {
                $fields[$matches[1]] = $matches[2].Trim()
            }
        }
    }

    # Confirming runs list every MAC under "Traveler MAC". Older reports listed
    # every adapter as "MAC RECORD", and before that only "MAC ADDRESS".
    $macSource = if ($travelerMacs.Count -gt 0) { $travelerMacs } elseif ($macRecords.Count -gt 0) { $macRecords } else { $macAddressLines }
    $macKeys = @($macSource | ForEach-Object { ConvertTo-MacKey $_ } | Where-Object { $_ } | Sort-Object -Unique)

    $runNumber = $null
    if ($fields["Run Number"] -match '^\d+$') {
        $runNumber = [int]$fields["Run Number"]
    }

    # Ordering: numbered runs by Run Number; older reports before them, by the
    # timestamp in their file name (or the file time if there is none).
    if ($null -ne $runNumber) {
        $sortKey = "1|{0:D9}" -f $runNumber
    }
    elseif ($File.Name -match '_(\d{8}_\d{6})_Hardware_Validation_Summary\.txt$') {
        $sortKey = "0|" + $matches[1]
    }
    else {
        $sortKey = "0|" + $File.LastWriteTime.ToString('yyyyMMdd_HHmmss')
    }

    return [pscustomobject]@{
        Path = [string]$File.FullName
        Name = [string]$File.Name
        RunNumber = $runNumber
        SortKey = $sortKey
        OverallResult = [string]$fields["Overall Result"]
        ConfigName = [string]$fields["Configuration"]
        Fingerprint = ([string]$fields["Hardware Fingerprint"]).ToUpperInvariant()
        SystemUUID = ([string]$fields["System UUID"]).ToUpperInvariant()
        BiosSerial = ([string]$fields["BIOS Serial"]).ToUpperInvariant()
        BaseboardSerial = ([string]$fields["Baseboard Serial"]).ToUpperInvariant()
        MacKeys = $macKeys
        TravelerConfirmed = $travelerConfirmed
    }
}

# Returns only the fingerprints listed under CURRENT HARDWARE in an approval
# file. The PREVIOUS HARDWARE fingerprint must never count as approved,
# otherwise swapping the original board back in would be auto-approved.
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

function Get-UnitHistory {
    param([string]$UnitSerial)

    $serial = ([string]$UnitSerial).Trim()
    $folder = Get-UnitReportFolder -UnitSerial $serial
    $runs = @()
    $approved = @()

    if (Test-Path $folder) {
        $runs = @(
            Get-ChildItem -Path $folder -Filter ("*" + $script:RunReportSuffix) -File -ErrorAction SilentlyContinue |
            ForEach-Object { ConvertFrom-RunReport $_ } |
            Sort-Object SortKey
        )
        $approved = @(
            Get-ChildItem -Path $folder -Filter "*_Hardware_Change_Approval_*.txt" -File -ErrorAction SilentlyContinue |
            ForEach-Object { Get-ApprovedFingerprintsFromApproval -Path $_.FullName }
        )
    }

    $latest = $null
    if ($runs.Count -gt 0) { $latest = $runs[$runs.Count - 1] }

    $highest = 0
    foreach ($r in $runs) {
        if ($null -ne $r.RunNumber -and $r.RunNumber -gt $highest) { $highest = $r.RunNumber }
    }

    # Each Traveler Confirmation (every Tier run) replaces the one before.
    $confirmedRun = @($runs | Where-Object { $_.TravelerConfirmed }) | Select-Object -Last 1

    return [pscustomobject]@{
        UnitSerial = $serial
        Runs = $runs
        LatestRun = $latest
        NextRunNumber = [int]([math]::Max($highest, $runs.Count) + 1)
        TravelerConfirmed = ($null -ne $confirmedRun)
        ConfirmedRunNumber = $(if ($null -ne $confirmedRun) { $confirmedRun.RunNumber } else { $null })
        ConfirmedMacKeys = $(if ($null -ne $confirmedRun) { @($confirmedRun.MacKeys) } else { @() })
        ApprovedFingerprints = @($approved)
    }
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

# Compares the motherboard the validator is running on with the unit's
# Baseline (its latest run, of any result).
#   NEW        - no runs recorded for this Unit Serial
#   UNVERIFIED - fingerprints cannot be compared
#   MATCH      - same motherboard as the latest run (history is trusted)
#   MISMATCH   - different motherboard: a Hardware Change, or the wrong serial
function Get-UnitIdentityState {
    param(
        $History,
        $CurrentIdentity
    )

    $serial = [string]$History.UnitSerial
    $latest = $History.LatestRun

    if ($null -eq $latest) {
        return New-IdentityState -Status "NEW" -TrustedHistory $false -UnitSerial $serial `
            -CurrentIdentity $CurrentIdentity -PreviousFingerprint "" -SummaryPath "" `
            -Detail "No previous run exists for unit '$serial'."
    }

    $previous = [string]$latest.Fingerprint

    if ([string]::IsNullOrWhiteSpace($previous)) {
        return New-IdentityState -Status "UNVERIFIED" -TrustedHistory $false -UnitSerial $serial `
            -CurrentIdentity $CurrentIdentity -PreviousFingerprint "" -SummaryPath $latest.Path `
            -Detail "Previous run found, but it predates hardware fingerprint tracking. Configuration history will not be trusted automatically."
    }

    if ([string]::IsNullOrWhiteSpace([string]$CurrentIdentity.Fingerprint)) {
        return New-IdentityState -Status "UNVERIFIED" -TrustedHistory $false -UnitSerial $serial `
            -CurrentIdentity $CurrentIdentity -PreviousFingerprint $previous -SummaryPath $latest.Path `
            -Detail "This unit does not expose enough usable motherboard identifiers to verify the previous run."
    }

    if ([string]$CurrentIdentity.Fingerprint -ieq $previous) {
        return New-IdentityState -Status "MATCH" -TrustedHistory $true -UnitSerial $serial `
            -CurrentIdentity $CurrentIdentity -PreviousFingerprint $previous -SummaryPath $latest.Path `
            -Detail "Motherboard matches the previous run for unit '$serial'."
    }

    return New-IdentityState -Status "MISMATCH" -TrustedHistory $false -UnitSerial $serial `
        -CurrentIdentity $CurrentIdentity -PreviousFingerprint $previous -SummaryPath $latest.Path `
        -Detail "Unit '$serial' was previously tested on a different motherboard."
}

# MAC addresses are Assigned MAC Addresses: they never legitimately change,
# so any difference from the Traveler Confirmation is a FAIL.
function Compare-MacsToBaseline {
    param(
        $History,
        $Snapshot,
        $Config = $null
    )

    $section = "MAC ADDRESSES"
    $check = "System Traveler baseline"

    if (-not $History.TravelerConfirmed) {
        return New-CheckResult $section $check "INFO" "No Traveler Confirmation recorded for this unit yet."
    }

    # Unexpected: a MAC on one of the Config's adapters that was not confirmed.
    # Missing: a confirmed MAC that is no longer anywhere on the unit. (Units
    # confirmed before V23 also have their unused adapters' MACs in the
    # baseline; those are still on the unit, so they are not missing.)
    $expected = @($History.ConfirmedMacKeys)
    $actual = @(Get-SnapshotMacKeys -Snapshot $Snapshot -Config $Config)
    $onUnit = @(Get-SnapshotMacKeys -Snapshot $Snapshot)
    $missing = @($expected | Where-Object { $onUnit -notcontains $_ })
    $unexpected = @($actual | Where-Object { $expected -notcontains $_ })
    $confirmedIn = if ($null -ne $History.ConfirmedRunNumber) { "run $($History.ConfirmedRunNumber)" } else { "an earlier run" }

    if ($missing.Count -eq 0 -and $unexpected.Count -eq 0) {
        return New-CheckResult $section $check "PASS" "Match the MAC addresses confirmed against the System Traveler in $confirmedIn."
    }

    $parts = [System.Collections.Generic.List[string]]::new()
    if ($missing.Count -gt 0) { $parts.Add("Missing: " + (($missing | ForEach-Object { Format-MacKey $_ }) -join ", ")) }
    if ($unexpected.Count -gt 0) { $parts.Add("Unexpected: " + (($unexpected | ForEach-Object { Format-MacKey $_ }) -join ", ")) }

    return New-CheckResult $section $check "FAIL" ("Do not match the System Traveler (confirmed in $confirmedIn). " + ($parts -join "; "))
}

function Get-HardwareChangeDetails {
    param(
        $History,
        $CurrentIdentity
    )

    $previous = $History.LatestRun
    if ($null -eq $previous) {
        return @()
    }

    $changes = [System.Collections.Generic.List[string]]::new()
    $fields = @(
        @{ Label = "System UUID"; Key = "SystemUUID" },
        @{ Label = "BIOS serial"; Key = "BiosSerial" },
        @{ Label = "Baseboard serial"; Key = "BaseboardSerial" }
    )

    foreach ($f in $fields) {
        $old = ([string]$previous.($f.Key)).Trim()
        $new = ([string]$CurrentIdentity.($f.Key)).Trim()

        if (-not [string]::IsNullOrWhiteSpace($old) -and $old -ine $new) {
            $changes.Add("$($f.Label) changed:`n  Previous: $old`n  Current:  $new")
        }
    }

    return @($changes)
}

function Test-HardwareChangeApproved {
    param(
        $History,
        [string]$Fingerprint
    )

    if ([string]::IsNullOrWhiteSpace($Fingerprint)) {
        return $false
    }
    return (@($History.ApprovedFingerprints) -contains $Fingerprint.ToUpperInvariant())
}

function Save-HardwareChangeApproval {
    param(
        $History,
        $CurrentIdentity,
        [string]$Reason,
        [string]$ApprovedByMode
    )

    $serial = [string]$History.UnitSerial
    $folder = Get-UnitReportFolder -UnitSerial $serial
    New-Item -ItemType Directory -Path $folder -Force | Out-Null

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $path = Join-Path $folder "${serial}_Hardware_Change_Approval_${timestamp}.txt"
    $old = $History.LatestRun

    @(
        "HARDWARE CHANGE APPROVAL"
        "========================"
        "Date/Time            : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        "Unit Serial          : $serial"
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
        "Fingerprint          : $([string]$CurrentIdentity.Fingerprint)"
        "System UUID          : $([string]$CurrentIdentity.SystemUUID)"
        "BIOS Serial          : $([string]$CurrentIdentity.BiosSerial)"
        "Baseboard Serial     : $([string]$CurrentIdentity.BaseboardSerial)"
    ) | Set-Content -Path $path -Encoding UTF8

    return $path
}

# Records a Validation Run as the unit's next Run Number. -Now exists so
# tests can simulate a unit whose clock is wrong.
function Save-ValidationRun {
    param(
        $History,
        [string]$TestPhase,
        [string]$AppMode,
        $Config,
        $Snapshot,
        $RenameInfo,
        $Results,
        [bool]$TravelerConfirmed = $false,
        [datetime]$Now = (Get-Date)
    )

    $serial = [string]$History.UnitSerial
    $runNumber = [int]$History.NextRunNumber
    $folder = Get-UnitReportFolder -UnitSerial $serial
    New-Item -ItemType Directory -Path $folder -Force | Out-Null

    $safePhase = ($TestPhase -replace '[^A-Za-z0-9-]','_')
    $timestamp = $Now.ToString('yyyyMMdd_HHmmss')
    $fileName = "{0}_Run{1:D3}_{2}_{3}{4}" -f $serial, $runNumber, $safePhase, $timestamp, $script:RunReportSuffix
    $path = Join-Path $folder $fileName

    $overall = Get-OverallResult -Results $Results -RenameInfo $RenameInfo

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("="*72)
    $lines.Add("HARDWARE VALIDATION SUMMARY")
    $lines.Add("="*72)
    $lines.Add("Date/Time      : $($Now.ToString('yyyy-MM-dd HH:mm:ss'))")
    $lines.Add("Serial Number  : $serial")
    $lines.Add("Run Number     : $runNumber")
    $lines.Add("Test Phase     : $TestPhase")
    $lines.Add("Application Mode : $AppMode")
    $lines.Add("Configuration  : $([string]$Config.Name)")
    $lines.Add("Hardware Fingerprint : $([string]$Snapshot.System.HardwareFingerprint)")
    $lines.Add("System UUID          : $([string]$Snapshot.System.SystemUUID)")
    $lines.Add("BIOS Serial          : $([string]$Snapshot.System.BiosSerial)")
    $lines.Add("Baseboard Serial     : $([string]$Snapshot.System.BaseboardSerial)")
    $lines.Add("BIOS Version   : $([string]$Snapshot.Firmware.BiosVersion)")
    $lines.Add("BIOS Date      : $([string]$Snapshot.Firmware.BiosDate)")
    $ecText = if ([string]::IsNullOrWhiteSpace([string]$Snapshot.Firmware.EcVersion)) { "NOT REPORTED" } else { [string]$Snapshot.Firmware.EcVersion }
    $lines.Add("EC Version     : $ecText")
    if ($TravelerConfirmed) {
        $lines.Add("Traveler Confirmation : Confirmed by operator in $AppMode mode")
    }
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
    if ($TravelerConfirmed) {
        # The MACs of the Config's adapters, as confirmed against the System
        # Traveler: the unit's MAC baseline until its next Traveler Confirmation.
        $lines.Add("SYSTEM TRAVELER")
        $lines.Add("-"*72)
        foreach ($key in @(Get-SnapshotMacKeys -Snapshot $Snapshot -Config $Config)) {
            $lines.Add("Traveler MAC   : $(Format-MacKey $key)")
        }
        $lines.Add("")
    }

    # Only the adapters the Config lists are reported.
    $lines.Add("NETWORK / MAC ADDRESSES")
    $lines.Add("-"*72)

    foreach ($a in @(Get-RequiredNetworkAdapters -Config $Config -Snapshot $Snapshot)) {
        $description = ([string]$a.InterfaceDescription).Trim()
        $mac = ([string]$a.MacAddress).Trim().ToUpperInvariant()

        $lines.Add("$description")
        $lines.Add("  Friendly Name : $([string]$a.Name)")
        $lines.Add("  Status        : $([string]$a.Status)")
        $lines.Add("  Link Speed    : $([string]$a.LinkSpeed)")
        $lines.Add("  MAC ADDRESS   : $mac")
        # Machine-readable record read back by Unit History.
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
