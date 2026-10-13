# Main-window behaviour: config list, hardware identity status, and the
# Validate System workflow. Uses the main form controls ($script:cmbConfig,
# $script:lvResults, ...) created in HardwareValidator_GUI.ps1.

function Refresh-Configs {
    $previousSelection = $null

    if ($null -ne $script:cmbConfig.SelectedItem) {
        $previousSelection = [string]$script:cmbConfig.SelectedItem
    }

    $script:cmbConfig.Items.Clear()

    foreach ($baseName in @(Get-ConfigBaseNames)) {
        [void]$script:cmbConfig.Items.Add($baseName)
    }

    $script:cmbConfig.SelectedIndex = -1

    if (-not [string]::IsNullOrWhiteSpace($previousSelection) -and $script:cmbConfig.Items.Contains($previousSelection)) {
        $script:cmbConfig.SelectedItem = $previousSelection
    }
}

function Update-IdentityStatusAndAutoSelectConfig {
    param(
        [switch]$PreserveCurrentSelection
    )

    $existingSelection = $null

    if ($null -ne $script:cmbConfig.SelectedItem) {
        $existingSelection = [string]$script:cmbConfig.SelectedItem
    }

    if (-not $PreserveCurrentSelection) {
        $script:cmbConfig.SelectedIndex = -1
    }

    # History belongs to the Unit Serial. Until the operator has typed one,
    # the computer name is only a guess: on a shared Boot Drive it is the
    # previous unit's name.
    $unitSerial = $script:txtSerial.Text.Trim()
    $serialIsGuess = $null -ne (Test-SerialNumberFormat -SerialNumber $unitSerial)
    if ($serialIsGuess) {
        $unitSerial = ([string]$env:COMPUTERNAME).Trim()
    }

    try {
        $script:UnitHistory = Get-UnitHistory -UnitSerial $unitSerial
        $script:IdentityState = Get-UnitIdentityState -History $script:UnitHistory -CurrentIdentity (Get-HardwareIdentity)
    }
    catch {
        Write-ErrorLog $_
        $script:UnitHistory = $null
        $script:IdentityState = New-IdentityState -Status "ERROR" -TrustedHistory $false `
            -UnitSerial $unitSerial -CurrentIdentity $null `
            -PreviousFingerprint "" -SummaryPath "" -Detail $_.Exception.Message
    }

    $lbl = $script:lblIdentity

    switch ($script:IdentityState.Status) {
        "MATCH"      { $lbl.Text = "Hardware Identity: MATCH"; $lbl.ForeColor = [System.Drawing.Color]::DarkGreen }
        "MISMATCH"   {
            if ($serialIsGuess) {
                $lbl.Text = "Hardware Identity: enter Unit Serial (name is from another unit)"
                $lbl.ForeColor = [System.Drawing.Color]::DarkOrange
            } else {
                $lbl.Text = "Hardware Identity: MISMATCH - motherboard differs from history"
                $lbl.ForeColor = [System.Drawing.Color]::DarkRed
            }
        }
        "UNVERIFIED" { $lbl.Text = "Hardware Identity: UNVERIFIED"; $lbl.ForeColor = [System.Drawing.Color]::DarkOrange }
        "NEW"        { $lbl.Text = "Hardware Identity: NEW / no previous history"; $lbl.ForeColor = [System.Drawing.Color]::DarkBlue }
        default      { $lbl.Text = "Hardware Identity: ERROR"; $lbl.ForeColor = [System.Drawing.Color]::DarkRed }
    }

    # When validation is already in progress, never erase or replace a
    # configuration the technician explicitly selected.
    if ($PreserveCurrentSelection -and -not [string]::IsNullOrWhiteSpace($existingSelection)) {
        if ($script:cmbConfig.Items.Contains($existingSelection)) {
            $script:cmbConfig.SelectedItem = $existingSelection
        }
        return
    }

    # Previous configuration is trusted only when the physical hardware
    # fingerprint matches the Unit History for this Unit Serial.
    if (-not $script:IdentityState.TrustedHistory -or $null -eq $script:UnitHistory.LatestRun) {
        return
    }

    try {
        $previousConfigName = [string]$script:UnitHistory.LatestRun.ConfigName
        $matchingBaseName = Find-ConfigBaseNameByConfigName -ConfigName $previousConfigName

        if (-not [string]::IsNullOrWhiteSpace($matchingBaseName) -and $script:cmbConfig.Items.Contains($matchingBaseName)) {
            $script:cmbConfig.SelectedItem = $matchingBaseName
        }
    }
    catch {
        Write-ErrorLog $_
        $script:cmbConfig.SelectedIndex = -1
    }
}

