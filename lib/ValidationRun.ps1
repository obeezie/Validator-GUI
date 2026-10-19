# One Validation Run, from the operator's inputs to a recorded report.
#
#   Invoke-ValidationRun -UnitSerial -TestPhase -ConfigBaseName -AppMode -Operator -Machine
#
# Returns an outcome:
#   Stopped   - Focus ("Serial" | "Phase" | "Config"), Title, Message ($null
#               when the operator chose to stop). Nothing was written and the
#               computer was not renamed.
#   Completed - Results, OverallResult, RenameInfo, SummaryPath, Snapshot,
#               Adapters (the Config's network adapters, as found on the unit).
#
# Order: every check that needs no operator answer runs first; then the
# questions (Traveler Confirmation, Hardware Change, rename); nothing is
# written to the Unit History until all of them are answered.
#
# Ports (hashtables of scriptblocks):
#   Operator: ConfirmTraveler(UnitSerial, Adapters, ReplacesRunNumber) -> bool
#             ApproveHardwareChange(UnitSerial, Changes) -> reason, or $null/"" to stop
#             ConfirmRename(CurrentName, UnitSerial) -> bool
#   Machine:  ReadIdentity, ReadSnapshot, ComputerName, PendingName, Rename(NewName)
#             (New-WindowsMachine in Hardware.ps1)

# The Test Phase at which the System Traveler is always re-confirmed.
$script:TravelerPhase = "Tier"

function New-StoppedOutcome {
    param([string]$Focus, [string]$Title = $null, [string]$Message = $null)

    return [pscustomobject]@{
        Status = "Stopped"
        Focus = $Focus
        Title = $Title
        Message = $(if ([string]::IsNullOrEmpty($Message)) { $null } else { $Message })
    }
}

