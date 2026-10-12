# Engineer Mode: capture a new known-good configuration from this system.

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

    # Ask about replacing before the hardware scan and review.
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

    $config = New-ConfigFromSnapshot -Snapshot $snapshot -Name $name
    Save-HardwareConfig -Config $config -Path $path

    Refresh-Configs
    $script:cmbConfig.SelectedItem = $safeName

    $openEditor = Confirm-Message -Icon Information -Title "Capture Complete" -Text (
        "Configuration reviewed, captured, and integrity-registered.`n`n" +
        "Hardware config:`n$path`n`n" +
        "All components were saved as Required. Open the config editor now to adjust limits or mark components optional?"
    )

    if ($openEditor) {
        [void](Show-ConfigEditor -ConfigBaseName $safeName)
    }
}