function Add-ResultRow {
    param($Result)

    $item = New-Object System.Windows.Forms.ListViewItem([string]$Result.Status)
    [void]$item.SubItems.Add([string]$Result.Section)
    [void]$item.SubItems.Add([string]$Result.Check)
    [void]$item.SubItems.Add([string]$Result.Detail)

    switch ([string]$Result.Status) {
        "PASS" { $item.BackColor = [System.Drawing.Color]::Honeydew }
        "FAIL" { $item.BackColor = [System.Drawing.Color]::MistyRose }
        "WARN" { $item.BackColor = [System.Drawing.Color]::LightYellow }
    }

    [void]$script:lvResults.Items.Add($item)
}

function Set-OverallLabel {
    param([string]$Text, $Color)

    $script:lblOverall.Text = "OVERALL RESULT: $Text"
    $script:lblOverall.BackColor = $Color
}

# Asks whether a motherboard mismatch is an intentional Hardware Change.
# Returns the operator's reason, or $null when validation must stop.
# Nothing is written here: the approval is recorded only if the run completes.
function Request-HardwareChangeReason {
    param($History, $CurrentIdentity)

    $changes = @(Get-HardwareChangeDetails -History $History -CurrentIdentity $CurrentIdentity)
    $changeText = if ($changes.Count -gt 0) {
        [string]::Join("`n`n", $changes)
    } else {
        "The stored and current hardware fingerprints differ."
    }

    $approve = Confirm-Message -Icon Warning -Title "Review Hardware Change" -DefaultNo -Text (
        "Unit '$($History.UnitSerial)' was previously tested on a different motherboard.`n`n$changeText`n`n" +
        "If this unit's motherboard was replaced during troubleshooting or repair, choose Yes to record the hardware change " +
        "and accept the current motherboard as its new baseline.`n`n" +
        "Choose No if the serial number may be mistyped or this is a different unit."
    )

    if (-not $approve) {
        return $null
    }

    $reason = Read-TextInput -Title "Hardware Change Approval" -Prompt (
        "Enter the reason for the motherboard replacement. Example: motherboard failed in Oven and was replaced:"
    )

    if ([string]::IsNullOrWhiteSpace($reason)) {
        Show-Message -Icon Warning -Title "Reason Required" -Text "A reason is required to approve a hardware change."
        return $null
    }

    return $reason.Trim()
}

# Traveler Confirmation: the operator checks the detected MAC addresses
# against the unit's System Traveler. Returns $true only on an explicit Yes.
function Confirm-TravelerMacs {
    param([string]$UnitSerial, $Snapshot)

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($a in @($Snapshot.Network.Adapters)) {
        $key = ConvertTo-MacKey ([string]$a.MacAddress)
        if ($key) {
            $lines.Add("  $([string]$a.InterfaceDescription)")
            $lines.Add("      $(Format-MacKey $key)")
        }
    }
    if ($lines.Count -eq 0) {
        $lines.Add("  (no network adapters with a MAC address were detected)")
    }

    return Confirm-Message -Icon Question -Title "Traveler Confirmation" -DefaultNo -Text (
        "Unit '$UnitSerial' has not been checked against its System Traveler yet.`n`n" +
        "Compare these MAC addresses with the System Traveler:`n`n" +
        [string]::Join("`n", $lines) + "`n`n" +
        "Is this the System Traveler for unit '$UnitSerial', and do ALL of these MAC addresses match it?"
    )
}

# Makes the operator confirm the serial before the computer is renamed to it
# (catches typos before a report is filed under the wrong serial).
function Confirm-SystemRename {
    param([string]$SerialNumber)

    $currentName = [string]$env:COMPUTERNAME

    return Confirm-Message -Icon Warning -Title "Confirm Computer Rename" -DefaultNo -Text (
        "The serial number you entered does not match this computer's current name.`n`n" +
        "    Current computer name:   $currentName`n" +
        "    Entered serial number:   $SerialNumber`n`n" +
        "If validation passes, this computer will be renamed to '$SerialNumber' (takes effect after a restart). " +
        "The validation report will be filed under that serial number either way.`n`n" +
        "Check the serial number carefully. Is '$SerialNumber' correct?"
    )
}

function Stop-AtSerialBox {
    $script:txtSerial.Focus() | Out-Null
    $script:txtSerial.SelectAll()
}