function Invoke-ValidationRun {
    param(
        [string]$UnitSerial,
        [string]$TestPhase,
        [string]$ConfigBaseName,
        [string]$AppMode,
        $Operator,
        $Machine
    )

    $serial = ([string]$UnitSerial).Trim()

    # --- Checks that need no operator answer --------------------------------
    $serialError = Test-SerialNumberFormat -SerialNumber $serial
    if ($null -ne $serialError) {
        return New-StoppedOutcome -Focus "Serial" -Title "Serial Number" -Message $serialError
    }

    if ([string]::IsNullOrWhiteSpace($TestPhase)) {
        return New-StoppedOutcome -Focus "Phase" -Title "Test Phase Required" -Message "Please select the current test phase before running validation."
    }

    if ([string]::IsNullOrWhiteSpace($ConfigBaseName)) {
        return New-StoppedOutcome -Focus "Config" -Title "Configuration Required" -Message "Please select a configuration."
    }

    $configPath = Get-ConfigPath $ConfigBaseName
    $integrity = Test-ConfigIntegrity -ConfigPath $configPath
    if (-not $integrity.Valid) {
        return New-StoppedOutcome -Focus "Config" -Title "Configuration Integrity Failure" -Message (
            "$($integrity.Detail)`n`nValidation will not continue with an unregistered or modified configuration. " +
            "Open Engineer mode and re-capture or edit and save the intended configuration."
        )
    }

    $config = Read-HardwareConfig -Path $configPath
    $configErrors = @(Test-ConfigDefinition $config)
    if ($configErrors.Count -gt 0) {
        return New-StoppedOutcome -Focus "Config" -Title "Configuration Problems" -Message (
            "The selected configuration cannot be used:`n`n" + [string]::Join([Environment]::NewLine, $configErrors) +
            "`n`nOpen Engineer mode and fix it with Edit Config."
        )
    }

    $currentName = [string](& $Machine.ComputerName)
    $pendingName = [string](& $Machine.PendingName)
    $renameAction = Get-RenameAction -SerialNumber $serial -CurrentName $currentName -PendingName $pendingName
    if ($renameAction -eq "Conflict") {
        return New-StoppedOutcome -Focus "Serial" -Title "Pending Rename Conflict" -Message (
            "This computer is named '$currentName', but Windows is set to rename it to '$pendingName' at the next restart.`n`n" +
            "Restart the computer and validate again. If '$pendingName' is the correct serial number, enter that instead."
        )
    }

    $history = Get-UnitHistory -UnitSerial $serial
    $currentIdentity = & $Machine.ReadIdentity
    $identity = Get-UnitIdentityState -History $history -CurrentIdentity $currentIdentity
    $snapshot = & $Machine.ReadSnapshot

    # --- Operator questions (nothing written yet) ---------------------------
    # Every Tier run re-confirms the MACs against the System Traveler (this is
    # how wrongly confirmed MACs are corrected); other phases ask only when the
    # unit has never been confirmed.
    $confirmingTraveler = (-not $history.TravelerConfirmed) -or ($TestPhase -ieq $script:TravelerPhase)
    if ($confirmingTraveler) {
        $adapters = @(
            @($snapshot.Network.Adapters) |
            Where-Object { ConvertTo-MacKey ([string]$_.MacAddress) } |
            ForEach-Object {
                [pscustomobject]@{
                    Description = [string]$_.InterfaceDescription
                    Mac = Format-MacKey (ConvertTo-MacKey ([string]$_.MacAddress))
                }
            }
        )

        $replacesRun = if ($history.TravelerConfirmed) { $history.ConfirmedRunNumber } else { $null }
        if (-not [bool](& $Operator.ConfirmTraveler $serial $adapters $replacesRun)) {
            return New-StoppedOutcome -Focus "Serial" -Title "Validation Stopped" -Message (
                "Validation stopped. Nothing was recorded.`n`n" +
                "Check that the unit, its serial label and the System Traveler belong together, " +
                "and that the MAC addresses were programmed."
            )
        }
    }

    # An approval only matters while the board differs from the latest run;
    # once a run is recorded on the new board, the identity simply MATCHes.
    $isMismatch = $identity.Status -eq "MISMATCH"
    $hardwareChangeApproved = $isMismatch -and (Test-HardwareChangeApproved -History $history -Fingerprint ([string]$currentIdentity.Fingerprint))
    $approvalReason = $null

    if ($isMismatch -and -not $hardwareChangeApproved) {
        $changes = @(Get-HardwareChangeDetails -History $history -CurrentIdentity $currentIdentity)
        $approvalReason = [string](& $Operator.ApproveHardwareChange $serial $changes)
        if ([string]::IsNullOrWhiteSpace($approvalReason)) {
            return New-StoppedOutcome -Focus "Serial"
        }
        $approvalReason = $approvalReason.Trim()
        $hardwareChangeApproved = $true
    }

    if ($renameAction -eq "Rename" -and -not [bool](& $Operator.ConfirmRename $currentName $serial)) {
        return New-StoppedOutcome -Focus "Serial"
    }

    # --- Checks ---------------------------------------------------------------
    $results = @(Test-SystemAgainstConfig -Config $config -Snapshot $snapshot)

    if ($hardwareChangeApproved) {
        $identityResult = New-CheckResult "IDENTITY" "Hardware fingerprint" "PASS" `
            "Hardware change (motherboard replacement) approved in $AppMode mode for the current motherboard."
    } else {
        $identityStatus = if ($identity.Status -eq "MATCH") { "PASS" } else { "INFO" }
        $identityResult = New-CheckResult "IDENTITY" "Hardware fingerprint" $identityStatus ([string]$identity.Detail)
    }

    # Assigned MAC Addresses survive a Hardware Change, so they are always
    # compared with the Traveler Confirmation.
    if ($confirmingTraveler) {
        $macResult = New-CheckResult "MAC ADDRESSES" "System Traveler baseline" "PASS" `
            "Confirmed against the System Traveler by the operator in $AppMode mode (this run)."
    } else {
        $macResult = Compare-MacsToBaseline -History $history -Snapshot $snapshot
    }

    $results = @($results) + @($identityResult) + @($macResult)

    # --- Record the run -------------------------------------------------------
    if ($null -ne $approvalReason) {
        [void](Save-HardwareChangeApproval -History $history -CurrentIdentity $currentIdentity `
            -Reason $approvalReason -ApprovedByMode $AppMode)
    }

    # The computer is renamed only when every check passed.
    $finalRenameAction = $renameAction
    if ($renameAction -eq "Rename" -and -not (Test-ChecksPassed -Results $results)) {
        $finalRenameAction = "Skip"
    }
    $renameInfo = Rename-SystemToSerial -SerialNumber $serial -Action $finalRenameAction -Machine $Machine

    $summaryPath = [string](Save-ValidationRun `
        -History $history `
        -TestPhase $TestPhase `
        -AppMode $AppMode `
        -Config $config `
        -Snapshot $snapshot `
        -RenameInfo $renameInfo `
        -Results $results `
        -TravelerConfirmed $confirmingTraveler)

    return [pscustomobject]@{
        Status = "Completed"
        Results = $results
        OverallResult = Get-OverallResult -Results $results -RenameInfo $renameInfo
        RenameInfo = $renameInfo
        SummaryPath = $summaryPath
        Snapshot = $snapshot
        Adapters = @(Get-ConfiguredNetworkAdapters -Config $config -Snapshot $snapshot)
    }
}
