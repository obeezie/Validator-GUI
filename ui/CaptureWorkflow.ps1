# Engineer Mode: capture a new known-good configuration from this system and
# pair it with a BurnInTest .bitcfg file.

function Show-CaptureConfirmation {
    param(
        [string]$Name,
        $Snapshot,
        $NetworkWarnings
    )

    if (@($NetworkWarnings).Count -gt 0) {
        $continue = Confirm-Message -Icon Warning -Title "Network Link Warning" -Text (
            "One or more physical network adapters are not linked/up.`n`n" +
            [string]::Join([Environment]::NewLine, $NetworkWarnings) +
            "`n`nYou should normally correct the link before capturing a known-good configuration.`n`nContinue to the capture review anyway?"
        )

        if (-not $continue) {
            return $false
        }
    }

    $reviewForm = New-Object System.Windows.Forms.Form
    $reviewForm.Text = "Engineer Capture Review"
    $reviewForm.StartPosition = "CenterParent"
    $reviewForm.Size = New-Object System.Drawing.Size(800,700)

    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Multiline = $true
    $txt.ReadOnly = $true
    $txt.ScrollBars = [System.Windows.Forms.ScrollBars]::Both
    $txt.WordWrap = $false
    $txt.Location = New-Object System.Drawing.Point(15,15)
    $txt.Size = New-Object System.Drawing.Size(750,590)
    $txt.Text = Build-CapturePreviewText -Name $Name -Snapshot $Snapshot -NetworkWarnings $NetworkWarnings
    $reviewForm.Controls.Add($txt)

    $btnConfirm = New-Object System.Windows.Forms.Button
    $btnConfirm.Text = "Confirm and Save"
    $btnConfirm.Location = New-Object System.Drawing.Point(480,620)
    $btnConfirm.Size = New-Object System.Drawing.Size(140,32)
    $btnConfirm.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $reviewForm.Controls.Add($btnConfirm)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.Location = New-Object System.Drawing.Point(630,620)
    $btnCancel.Size = New-Object System.Drawing.Size(100,32)
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $reviewForm.Controls.Add($btnCancel)

    $reviewForm.AcceptButton = $btnConfirm
    $reviewForm.CancelButton = $btnCancel

    $result = $reviewForm.ShowDialog($script:form)
    $reviewForm.Dispose()

    return ($result -eq [System.Windows.Forms.DialogResult]::OK)
}

# Shows Check Again / Link Existing / Cancel until a .bitcfg is in place.
# Returns "CHECK", "LINK" or "CANCEL".
function Show-BurnInTestConfigPrompt {
    param([string]$ExpectedPath)

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = "BurnInTest Configuration Required"
    $dialog.StartPosition = "CenterParent"
    $dialog.Size = New-Object System.Drawing.Size(700,310)
    $dialog.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Location = New-Object System.Drawing.Point(20,20)
    $lbl.Size = New-Object System.Drawing.Size(645,160)
    $lbl.Text = "A known-good BurnInTest configuration is required.`r`n`r`nCreate the BurnInTest configuration and save it as:`r`n$([IO.Path]::GetFileName($ExpectedPath))`r`n`r`nin:`r`n$script:BurnInTestConfigDir`r`n`r`nThen click Check Again, or link an existing .bitcfg file."
    $dialog.Controls.Add($lbl)

    $state = @{ Action = "CANCEL" }

    $buttons = @(
        @{ Text = "Check Again";     X = 220; Width = 120; Action = "CHECK" },
        @{ Text = "Link Existing..."; X = 350; Width = 130; Action = "LINK" },
        @{ Text = "Cancel Capture";  X = 490; Width = 130; Action = "CANCEL" }
    )

    foreach ($b in $buttons) {
        $btn = New-Object System.Windows.Forms.Button
        $btn.Text = $b.Text
        $btn.Tag = $b.Action
        $btn.Location = New-Object System.Drawing.Point($b.X,210)
        $btn.Size = New-Object System.Drawing.Size($b.Width,35)
        $btn.Add_Click({ param($sender, $e) $state.Action = [string]$sender.Tag; $dialog.Close() })
        $dialog.Controls.Add($btn)
    }

    [void]$dialog.ShowDialog($script:form)
    $dialog.Dispose()

    return [string]$state.Action
}

