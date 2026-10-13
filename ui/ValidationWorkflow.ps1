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
        $script:IdentityState = Get-UnitIdentityState -History $script:UnitHistory -CurrentIdentity (& $script:Machine.ReadIdentity)
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

# The operator port for the real app: WinForms dialogs. Tests use a fake with
# the same keys (see Invoke-ValidationRun in lib\ValidationRun.ps1).
function New-DialogOperator {
    return @{
        ConfirmTraveler = {
            param($UnitSerial, $Adapters)

            $lines = [System.Collections.Generic.List[string]]::new()
            foreach ($a in @($Adapters)) {
                $lines.Add("  $($a.Description)")
                $lines.Add("      $($a.Mac)")
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

        ApproveHardwareChange = {
            param($UnitSerial, $Changes)

            $changeText = if (@($Changes).Count -gt 0) {
                [string]::Join("`n`n", @($Changes))
            } else {
                "The stored and current hardware fingerprints differ."
            }

            $approve = Confirm-Message -Icon Warning -Title "Review Hardware Change" -DefaultNo -Text (
                "Unit '$UnitSerial' was previously tested on a different motherboard.`n`n$changeText`n`n" +
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
            return $reason
        }

        ConfirmRename = {
            param($CurrentName, $UnitSerial)

            return Confirm-Message -Icon Warning -Title "Confirm Computer Rename" -DefaultNo -Text (
                "The serial number you entered does not match this computer's current name.`n`n" +
                "    Current computer name:   $CurrentName`n" +
                "    Entered serial number:   $UnitSerial`n`n" +
                "If validation passes, this computer will be renamed to '$UnitSerial' (takes effect after a restart). " +
                "The validation report will be filed under that serial number either way.`n`n" +
                "Check the serial number carefully. Is '$UnitSerial' correct?"
            )
        }
    }
}

# Runs one Validation Run (lib\ValidationRun.ps1) and shows its outcome.
function Invoke-SystemValidation {
    $script:lvResults.Items.Clear()
    $script:txtMacs.Clear()
    Set-OverallLabel "RUNNING..." ([System.Drawing.Color]::LightYellow)
    $script:btnOpenReport.Enabled = $false
    $script:LastReportFolder = $null
    $script:form.Refresh()

    try {
        # Refresh the identity status and auto-select this unit's previous
        # Config, keeping any Config the technician already selected.
        Update-IdentityStatusAndAutoSelectConfig -PreserveCurrentSelection

        $outcome = Invoke-ValidationRun `
            -UnitSerial $script:txtSerial.Text `
            -TestPhase ([string]$script:cmbPhase.SelectedItem) `
            -ConfigBaseName ([string]$script:cmbConfig.SelectedItem) `
            -AppMode $script:AppMode `
            -Operator $script:Operator `
            -Machine $script:Machine
    }
    catch {
        Set-OverallLabel "ERROR" ([System.Drawing.Color]::LightCoral)
        Show-ErrorWithLog $_ "Validation Error"
        return
    }

    if ($outcome.Status -eq "Stopped") {
        Set-OverallLabel "-" ([System.Drawing.SystemColors]::Control)
        if ($null -ne $outcome.Message) {
            Show-Message -Icon Warning -Title $outcome.Title -Text $outcome.Message
        }
        switch ($outcome.Focus) {
            "Serial" { $script:txtSerial.Focus() | Out-Null; $script:txtSerial.SelectAll() }
            "Phase"  { $script:cmbPhase.Focus() | Out-Null }
            "Config" { $script:cmbConfig.Focus() | Out-Null }
        }
        return
    }

    foreach ($r in $outcome.Results) {
        Add-ResultRow $r
    }

    $macLines = [System.Collections.Generic.List[string]]::new()
    foreach ($a in @($outcome.Snapshot.Network.Adapters)) {
        $macLines.Add("$([string]$a.InterfaceDescription) | $([string]$a.MacAddress) | $([string]$a.LinkSpeed) | $([string]$a.Status)")
    }
    $script:txtMacs.Text = [string]::Join([Environment]::NewLine, $macLines)

    $script:LastReportFolder = [string](Split-Path -Parent $outcome.SummaryPath)
    $script:btnOpenReport.Enabled = $true

    if ($outcome.OverallResult -eq "PASS") {
        Set-OverallLabel "PASS" ([System.Drawing.Color]::LightGreen)
    } else {
        Set-OverallLabel "FAIL" ([System.Drawing.Color]::LightCoral)
    }

    # The run is now part of the Unit History; refresh the identity status.
    try { Update-IdentityStatusAndAutoSelectConfig -PreserveCurrentSelection } catch { Write-ErrorLog $_ }

    $renameInfo = $outcome.RenameInfo
    if (-not $renameInfo.RenameSucceeded) {
        Show-Message -Icon Error -Title "Rename Error" -Text "Computer rename failed:`n$($renameInfo.Detail)"
    }
    elseif ($renameInfo.RebootRequired) {
        $restart = Confirm-Message -Title "Restart Required" -Text "The computer will be renamed to '$($renameInfo.RequestedName)' after a restart.`n`nWould you like to restart now?"
        if ($restart) {
            Restart-Computer -Force
        }
    }
}
