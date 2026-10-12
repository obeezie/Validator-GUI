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

    try {
        $script:IdentityState = Get-CurrentSystemIdentityState
    }
    catch {
        Write-ErrorLog $_
        $script:IdentityState = New-IdentityState -Status "ERROR" -TrustedHistory $false `
            -SystemName ([string]$env:COMPUTERNAME).Trim() -CurrentIdentity $null `
            -PreviousFingerprint "" -SummaryPath "" -Detail $_.Exception.Message
    }

    $lbl = $script:lblIdentity

    switch ($script:IdentityState.Status) {
        "MATCH"      { $lbl.Text = "Hardware Identity: MATCH"; $lbl.ForeColor = [System.Drawing.Color]::DarkGreen }
        "MISMATCH"   { $lbl.Text = "Hardware Identity: MISMATCH - stale hostname detected"; $lbl.ForeColor = [System.Drawing.Color]::DarkRed }
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
    # fingerprint matches the report history for this Windows computer name.
    if (-not $script:IdentityState.TrustedHistory) {
        return
    }

    $summaryPath = [string]$script:IdentityState.SummaryPath

    if ([string]::IsNullOrWhiteSpace($summaryPath)) {
        return
    }

    try {
        $previousConfigName = Get-ConfigurationNameFromSummary -Path $summaryPath
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

# Handles a hardware identity MISMATCH. Returns $true when the current
# hardware is (or has just been) approved, $false when validation must stop.
function Request-HardwareChangeApproval {
    $changes = @(Get-HardwareChangeDetails -IdentityState $script:IdentityState)
    $changeText = if ($changes.Count -gt 0) {
        [string]::Join("`n`n", $changes)
    } else {
        "The stored and current hardware fingerprints differ."
    }

    $approve = Confirm-Message -Icon Warning -Title "Review Hardware Change" -Text (
        "Physical hardware mismatch detected.`n`n$changeText`n`n" +
        "If hardware was intentionally replaced during troubleshooting or repair, choose Yes to accept the current hardware as the new baseline. " +
        "Choose No if this may be the wrong system or a transferred boot drive."
    )

    if (-not $approve) {
        return $false
    }

    $reason = Read-TextInput -Title "Hardware Change Approval" -Prompt (
        "Enter the reason for the hardware replacement/change. Example: failed NIC replaced, motherboard swapped, storage controller replaced:"
    )

    if ([string]::IsNullOrWhiteSpace($reason)) {
        Show-Message -Icon Warning -Title "Reason Required" -Text "A reason is required to approve a hardware identity change."
        return $false
    }

    $approvalPath = Save-HardwareChangeApproval `
        -SystemName ([string]$script:IdentityState.SystemName) `
        -Reason $reason.Trim() `
        -ApprovedByMode $script:AppMode `
        -IdentityState $script:IdentityState

    Show-Message -Title "Hardware Change Approved" -Text "Hardware change approved and recorded:`n$approvalPath"
    return $true
}

# Decides whether the computer needs renaming to the serial and, if so,
# makes the operator confirm the serial first (catches typos before the
# computer is renamed and a report is filed under the wrong serial).
# Returns "None", "Pending" or "Rename", or $null when the operator declined.
function Confirm-SystemRename {
    param([string]$SerialNumber)

    $currentName = [string]$env:COMPUTERNAME
    $action = Get-RenameAction -SerialNumber $SerialNumber -CurrentName $currentName -PendingName (Get-PendingComputerName)

    if ($action -ne "Rename") {
        return $action
    }

    $confirmed = Confirm-Message -Icon Warning -Title "Confirm Computer Rename" -DefaultNo -Text (
        "The serial number you entered does not match this computer's current name.`n`n" +
        "    Current computer name:   $currentName`n" +
        "    Entered serial number:   $SerialNumber`n`n" +
        "Continuing will rename this computer to '$SerialNumber' (takes effect after a restart) " +
        "and file the validation report under that serial number.`n`n" +
        "Check the serial number carefully. Is '$SerialNumber' correct?"
    )

    if ($confirmed) {
        return "Rename"
    }
    return $null
}

function Invoke-SystemValidation {
    $script:lvResults.Items.Clear()
    $script:txtMacs.Clear()
    Set-OverallLabel "RUNNING..." ([System.Drawing.Color]::LightYellow)
    $script:btnOpenReport.Enabled = $false
    $script:LastReportFolder = $null
    $script:form.Refresh()

    $finished = $false

    try {
        $serial = $script:txtSerial.Text.Trim()
        $testPhase = [string]$script:cmbPhase.SelectedItem

        $serialError = Test-SerialNumberFormat -SerialNumber $serial
        if ($null -ne $serialError) {
            Show-Message -Icon Warning -Title "Serial Number" -Text $serialError
            $script:txtSerial.Focus()
            return
        }

        if ($null -eq $script:cmbPhase.SelectedItem) {
            Show-Message -Icon Warning -Title "Test Phase Required" -Text "Please select the current test phase before running validation."
            $script:cmbPhase.Focus()
            return
        }

        # Re-check physical identity immediately before validation.
        # A removable/external Windows boot drive can carry an old hostname to
        # different physical hardware, so hostname history is trusted only when
        # the stored hardware fingerprint matches. Preserve any configuration
        # the technician has already selected manually.
        Update-IdentityStatusAndAutoSelectConfig -PreserveCurrentSelection

        $hardwareChangeApproved = Test-HardwareChangeApprovalForCurrentIdentity -IdentityState $script:IdentityState

        if ($script:IdentityState.Status -eq "MISMATCH" -and -not $hardwareChangeApproved) {
            if (-not (Request-HardwareChangeApproval)) {
                return
            }
            $hardwareChangeApproved = $true
        }

        if ($null -eq $script:cmbConfig.SelectedItem) {
            Show-Message -Icon Warning -Title "Configuration Required" -Text "Please select a configuration."
            return
        }

        $configBaseName = [string]$script:cmbConfig.SelectedItem
        $configPath = Get-ConfigPath $configBaseName
        $bitConfigPath = Get-ExpectedBurnInTestConfigPath -ConfigBaseName $configBaseName
        $bitIntegrity = Test-BurnInTestConfigIntegrity -Path $bitConfigPath

        if (-not $bitIntegrity.Exists) {
            Show-Message -Icon Error -Title "BurnInTest Config Missing" -Text (
                "The selected hardware configuration does not have a matching BurnInTest configuration.`n`n" +
                "Expected:`n$bitConfigPath`n`nValidation cannot continue until Engineer mode provides the required .bitcfg file."
            )
            return
        }

        if (-not $bitIntegrity.Valid) {
            Show-Message -Icon Error -Title "BurnInTest Config Integrity Failure" -Text (
                "$($bitIntegrity.Detail)`n`nExpected file:`n$bitConfigPath`n`n" +
                "Open Engineer mode and re-link or re-register the intended BurnInTest configuration."
            )
            return
        }

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

        $renameAction = Confirm-SystemRename -SerialNumber $serial
        if ($null -eq $renameAction) {
            $script:txtSerial.Focus()
            $script:txtSerial.SelectAll()
            return
        }

        $renameInfo = Rename-SystemToSerial -SerialNumber $serial -Action $renameAction
        $snapshot = Get-HardwareSnapshot
        $results = @(Test-SystemAgainstConfig -Config $config -Snapshot $snapshot)

        $historyIdentity = ([string]$renameInfo.PreviousName).Trim()

        if ($hardwareChangeApproved) {
            $macHistoryResult = New-CheckResult "MAC HISTORY" "Previous summary comparison" "INFO" `
                "Intentional hardware replacement was approved. Previous MAC addresses were not used as the baseline for the replacement hardware."
        }
        elseif ($script:IdentityState.TrustedHistory) {
            $macHistoryResult = Compare-MacsToLatestSummary -SerialNumber $historyIdentity -Snapshot $snapshot
        }
        else {
            $macHistoryResult = New-CheckResult "MAC HISTORY" "Previous summary comparison" "INFO" `
                "No trusted hardware-matched previous summary is available. Current MAC addresses will establish the baseline."
        }

        if ($hardwareChangeApproved) {
            $identityResult = New-CheckResult "IDENTITY" "Hardware fingerprint" "PASS" `
                "Intentional hardware change was approved in $script:AppMode mode for the current physical hardware."
        } else {
            $identityStatus = if ($script:IdentityState.Status -eq "MATCH") { "PASS" } else { "INFO" }
            $identityResult = New-CheckResult "IDENTITY" "Hardware fingerprint" $identityStatus ([string]$script:IdentityState.Detail)
        }

        $results = @($results) + @($identityResult) + @($macHistoryResult)

        foreach ($r in $results) {
            Add-ResultRow $r
        }

        $macLines = [System.Collections.Generic.List[string]]::new()
        foreach ($a in @($snapshot.Network.Adapters)) {
            $macLines.Add("$([string]$a.InterfaceDescription) | $([string]$a.MacAddress) | $([string]$a.LinkSpeed) | $([string]$a.Status)")
        }
        $script:txtMacs.Text = [string]::Join([Environment]::NewLine, $macLines)

        $summary = [string](Save-Summary `
            -SerialNumber $serial `
            -TestPhase $testPhase `
            -AppMode $script:AppMode `
            -ConfigBaseName $configBaseName `
            -Config $config `
            -Snapshot $snapshot `
            -RenameInfo $renameInfo `
            -Results $results)

        $script:LastReportFolder = [string](Split-Path -Parent $summary)
        $script:btnOpenReport.Enabled = $true

        if ((Get-OverallResult -Results $results -RenameInfo $renameInfo) -eq "PASS") {
            Set-OverallLabel "PASS" ([System.Drawing.Color]::LightGreen)
        } else {
            Set-OverallLabel "FAIL" ([System.Drawing.Color]::LightCoral)
        }
        $finished = $true

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
