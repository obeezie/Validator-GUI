param(
    [ValidateSet("Production","Engineer")]
    [string]$AppMode = "Production"
)

# Hardware Validator GUI - entry point.
# Builds the main window and wires its buttons to the workflows in ui\.
# Requires Windows PowerShell 5.1 (built into Windows 10/11); no installs.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic

[System.Windows.Forms.Application]::EnableVisualStyles()
$ErrorActionPreference = "Stop"

$script:form = $null
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

$sourceFiles = @(
    "lib\Common.ps1",
    "lib\Integrity.ps1",
    "lib\Identity.ps1",
    "lib\Hardware.ps1",
    "lib\ConfigModel.ps1",
    "lib\Validation.ps1",
    "lib\Reports.ps1",
    "ui\Dialogs.ps1",
    "ui\CaptureWorkflow.ps1",
    "ui\ConfigEditor.ps1",
    "ui\ValidationWorkflow.ps1"
)

foreach ($relativePath in $sourceFiles) {
    $fullPath = Join-Path $ScriptRoot $relativePath
    if (-not (Test-Path $fullPath)) {
        [void][System.Windows.Forms.MessageBox]::Show(
            "Required file is missing:`n$fullPath`n`nCopy the entire HardwareValidator folder (including the lib and ui folders) to the USB drive.",
            "Hardware Validator - Missing Files",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
        exit 1
    }
    . $fullPath
}

Initialize-ValidatorPaths -Root $ScriptRoot

$TestPhases = @("Tier","Pre-Oven","Oven","Post-Oven")

# ---------------------------------------------------------------------------
# Main window
# ---------------------------------------------------------------------------

$form = New-Object System.Windows.Forms.Form
$form.Text = "Hardware Configuration Validator - $AppMode Mode"
$form.StartPosition = "CenterScreen"
$form.Size = New-Object System.Drawing.Size(1050,800)
$form.MinimumSize = New-Object System.Drawing.Size(900,690)
$script:form = $form

$lblConfig = New-Object System.Windows.Forms.Label
$lblConfig.Text = "Configuration:"
$lblConfig.Location = New-Object System.Drawing.Point(20,20)
$lblConfig.AutoSize = $true
$form.Controls.Add($lblConfig)

$cmbConfig = New-Object System.Windows.Forms.ComboBox
$cmbConfig.Location = New-Object System.Drawing.Point(120,16)
$cmbConfig.Size = New-Object System.Drawing.Size(280,25)
$cmbConfig.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$form.Controls.Add($cmbConfig)

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = "Refresh"
$btnRefresh.Location = New-Object System.Drawing.Point(410,15)
$btnRefresh.Size = New-Object System.Drawing.Size(80,28)
$form.Controls.Add($btnRefresh)

$lblSerial = New-Object System.Windows.Forms.Label
$lblSerial.Text = "Serial Number:"
$lblSerial.Location = New-Object System.Drawing.Point(20,58)
$lblSerial.AutoSize = $true
$form.Controls.Add($lblSerial)

$txtSerial = New-Object System.Windows.Forms.TextBox
$txtSerial.Location = New-Object System.Drawing.Point(120,54)
$txtSerial.Size = New-Object System.Drawing.Size(280,25)
$form.Controls.Add($txtSerial)

$lblPhase = New-Object System.Windows.Forms.Label
$lblPhase.Text = "Test Phase:"
$lblPhase.Location = New-Object System.Drawing.Point(20,92)
$lblPhase.AutoSize = $true
$form.Controls.Add($lblPhase)

$cmbPhase = New-Object System.Windows.Forms.ComboBox
$cmbPhase.Location = New-Object System.Drawing.Point(120,88)
$cmbPhase.Size = New-Object System.Drawing.Size(280,25)
$cmbPhase.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
foreach ($phase in $TestPhases) {
    [void]$cmbPhase.Items.Add($phase)
}
$cmbPhase.SelectedIndex = -1
$form.Controls.Add($cmbPhase)

$lblSystemName = New-Object System.Windows.Forms.Label
$lblSystemName.Text = "Computer Name: $env:COMPUTERNAME"
$lblSystemName.Location = New-Object System.Drawing.Point(510,90)
$lblSystemName.Size = New-Object System.Drawing.Size(460,24)
$lblSystemName.Font = New-Object System.Drawing.Font("Segoe UI",9,[System.Drawing.FontStyle]::Bold)
$form.Controls.Add($lblSystemName)

$lblIdentity = New-Object System.Windows.Forms.Label
$lblIdentity.Text = "Hardware Identity: checking..."
$lblIdentity.Location = New-Object System.Drawing.Point(510,112)
$lblIdentity.Size = New-Object System.Drawing.Size(460,24)
$lblIdentity.Font = New-Object System.Drawing.Font("Segoe UI",9,[System.Drawing.FontStyle]::Bold)
$form.Controls.Add($lblIdentity)

$btnValidate = New-Object System.Windows.Forms.Button
$btnValidate.Text = "Validate System"
$btnValidate.Location = New-Object System.Drawing.Point(510,15)
$btnValidate.Size = New-Object System.Drawing.Size(140,64)
$form.Controls.Add($btnValidate)

$btnCapture = New-Object System.Windows.Forms.Button
$btnCapture.Text = "Capture New Config"
$btnCapture.Location = New-Object System.Drawing.Point(660,15)
$btnCapture.Size = New-Object System.Drawing.Size(150,64)
$btnCapture.Visible = ($AppMode -eq "Engineer")
$form.Controls.Add($btnCapture)

$btnOpenReport = New-Object System.Windows.Forms.Button
$btnOpenReport.Text = "Open Report Folder"
$btnOpenReport.Location = New-Object System.Drawing.Point(820,15)
$btnOpenReport.Size = New-Object System.Drawing.Size(150,64)
$btnOpenReport.Enabled = $false
$form.Controls.Add($btnOpenReport)

# Engineer-only row below the input fields.
$btnEditConfig = New-Object System.Windows.Forms.Button
$btnEditConfig.Text = "Edit Selected Config"
$btnEditConfig.Location = New-Object System.Drawing.Point(20,138)
$btnEditConfig.Size = New-Object System.Drawing.Size(220,34)
$btnEditConfig.Visible = ($AppMode -eq "Engineer")
$form.Controls.Add($btnEditConfig)

$lblOverall = New-Object System.Windows.Forms.Label
$lblOverall.Text = "OVERALL RESULT: -"
$lblOverall.Location = New-Object System.Drawing.Point(20,190)
$lblOverall.Size = New-Object System.Drawing.Size(950,35)
$lblOverall.Font = New-Object System.Drawing.Font("Segoe UI",16,[System.Drawing.FontStyle]::Bold)
$lblOverall.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$form.Controls.Add($lblOverall)

$lvResults = New-Object System.Windows.Forms.ListView
$lvResults.Location = New-Object System.Drawing.Point(20,240)
$lvResults.Size = New-Object System.Drawing.Size(950,305)
$lvResults.View = [System.Windows.Forms.View]::Details
$lvResults.FullRowSelect = $true
$lvResults.GridLines = $true
$lvResults.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
[void]$lvResults.Columns.Add("Status",[int]75)
[void]$lvResults.Columns.Add("Section",[int]100)
[void]$lvResults.Columns.Add("Check",[int]230)
[void]$lvResults.Columns.Add("Detail",[int]520)
$form.Controls.Add($lvResults)

$grpMac = New-Object System.Windows.Forms.GroupBox
$grpMac.Text = "Detected MAC Addresses"
$grpMac.Location = New-Object System.Drawing.Point(20,565)
$grpMac.Size = New-Object System.Drawing.Size(950,130)
$grpMac.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($grpMac)

$txtMacs = New-Object System.Windows.Forms.TextBox
$txtMacs.Multiline = $true
$txtMacs.ReadOnly = $true
$txtMacs.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
$txtMacs.Location = New-Object System.Drawing.Point(10,22)
$txtMacs.Size = New-Object System.Drawing.Size(930,95)
$txtMacs.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$grpMac.Controls.Add($txtMacs)

$script:LastReportFolder = $null
$script:IdentityState = $null

# ---------------------------------------------------------------------------
# Button wiring
# ---------------------------------------------------------------------------

$btnRefresh.Add_Click({
    Refresh-Configs
    Update-IdentityStatusAndAutoSelectConfig -PreserveCurrentSelection
})

$btnValidate.Add_Click({ Invoke-SystemValidation })

# Once the operator has typed the Unit Serial, show that unit's identity
# status and pick its previous Config (the computer name may be stale).
$txtSerial.Add_Leave({
    try {
        Update-IdentityStatusAndAutoSelectConfig -PreserveCurrentSelection
    }
    catch {
        Write-ErrorLog $_
    }
})

$btnCapture.Add_Click({
    try {
        Invoke-ConfigCapture
    }
    catch {
        Show-ErrorWithLog $_ "Capture Error"
    }
})

$btnEditConfig.Add_Click({
    if ($null -eq $cmbConfig.SelectedItem) {
        Show-Message -Icon Warning -Title "Configuration Required" -Text "Select the configuration to edit first."
        return
    }

    try {
        [void](Show-ConfigEditor -ConfigBaseName ([string]$cmbConfig.SelectedItem))
    }
    catch {
        Show-ErrorWithLog $_ "Config Editor Error"
    }
})

$btnOpenReport.Add_Click({
    if ($script:LastReportFolder -and (Test-Path $script:LastReportFolder)) {
        Start-Process explorer.exe -ArgumentList "`"$script:LastReportFolder`""
    }
})

Refresh-Configs
Update-IdentityStatusAndAutoSelectConfig
[void]$form.ShowDialog()