function Request-BurnInTestConfigForCapture {
    param([string]$ConfigBaseName)

    $expectedPath = Get-ExpectedBurnInTestConfigPath -ConfigBaseName $ConfigBaseName
    $success = [pscustomobject]@{ Success=$true; Path=$expectedPath }
    $failure = [pscustomobject]@{ Success=$false; Path=$expectedPath }

    if (Test-Path $expectedPath) {
        $check = Test-BurnInTestConfigIntegrity -Path $expectedPath

        if ($check.Valid) {
            return $success
        }

        # Never silently re-trust a file that changed or was never registered.
        $useExisting = Confirm-Message -Icon Warning -Title "Existing BurnInTest Config" -DefaultNo -Text (
            "A BurnInTest configuration already exists:`n$expectedPath`n`n$($check.Detail)`n`n" +
            "Use this file as-is and register it as known-good?`n`nChoose No to link a different file or cancel."
        )

        if ($useExisting) {
            Register-BurnInTestConfigIntegrity -Path $expectedPath
            return $success
        }
    }

    while ($true) {
        $action = Show-BurnInTestConfigPrompt -ExpectedPath $expectedPath

        if ($action -eq "CANCEL") {
            return $failure
        }

        if ($action -eq "CHECK") {
            if (Test-Path $expectedPath) {
                Register-BurnInTestConfigIntegrity -Path $expectedPath
                return $success
            }

            Show-Message -Icon Warning -Title "BurnInTest Config Not Found" -Text "The expected file is still missing:`n$expectedPath"
            continue
        }

        if ($action -eq "LINK") {
            $ofd = New-Object System.Windows.Forms.OpenFileDialog
            $ofd.Title = "Select Existing BurnInTest Configuration"
            $ofd.Filter = "BurnInTest Config (*.bitcfg)|*.bitcfg|All Files (*.*)|*.*"
            $ofd.Multiselect = $false

            if ($ofd.ShowDialog($script:form) -eq [System.Windows.Forms.DialogResult]::OK) {
                try {
                    $source = [IO.Path]::GetFullPath($ofd.FileName)
                    $target = [IO.Path]::GetFullPath($expectedPath)

                    if ($source -ine $target) {
                        Set-FileReadOnlyState -Path $expectedPath -ReadOnly $false
                        Copy-Item -Path $source -Destination $target -Force
                    }

                    Register-BurnInTestConfigIntegrity -Path $expectedPath
                    return $success
                }
                catch {
                    Write-ErrorLog $_
                    Show-Message -Icon Error -Title "BurnInTest Config Error" -Text "Unable to link the BurnInTest configuration.`n`n$($_.Exception.Message)"
                }
            }
        }
    }
}

function Invoke-ConfigCapture {
    if ($script:AppMode -ne "Engineer") {
        Show-Message -Icon Warning -Title "Engineer Mode Required" -Text "Configuration capture is available only in Engineer mode."
        return
    }

    $name = Read-TextInput -Prompt "Enter a name for this configuration:" -Title "Capture Known-Good Configuration"
    if ([string]::IsNullOrWhiteSpace($name)) { return }
    $name = $name.Trim()

    $safe = ConvertTo-SafeConfigName -Name $name
    if ($null -ne $safe.Error) {
        Show-Message -Icon Warning -Title "Invalid Configuration Name" -Text $safe.Error
        return
    }

    $safeName = [string]$safe.Name
    $path = Get-ConfigPath $safeName

    # Ask about replacing before anything (including the .bitcfg) is touched.
    if (Test-Path $path) {
        $replace = Confirm-Message -Icon Warning -Title "Replace Existing Configuration?" -DefaultNo `
            -Text "Configuration '$safeName' already exists.`n`nReplace the existing configuration?"
        if (-not $replace) { return }
    }

    $snapshot = Get-HardwareSnapshot
    $warnings = @(Get-NetworkCaptureWarnings -Snapshot $snapshot)

    if (-not (Show-CaptureConfirmation -Name $name -Snapshot $snapshot -NetworkWarnings $warnings)) {
        return
    }

    $bitConfigResult = Request-BurnInTestConfigForCapture -ConfigBaseName $safeName
    if (-not $bitConfigResult.Success) {
        Show-Message -Title "Capture Not Finalized" -Text "Configuration capture was cancelled because the required BurnInTest configuration was not provided."
        return
    }

    $config = New-ConfigFromSnapshot -Snapshot $snapshot -Name $name
    Save-HardwareConfig -Config $config -Path $path

    Refresh-Configs
    $script:cmbConfig.SelectedItem = $safeName

    $openEditor = Confirm-Message -Icon Information -Title "Capture Complete" -Text (
        "Configuration reviewed, captured, and integrity-registered.`n`n" +
        "Hardware config:`n$path`n`nBurnInTest config:`n$($bitConfigResult.Path)`n`n" +
        "All components were saved as Required. Open the config editor now to adjust limits or mark components optional?"
    )

    if ($openEditor) {
        [void](Show-ConfigEditor -ConfigBaseName $safeName)
    }
}