# One Validation Run. Every check that needs no answer from the operator runs
# first; then the questions; nothing is written to the Unit History until the
# run completes, so a stopped run leaves no files behind.
function Invoke-SystemValidation {
    $script:lvResults.Items.Clear()
    $script:txtMacs.Clear()
    Set-OverallLabel "RUNNING..." ([System.Drawing.Color]::LightYellow)
    $script:btnOpenReport.Enabled = $false
    $script:LastReportFolder = $null
    $script:form.Refresh()

    $finished = $false

    try {
        # --- Checks that need no operator answer ------------------------------
        $serial = $script:txtSerial.Text.Trim()
        $testPhase = [string]$script:cmbPhase.SelectedItem

        $serialError = Test-SerialNumberFormat -SerialNumber $serial
        if ($null -ne $serialError) {
            Show-Message -Icon Warning -Title "Serial Number" -Text $serialError
            Stop-AtSerialBox
            return
        }

        if ($null -eq $script:cmbPhase.SelectedItem) {
            Show-Message -Icon Warning -Title "Test Phase Required" -Text "Please select the current test phase before running validation."
            $script:cmbPhase.Focus() | Out-Null
            return
        }

        # Re-read this unit's history and motherboard identity, keeping any
        # Config the technician already selected.
        Update-IdentityStatusAndAutoSelectConfig -PreserveCurrentSelection
        $history = $script:UnitHistory
        $identity = $script:IdentityState

        if ($null -eq $history) {
            Show-Message -Icon Error -Title "Unit History Error" -Text "The unit's history or hardware identity could not be read:`n`n$($identity.Detail)"
            return
        }

        if ($null -eq $script:cmbConfig.SelectedItem) {
            Show-Message -Icon Warning -Title "Configuration Required" -Text "Please select a configuration."
            return
        }

        $configBaseName = [string]$script:cmbConfig.SelectedItem
        $configPath = Get-ConfigPath $configBaseName
        $integrity = Test-ConfigIntegrity -ConfigPath $configPath
        if (-not $integrity.Valid) {
            Show-Message -Icon Error -Title "Configuration Integrity Failure" -Text (
                "$($integrity.Detail)`n`nValidation will not continue with an unregistered or modified configuration. " +
                "Open Engineer mode and re-capture or edit and save the intended configuration."
            )
            return
        }

        $config = Read-HardwareConfig -Path $configPath
        $configErrors = @(Test-ConfigDefinition $config)
        if ($configErrors.Count -gt 0) {
            Show-Message -Icon Error -Title "Configuration Problems" -Text (
                "The selected configuration cannot be used:`n`n" + [string]::Join([Environment]::NewLine, $configErrors) +
                "`n`nOpen Engineer mode and fix it with Edit Config."
            )
            return
        }

        $currentName = [string]$env:COMPUTERNAME
        $pendingName = Get-PendingComputerName
        $renameAction = Get-RenameAction -SerialNumber $serial -CurrentName $currentName -PendingName $pendingName
        if ($renameAction -eq "Conflict") {
            Show-Message -Icon Warning -Title "Pending Rename Conflict" -Text (
                "This computer is named '$currentName', but Windows is set to rename it to '$pendingName' at the next restart.`n`n" +
                "Restart the computer and validate again. If '$pendingName' is the correct serial number, enter that instead."
            )
            return
        }

        $snapshot = Get-HardwareSnapshot

        # --- Operator questions (nothing written yet) -------------------------
        $confirmingTraveler = -not $history.TravelerConfirmed
        if ($confirmingTraveler) {
            if (-not (Confirm-TravelerMacs -UnitSerial $serial -Snapshot $snapshot)) {
                Show-Message -Icon Warning -Title "Validation Stopped" -Text (
                    "Validation stopped. Nothing was recorded.`n`n" +
                    "Check that the unit, its serial label and the System Traveler belong together, " +
                    "and that the MAC addresses were programmed."
                )
                Stop-AtSerialBox
                return
            }
        }

        $currentIdentity = $identity.CurrentIdentity
        # An approval only matters while the board differs from the latest run;
        # once a run is recorded on the new board, the identity simply MATCHes.
        $isMismatch = $identity.Status -eq "MISMATCH"
        $hardwareChangeApproved = $isMismatch -and (Test-HardwareChangeApproved -History $history -Fingerprint ([string]$currentIdentity.Fingerprint))
        $approvalReason = $null

        if ($isMismatch -and -not $hardwareChangeApproved) {
            $approvalReason = Request-HardwareChangeReason -History $history -CurrentIdentity $currentIdentity
            if ($null -eq $approvalReason) {
                Stop-AtSerialBox
                return
            }
            $hardwareChangeApproved = $true
        }

        if ($renameAction -eq "Rename" -and -not (Confirm-SystemRename -SerialNumber $serial)) {
            Stop-AtSerialBox
            return
        }

        # --- Checks ------------------------------------------------------------
        $results = @(Test-SystemAgainstConfig -Config $config -Snapshot $snapshot)

        if ($hardwareChangeApproved) {
            $identityResult = New-CheckResult "IDENTITY" "Hardware fingerprint" "PASS" `
                "Hardware change (motherboard replacement) approved in $script:AppMode mode for the current motherboard."
        } else {
            $identityStatus = if ($identity.Status -eq "MATCH") { "PASS" } else { "INFO" }
            $identityResult = New-CheckResult "IDENTITY" "Hardware fingerprint" $identityStatus ([string]$identity.Detail)
        }

        # Assigned MAC Addresses survive a Hardware Change, so they are always
        # compared with the Traveler Confirmation.
        if ($confirmingTraveler) {
            $macResult = New-CheckResult "MAC ADDRESSES" "System Traveler baseline" "PASS" `
                "Confirmed against the System Traveler by the operator in $script:AppMode mode (this run)."
        } else {
            $macResult = Compare-MacsToBaseline -History $history -Snapshot $snapshot
        }

        $results = @($results) + @($identityResult) + @($macResult)

        # --- Record the run ------------------------------------------------------
        if ($null -ne $approvalReason) {
            [void](Save-HardwareChangeApproval -History $history -CurrentIdentity $currentIdentity `
                -Reason $approvalReason -ApprovedByMode $script:AppMode)
        }

        # Rename only after every check has passed.
        $finalRenameAction = Get-RenameActionAfterValidation -Action $renameAction -ChecksPassed (Test-ChecksPassed -Results $results)
        $renameInfo = Rename-SystemToSerial -SerialNumber $serial -Action $finalRenameAction

        $summary = [string](Save-ValidationRun `
            -History $history `
            -TestPhase $testPhase `
            -AppMode $script:AppMode `
            -Config $config `
            -Snapshot $snapshot `
            -RenameInfo $renameInfo `
            -Results $results `
            -TravelerConfirmed $confirmingTraveler)

        # --- Show the outcome ----------------------------------------------------
        foreach ($r in $results) {
            Add-ResultRow $r
        }

        $macLines = [System.Collections.Generic.List[string]]::new()
        foreach ($a in @($snapshot.Network.Adapters)) {
            $macLines.Add("$([string]$a.InterfaceDescription) | $([string]$a.MacAddress) | $([string]$a.LinkSpeed) | $([string]$a.Status)")
        }
        $script:txtMacs.Text = [string]::Join([Environment]::NewLine, $macLines)

        $script:LastReportFolder = [string](Split-Path -Parent $summary)
        $script:btnOpenReport.Enabled = $true

        if ((Get-OverallResult -Results $results -RenameInfo $renameInfo) -eq "PASS") {
            Set-OverallLabel "PASS" ([System.Drawing.Color]::LightGreen)
        } else {
            Set-OverallLabel "FAIL" ([System.Drawing.Color]::LightCoral)
        }
        $finished = $true

        # The run is now part of the history; refresh the identity status.
        Update-IdentityStatusAndAutoSelectConfig -PreserveCurrentSelection

        if (-not $renameInfo.RenameSucceeded) {
            Show-Message -Icon Error -Title "Rename Error" -Text "Computer rename failed:`n$($renameInfo.Detail)"
        }
        elseif ($renameInfo.RebootRequired) {
            $restart = Confirm-Message -Title "Restart Required" -Text "The computer will be renamed to '$serial' after a restart.`n`nWould you like to restart now?"
            if ($restart) {
                Restart-Computer -Force
            }
        }
    }
    catch {
        $finished = $true
        Set-OverallLabel "ERROR" ([System.Drawing.Color]::LightCoral)
        Show-ErrorWithLog $_ "Validation Error"
    }
    finally {
        # Validation was stopped before running (missing input, declined
        # prompt, integrity failure): don't leave "RUNNING..." on screen.
        if (-not $finished) {
            Set-OverallLabel "-" ([System.Drawing.SystemColors]::Control)
        }
    }
}
