param(
    [ValidateSet("Production","Engineer")]
    [string]$AppMode = "Production"
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic

[System.Windows.Forms.Application]::EnableVisualStyles()
$ErrorActionPreference = "Stop"

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigDir = Join-Path $ScriptRoot "Configs"
$ReportDir = Join-Path $ScriptRoot "Reports"
$BurnInTestConfigDir = Join-Path $ScriptRoot "BurnInTestConfigs"
$ConfigManifestPath = Join-Path $ConfigDir "config_manifest.json"
$BurnInTestManifestPath = Join-Path $BurnInTestConfigDir "bitcfg_manifest.json"
$ErrorLog = Join-Path $ScriptRoot "HardwareValidator_Error.log"
$TestPhases = @("Tier","Pre-Oven","Oven","Post-Oven")

if (-not (Test-Path $ConfigDir)) {
    New-Item -ItemType Directory -Path $ConfigDir | Out-Null
}

if (-not (Test-Path $ReportDir)) {
    New-Item -ItemType Directory -Path $ReportDir | Out-Null
}
if (-not (Test-Path $BurnInTestConfigDir)) {
    New-Item -ItemType Directory -Path $BurnInTestConfigDir | Out-Null
}

function Write-ErrorLog {
    param($ErrorRecord)
    $text = @"
============================================================
$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
MESSAGE:
$($ErrorRecord.Exception.Message)

TYPE:
$($ErrorRecord.Exception.GetType().FullName)

SCRIPT STACK:
$($ErrorRecord.ScriptStackTrace)

POSITION:
$($ErrorRecord.InvocationInfo.PositionMessage)

FULL ERROR:
$($ErrorRecord | Out-String)
============================================================

"@
    Add-Content -Path $ErrorLog -Value $text -Encoding UTF8
}

function Convert-LinkSpeedToMbps {
    param([string]$LinkSpeed)

    if ([string]::IsNullOrWhiteSpace($LinkSpeed)) {
        return $null
    }

    if ($LinkSpeed -match '([\d\.]+)\s*Gbps') {
        return [double]([math]::Round(([double]$matches[1]) * 1000, 2))
    }

    if ($LinkSpeed -match '([\d\.]+)\s*Mbps') {
        return [double]([math]::Round([double]$matches[1], 2))
    }

    if ($LinkSpeed -match '([\d\.]+)\s*Kbps') {
        return [double]([math]::Round(([double]$matches[1]) / 1000, 3))
    }

    return $null
}

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

function Get-HardwareIdentity {
    $product = Get-CimInstance Win32_ComputerSystemProduct | Select-Object -First 1
    $bios = Get-CimInstance Win32_BIOS | Select-Object -First 1
    $baseboard = Get-CimInstance Win32_BaseBoard | Select-Object -First 1

    $uuid = ([string]$product.UUID).Trim().ToUpperInvariant()
    $biosSerial = ([string]$bios.SerialNumber).Trim().ToUpperInvariant()
    $baseboardSerial = ([string]$baseboard.SerialNumber).Trim().ToUpperInvariant()

    $parts = [System.Collections.Generic.List[string]]::new()

    if (Test-UsableHardwareIdValue $uuid) {
        $parts.Add("UUID=$uuid")
    }

    if (Test-UsableHardwareIdValue $biosSerial) {
        $parts.Add("BIOS=$biosSerial")
    }

    if (Test-UsableHardwareIdValue $baseboardSerial) {
        $parts.Add("BOARD=$baseboardSerial")
    }

    if ($parts.Count -eq 0) {
        return [pscustomobject]@{
            SystemUUID = $uuid
            BiosSerial = $biosSerial
            BaseboardSerial = $baseboardSerial
            Fingerprint = ""
            UsableComponentCount = 0
        }
    }

    $identityText = [string]::Join("|", $parts)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($identityText)
        $hashBytes = $sha.ComputeHash($bytes)
        $fingerprint = ([System.BitConverter]::ToString($hashBytes)).Replace("-","")
    }
    finally {
        $sha.Dispose()
    }

    return [pscustomobject]@{
        SystemUUID = $uuid
        BiosSerial = $biosSerial
        BaseboardSerial = $baseboardSerial
        Fingerprint = $fingerprint
        UsableComponentCount = [int]$parts.Count
    }
}

function Get-HardwareFingerprintFromSummary {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        return $null
    }

    foreach ($line in Get-Content -Path $Path -ErrorAction Stop) {
        if ($line -match '^Hardware Fingerprint\s*:\s*(.+)$') {
            $value = $matches[1].Trim().ToUpperInvariant()
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                return [string]$value
            }
        }
    }

    return $null
}

function Get-CurrentSystemIdentityState {
    $systemName = ([string]$env:COMPUTERNAME).Trim()
    $currentIdentity = Get-HardwareIdentity
    $summary = Get-LatestSummary -SerialNumber $systemName

    if ($null -eq $summary) {
        return [pscustomobject]@{
            Status = "NEW"
            TrustedHistory = $false
            SystemName = $systemName
            CurrentIdentity = $currentIdentity
            PreviousFingerprint = ""
            SummaryPath = ""
            Detail = "No previous report exists for the current Windows computer name."
        }
    }

    $previousFingerprint = Get-HardwareFingerprintFromSummary -Path $summary.FullName

    if ([string]::IsNullOrWhiteSpace($previousFingerprint)) {
        return [pscustomobject]@{
            Status = "UNVERIFIED"
            TrustedHistory = $false
            SystemName = $systemName
            CurrentIdentity = $currentIdentity
            PreviousFingerprint = ""
            SummaryPath = [string]$summary.FullName
            Detail = "Previous report found, but it predates hardware fingerprint tracking. Configuration history will not be trusted automatically."
        }
    }

    if ([string]::IsNullOrWhiteSpace([string]$currentIdentity.Fingerprint)) {
        return [pscustomobject]@{
            Status = "UNVERIFIED"
            TrustedHistory = $false
            SystemName = $systemName
            CurrentIdentity = $currentIdentity
            PreviousFingerprint = $previousFingerprint
            SummaryPath = [string]$summary.FullName
            Detail = "This system does not expose enough usable motherboard/system identifiers to verify the previous report."
        }
    }

    if ([string]$currentIdentity.Fingerprint -ieq $previousFingerprint) {
        return [pscustomobject]@{
            Status = "MATCH"
            TrustedHistory = $true
            SystemName = $systemName
            CurrentIdentity = $currentIdentity
            PreviousFingerprint = $previousFingerprint
            SummaryPath = [string]$summary.FullName
            Detail = "Current hardware fingerprint matches the previous report for this computer name."
        }
    }

    return [pscustomobject]@{
        Status = "MISMATCH"
        TrustedHistory = $false
        SystemName = $systemName
        CurrentIdentity = $currentIdentity
        PreviousFingerprint = $previousFingerprint
        SummaryPath = [string]$summary.FullName
        Detail = "The current Windows computer name has previous test history, but that history belongs to different physical hardware."
    }
}


function Get-FileSha256 {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        return $null
    }

    return (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Get-ConfigManifest {
    if (-not (Test-Path $ConfigManifestPath)) {
        return @{}
    }

    try {
        $raw = Get-Content -Path $ConfigManifestPath -Raw | ConvertFrom-Json
        $table = @{}

        foreach ($p in $raw.PSObject.Properties) {
            $table[$p.Name] = [string]$p.Value
        }

        return $table
    }
    catch {
        Write-ErrorLog $_
        return @{}
    }
}

function Save-ConfigManifest {
    param([hashtable]$Manifest)

    $obj = [ordered]@{}

    foreach ($key in ($Manifest.Keys | Sort-Object)) {
        $obj[$key] = $Manifest[$key]
    }

    # Temporarily clear read-only if this is an existing engineer-managed file.
    if (Test-Path $ConfigManifestPath) {
        try { (Get-Item $ConfigManifestPath).IsReadOnly = $false } catch {}
    }

    $obj | ConvertTo-Json -Depth 4 | Set-Content -Path $ConfigManifestPath -Encoding UTF8

    try {
        (Get-Item $ConfigManifestPath).IsReadOnly = $true
    } catch {}
}

function Register-ConfigIntegrity {
    param([string]$ConfigPath)

    $manifest = Get-ConfigManifest
    $fileName = [IO.Path]::GetFileName($ConfigPath)
    $manifest[$fileName] = Get-FileSha256 -Path $ConfigPath
    Save-ConfigManifest -Manifest $manifest

    try {
        (Get-Item $ConfigPath).IsReadOnly = $true
    } catch {}
}

function Test-ConfigIntegrity {
    param([string]$ConfigPath)

    $manifest = Get-ConfigManifest
    $fileName = [IO.Path]::GetFileName($ConfigPath)

    if (-not $manifest.ContainsKey($fileName)) {
        return [pscustomobject]@{
            Valid = $false
            Detail = "No engineer-generated integrity record exists for '$fileName'."
        }
    }

    $actual = Get-FileSha256 -Path $ConfigPath
    $expected = [string]$manifest[$fileName]

    if ($actual -ieq $expected) {
        return [pscustomobject]@{
            Valid = $true
            Detail = "Configuration integrity verified."
        }
    }

    return [pscustomobject]@{
        Valid = $false
        Detail = "Configuration file hash does not match the engineer-generated integrity record."
    }
}


function Get-BurnInTestManifest {
    if (-not (Test-Path $BurnInTestManifestPath)) { return @{} }
    try {
        $raw = Get-Content -Path $BurnInTestManifestPath -Raw | ConvertFrom-Json
        $table = @{}
        foreach ($p in $raw.PSObject.Properties) { $table[$p.Name] = [string]$p.Value }
        return $table
    } catch {
        Write-ErrorLog $_
        return @{}
    }
}

function Save-BurnInTestManifest {
    param([hashtable]$Manifest)
    $obj = [ordered]@{}
    foreach ($key in ($Manifest.Keys | Sort-Object)) { $obj[$key] = $Manifest[$key] }

    if (Test-Path $BurnInTestManifestPath) {
        try { (Get-Item $BurnInTestManifestPath).IsReadOnly = $false } catch {}
    }

    $obj | ConvertTo-Json -Depth 4 | Set-Content -Path $BurnInTestManifestPath -Encoding UTF8
    try { (Get-Item $BurnInTestManifestPath).IsReadOnly = $true } catch {}
}

function Register-BurnInTestConfigIntegrity {
    param([string]$Path)
    $manifest = Get-BurnInTestManifest
    $fileName = [IO.Path]::GetFileName($Path)
    $manifest[$fileName] = Get-FileSha256 -Path $Path
    Save-BurnInTestManifest -Manifest $manifest
    try { (Get-Item $Path).IsReadOnly = $true } catch {}
}

function Test-BurnInTestConfigIntegrity {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        return [pscustomobject]@{ Exists=$false; Valid=$false; Detail="BurnInTest configuration file is missing." }
    }

    $manifest = Get-BurnInTestManifest
    $fileName = [IO.Path]::GetFileName($Path)

    if (-not $manifest.ContainsKey($fileName)) {
        return [pscustomobject]@{ Exists=$true; Valid=$false; Detail="BurnInTest configuration exists but has no engineer-generated integrity record." }
    }

    $actual = Get-FileSha256 -Path $Path
    $expected = [string]$manifest[$fileName]

    if ($actual -ieq $expected) {
        return [pscustomobject]@{ Exists=$true; Valid=$true; Detail="BurnInTest configuration integrity verified." }
    }

    return [pscustomobject]@{ Exists=$true; Valid=$false; Detail="BurnInTest configuration hash does not match the engineer-generated integrity record." }
}

function Get-ExpectedBurnInTestConfigPath {
    param([string]$ConfigBaseName)
    return (Join-Path $BurnInTestConfigDir ($ConfigBaseName + ".bitcfg"))
}

function Ensure-BurnInTestConfigForCapture {
    param([string]$ConfigBaseName)

    $expectedPath = Get-ExpectedBurnInTestConfigPath -ConfigBaseName $ConfigBaseName

    if (Test-Path $expectedPath) {
        Register-BurnInTestConfigIntegrity -Path $expectedPath
        return [pscustomobject]@{ Success=$true; Path=$expectedPath; LinkedExisting=$false }
    }

    while ($true) {
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
        $lbl.Text = "A matching BurnInTest configuration was not found.`r`n`r`nCreate the BurnInTest configuration and save it as:`r`n$([IO.Path]::GetFileName($expectedPath))`r`n`r`nin:`r`n$BurnInTestConfigDir`r`n`r`nThen click Check Again, or link an existing .bitcfg file."
        $dialog.Controls.Add($lbl)

        $btnCheck = New-Object System.Windows.Forms.Button
        $btnCheck.Text = "Check Again"
        $btnCheck.Location = New-Object System.Drawing.Point(220,210)
        $btnCheck.Size = New-Object System.Drawing.Size(120,35)
        $dialog.Controls.Add($btnCheck)

        $btnLink = New-Object System.Windows.Forms.Button
        $btnLink.Text = "Link Existing..."
        $btnLink.Location = New-Object System.Drawing.Point(350,210)
        $btnLink.Size = New-Object System.Drawing.Size(130,35)
        $dialog.Controls.Add($btnLink)

        $btnCancel = New-Object System.Windows.Forms.Button
        $btnCancel.Text = "Cancel Capture"
        $btnCancel.Location = New-Object System.Drawing.Point(490,210)
        $btnCancel.Size = New-Object System.Drawing.Size(130,35)
        $dialog.Controls.Add($btnCancel)

        $script:BitConfigDialogAction = ""

        $btnCheck.Add_Click({ $script:BitConfigDialogAction = "CHECK"; $dialog.Close() })
        $btnLink.Add_Click({ $script:BitConfigDialogAction = "LINK"; $dialog.Close() })
        $btnCancel.Add_Click({ $script:BitConfigDialogAction = "CANCEL"; $dialog.Close() })

        [void]$dialog.ShowDialog($form)
        $action = [string]$script:BitConfigDialogAction
        $dialog.Dispose()

        if ($action -eq "CANCEL" -or [string]::IsNullOrWhiteSpace($action)) {
            return [pscustomobject]@{ Success=$false; Path=$expectedPath; LinkedExisting=$false }
        }

        if ($action -eq "CHECK") {
            if (Test-Path $expectedPath) {
                Register-BurnInTestConfigIntegrity -Path $expectedPath
                return [pscustomobject]@{ Success=$true; Path=$expectedPath; LinkedExisting=$false }
            }

            [void][System.Windows.Forms.MessageBox]::Show(
                "The expected file is still missing:`n$expectedPath",
                "BurnInTest Config Not Found",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            continue
        }

        if ($action -eq "LINK") {
            $ofd = New-Object System.Windows.Forms.OpenFileDialog
            $ofd.Title = "Select Existing BurnInTest Configuration"
            $ofd.Filter = "BurnInTest Config (*.bitcfg)|*.bitcfg|All Files (*.*)|*.*"
            $ofd.Multiselect = $false

            if ($ofd.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
                try {
                    if (Test-Path $expectedPath) {
                        try { (Get-Item $expectedPath).IsReadOnly = $false } catch {}
                    }

                    Copy-Item -Path $ofd.FileName -Destination $expectedPath -Force
                    Register-BurnInTestConfigIntegrity -Path $expectedPath

                    return [pscustomobject]@{ Success=$true; Path=$expectedPath; LinkedExisting=$true }
                }
                catch {
                    Write-ErrorLog $_
                    [void][System.Windows.Forms.MessageBox]::Show(
                        "Unable to link the BurnInTest configuration.`n`n$($_.Exception.Message)",
                        "BurnInTest Config Error",
                        [System.Windows.Forms.MessageBoxButtons]::OK,
                        [System.Windows.Forms.MessageBoxIcon]::Error
                    )
                }
            }
        }
    }
}

function Get-NetworkCaptureWarnings {
    param($Snapshot)

    $warnings = [System.Collections.Generic.List[string]]::new()

    foreach ($a in @($Snapshot.Network.Adapters)) {
        if ([string]$a.Status -ne "Up") {
            $warnings.Add("$([string]$a.InterfaceDescription) is not linked/up (Status=$([string]$a.Status)).")
        }
    }

    return @($warnings)
}

function Build-CapturePreviewText {
    param(
        [string]$Name,
        $Snapshot,
        $NetworkWarnings
    )

    $lines = [System.Collections.Generic.List[string]]::new()

    $lines.Add("Configuration: $Name")
    $lines.Add("")
    $lines.Add("SYSTEM")
    $lines.Add("  Manufacturer: $([string]$Snapshot.System.Manufacturer)")
    $lines.Add("  Model:        $([string]$Snapshot.System.Model)")
    $lines.Add("  System UUID:  $([string]$Snapshot.System.SystemUUID)")
    $lines.Add("  BIOS Serial:  $([string]$Snapshot.System.BiosSerial)")
    $lines.Add("  Board Serial: $([string]$Snapshot.System.BaseboardSerial)")
    $lines.Add("")
    $lines.Add("CPU")
    $lines.Add("  $([string]$Snapshot.CPU.Model)")
    $lines.Add("  Cores: $([int]$Snapshot.CPU.CoreCount)")
    $lines.Add("  Logical CPUs: $([int]$Snapshot.CPU.LogicalProcessors)")
    $lines.Add("")
    $lines.Add("MEMORY")
    $lines.Add("  Total RAM: $([double]$Snapshot.Memory.TotalGB) GB")
    $lines.Add("  DIMMs:     $([int]$Snapshot.Memory.DimmCount)")
    $lines.Add("")
    $lines.Add("STORAGE")

    foreach ($d in @($Snapshot.Storage.PhysicalDisks)) {
        $lines.Add("  $([string]$d.FriendlyName) | $([double]$d.SizeGB) GB | $([string]$d.BusType) | $([string]$d.HealthStatus)")
    }

    $lines.Add("")
    $lines.Add("NETWORK")

    foreach ($a in @($Snapshot.Network.Adapters)) {
        $lines.Add("  $([string]$a.InterfaceDescription)")
        $lines.Add("    Status: $([string]$a.Status)")
        $lines.Add("    Link:   $([string]$a.LinkSpeed)")
        $lines.Add("    MAC:    $([string]$a.MacAddress)")
    }

    $lines.Add("")
    $lines.Add("GPU")

    foreach ($g in @($Snapshot.GPU.Adapters)) {
        $lines.Add("  $([string]$g.Name)")
    }

    if (@($NetworkWarnings).Count -gt 0) {
        $lines.Add("")
        $lines.Add("WARNING - NETWORK LINK")
        foreach ($w in @($NetworkWarnings)) {
            $lines.Add("  $w")
        }
    }

    $lines.Add("")
    $lines.Add("Confirm that the above hardware is the intended known-good configuration.")

    return [string]::Join([Environment]::NewLine, $lines)
}

function Show-CaptureConfirmation {
    param(
        [string]$Name,
        $Snapshot,
        $NetworkWarnings
    )

    $preview = Build-CapturePreviewText -Name $Name -Snapshot $Snapshot -NetworkWarnings $NetworkWarnings

    if (@($NetworkWarnings).Count -gt 0) {
        $warningChoice = [System.Windows.Forms.MessageBox]::Show(
            "One or more physical network adapters are not linked/up.`n`n$([string]::Join([Environment]::NewLine, $NetworkWarnings))`n`nYou should normally correct the link before capturing a known-good configuration.`n`nContinue to the capture review anyway?",
            "Network Link Warning",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )

        if ($warningChoice -ne [System.Windows.Forms.DialogResult]::Yes) {
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
    $txt.Text = $preview
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

    $result = $reviewForm.ShowDialog($form)
    $reviewForm.Dispose()

    return ($result -eq [System.Windows.Forms.DialogResult]::OK)
}

function Get-HardwareIdentityFieldsFromSummary {
    param([string]$Path)

    $values = @{
        Fingerprint = ""
        SystemUUID = ""
        BiosSerial = ""
        BaseboardSerial = ""
    }

    if (-not (Test-Path $Path)) {
        return [pscustomobject]$values
    }

    foreach ($line in Get-Content -Path $Path -ErrorAction Stop) {
        if ($line -match '^Hardware Fingerprint\s*:\s*(.*)$') {
            $values.Fingerprint = $matches[1].Trim().ToUpperInvariant()
        }
        elseif ($line -match '^System UUID\s*:\s*(.*)$') {
            $values.SystemUUID = $matches[1].Trim().ToUpperInvariant()
        }
        elseif ($line -match '^BIOS Serial\s*:\s*(.*)$') {
            $values.BiosSerial = $matches[1].Trim().ToUpperInvariant()
        }
        elseif ($line -match '^Baseboard Serial\s*:\s*(.*)$') {
            $values.BaseboardSerial = $matches[1].Trim().ToUpperInvariant()
        }
    }

    return [pscustomobject]$values
}

function Get-HardwareChangeDetails {
    param($IdentityState)

    if ($null -eq $IdentityState -or $IdentityState.Status -ne "MISMATCH") {
        return @()
    }

    if ([string]::IsNullOrWhiteSpace([string]$IdentityState.SummaryPath)) {
        return @()
    }

    $previous = Get-HardwareIdentityFieldsFromSummary -Path $IdentityState.SummaryPath
    $current = $IdentityState.CurrentIdentity
    $changes = [System.Collections.Generic.List[string]]::new()

    if (
        -not [string]::IsNullOrWhiteSpace([string]$previous.SystemUUID) -and
        [string]$previous.SystemUUID -ine [string]$current.SystemUUID
    ) {
        $changes.Add("System UUID changed:`n  Previous: $([string]$previous.SystemUUID)`n  Current:  $([string]$current.SystemUUID)")
    }

    if (
        -not [string]::IsNullOrWhiteSpace([string]$previous.BiosSerial) -and
        [string]$previous.BiosSerial -ine [string]$current.BiosSerial
    ) {
        $changes.Add("BIOS serial changed:`n  Previous: $([string]$previous.BiosSerial)`n  Current:  $([string]$current.BiosSerial)")
    }

    if (
        -not [string]::IsNullOrWhiteSpace([string]$previous.BaseboardSerial) -and
        [string]$previous.BaseboardSerial -ine [string]$current.BaseboardSerial
    ) {
        $changes.Add("Baseboard serial changed:`n  Previous: $([string]$previous.BaseboardSerial)`n  Current:  $([string]$current.BaseboardSerial)")
    }

    return @($changes)
}

function Save-HardwareChangeApproval {
    param(
        [string]$SystemName,
        [string]$Reason,
        [string]$ApprovedByMode,
        $IdentityState
    )

    $folder = Join-Path $ReportDir $SystemName
    New-Item -ItemType Directory -Path $folder -Force | Out-Null

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $path = Join-Path $folder "${SystemName}_Hardware_Change_Approval_${timestamp}.txt"

    $old = Get-HardwareIdentityFieldsFromSummary -Path $IdentityState.SummaryPath
    $current = $IdentityState.CurrentIdentity

    @(
        "HARDWARE CHANGE APPROVAL"
        "========================"
        "Date/Time            : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        "System Name          : $SystemName"
        "Approved In Mode     : $ApprovedByMode"
        "Change Reason         : $Reason"
        ""
        "PREVIOUS HARDWARE"
        "Fingerprint          : $([string]$old.Fingerprint)"
        "System UUID          : $([string]$old.SystemUUID)"
        "BIOS Serial          : $([string]$old.BiosSerial)"
        "Baseboard Serial     : $([string]$old.BaseboardSerial)"
        ""
        "CURRENT HARDWARE"
        "Fingerprint          : $([string]$current.Fingerprint)"
        "System UUID          : $([string]$current.SystemUUID)"
        "BIOS Serial          : $([string]$current.BiosSerial)"
        "Baseboard Serial     : $([string]$current.BaseboardSerial)"
    ) | Set-Content -Path $path -Encoding UTF8

    return $path
}

function Test-HardwareChangeApprovalForCurrentIdentity {
    param($IdentityState)

    if ($null -eq $IdentityState -or $IdentityState.Status -ne "MISMATCH") {
        return $false
    }

    $systemName = [string]$IdentityState.SystemName
    $folder = Join-Path $ReportDir $systemName

    if (-not (Test-Path $folder)) {
        return $false
    }

    $currentFingerprint = ([string]$IdentityState.CurrentIdentity.Fingerprint).ToUpperInvariant()

    foreach ($file in Get-ChildItem -Path $folder -Filter "*_Hardware_Change_Approval_*.txt" -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending) {
        foreach ($line in Get-Content -Path $file.FullName -ErrorAction SilentlyContinue) {
            if ($line -match '^Fingerprint\s*:\s*(.+)$') {
                if ($matches[1].Trim().ToUpperInvariant() -eq $currentFingerprint) {
                    return $true
                }
            }
        }
    }

    return $false
}

function Get-HardwareSnapshot {
    $computer = Get-CimInstance Win32_ComputerSystem | Select-Object -First 1
    $bios = Get-CimInstance Win32_BIOS | Select-Object -First 1
    $hardwareIdentity = Get-HardwareIdentity
    $cpus = @(Get-CimInstance Win32_Processor)
    $mem = @(Get-CimInstance Win32_PhysicalMemory)

    $totalBytes = [double](($mem | Measure-Object -Property Capacity -Sum).Sum)
    $totalMemGB = [double][math]::Round(($totalBytes / 1GB), 2)

    $coreSum = [int](($cpus | Measure-Object -Property NumberOfCores -Sum).Sum)
    $logicalSum = [int](($cpus | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum)

    $disks = @(
        Get-PhysicalDisk |
        Where-Object { $_.BusType -notin @("USB","Virtual") } |
        ForEach-Object {
            [pscustomobject]@{
                FriendlyName = [string]$_.FriendlyName
                BusType = [string]$_.BusType
                MediaType = [string]$_.MediaType
                SizeGB = [double][math]::Round(([double]$_.Size / 1GB), 2)
                HealthStatus = [string]$_.HealthStatus
                SerialNumber = ([string]$_.SerialNumber).Trim()
            }
        }
    )

    $net = @(
        Get-NetAdapter -Physical |
        Sort-Object InterfaceDescription |
        ForEach-Object {
            $speedText = [string]$_.LinkSpeed
            [pscustomobject]@{
                Name = [string]$_.Name
                InterfaceDescription = [string]$_.InterfaceDescription
                Status = [string]$_.Status
                MacAddress = [string]$_.MacAddress
                LinkSpeed = $speedText
                LinkSpeedMbps = Convert-LinkSpeedToMbps $speedText
            }
        }
    )

    $gpus = @(
        Get-CimInstance Win32_VideoController |
        ForEach-Object {
            [pscustomobject]@{
                Name = [string]$_.Name
                DriverVersion = [string]$_.DriverVersion
            }
        }
    )

    return [pscustomobject]@{
        System = [pscustomobject]@{
            Manufacturer = [string]$computer.Manufacturer
            Model = [string]$computer.Model
            ComputerName = [string]$env:COMPUTERNAME
            BiosSerial = [string]$bios.SerialNumber
            BiosVersion = [string]$bios.SMBIOSBIOSVersion
            SystemUUID = [string]$hardwareIdentity.SystemUUID
            BaseboardSerial = [string]$hardwareIdentity.BaseboardSerial
            HardwareFingerprint = [string]$hardwareIdentity.Fingerprint
            HardwareIdComponentCount = [int]$hardwareIdentity.UsableComponentCount
        }
        CPU = [pscustomobject]@{
            Model = ([string]($cpus | Select-Object -First 1).Name).Trim()
            CoreCount = $coreSum
            LogicalProcessors = $logicalSum
        }
        Memory = [pscustomobject]@{
            TotalGB = $totalMemGB
            DimmCount = [int]$mem.Count
        }
        Storage = [pscustomobject]@{ PhysicalDisks = @($disks) }
        Network = [pscustomobject]@{ Adapters = @($net) }
        GPU = [pscustomobject]@{ Adapters = @($gpus) }
    }
}

function New-ConfigFromSnapshot {
    param($Snapshot,[string]$Name)

    return [pscustomobject]@{
        Name = $Name
        System = [pscustomobject]@{
            Manufacturer = [string]$Snapshot.System.Manufacturer
            Model = [string]$Snapshot.System.Model
        }
        CPU = [pscustomobject]@{
            ModelContains = [string]$Snapshot.CPU.Model
            MinimumCores = [int]$Snapshot.CPU.CoreCount
            MinimumLogicalCPUs = [int]$Snapshot.CPU.LogicalProcessors
        }
        Memory = [pscustomobject]@{
            MinimumTotalGB = [double]([math]::Floor(([double]$Snapshot.Memory.TotalGB * 0.95) * 100) / 100)
            ExpectedDIMMs = [int]$Snapshot.Memory.DimmCount
        }
        Storage = [pscustomobject]@{
            PhysicalDisks = @($Snapshot.Storage.PhysicalDisks | ForEach-Object {
                [pscustomobject]@{
                    FriendlyNameContains = [string]$_.FriendlyName
                    BusType = [string]$_.BusType
                    MinimumGB = [double][math]::Floor(([double]$_.SizeGB * 0.95))
                    Required = $true
                }
            })
        }
        Network = [pscustomobject]@{
            Adapters = @($Snapshot.Network.Adapters | ForEach-Object {
                [pscustomobject]@{
                    AdapterContains = [string]$_.InterfaceDescription
                    Required = $true
                    MinimumLinkMbps = if ($null -ne $_.LinkSpeedMbps) { [double]$_.LinkSpeedMbps } else { $null }
                    RequireUp = ([string]$_.Status -eq "Up")
                }
            })
        }
        GPU = [pscustomobject]@{
            Adapters = @($Snapshot.GPU.Adapters | ForEach-Object {
                [pscustomobject]@{
                    ModelContains = [string]$_.Name
                    Required = $true
                }
            })
        }
    }
}

function Rename-SystemToSerial {
    param([string]$SerialNumber)

    $current = [string]$env:COMPUTERNAME

    if ($current -ieq $SerialNumber) {
        return [pscustomobject]@{
            PreviousName=$current
            RequestedName=$SerialNumber
            RenameSucceeded=$true
            RebootRequired=$false
            Detail="Computer name already matches serial number."
        }
    }

    try {
        Rename-Computer -NewName $SerialNumber -Force -ErrorAction Stop
        return [pscustomobject]@{
            PreviousName=$current
            RequestedName=$SerialNumber
            RenameSucceeded=$true
            RebootRequired=$true
            Detail="Rename requested successfully. Reboot required."
        }
    }
    catch {
        return [pscustomobject]@{
            PreviousName=$current
            RequestedName=$SerialNumber
            RenameSucceeded=$false
            RebootRequired=$false
            Detail=[string]$_.Exception.Message
        }
    }
}

function Validate-AgainstConfig {
    param($Config,$Snapshot)

    $results = [System.Collections.Generic.List[object]]::new()

    $results.Add([pscustomobject]@{
        Section="SYSTEM"; Check="Manufacturer"
        Status=$(if ([string]$Snapshot.System.Manufacturer -eq [string]$Config.System.Manufacturer) {"PASS"} else {"FAIL"})
        Detail=[string]$Snapshot.System.Manufacturer
    })

    $results.Add([pscustomobject]@{
        Section="SYSTEM"; Check="Model"
        Status=$(if ([string]$Snapshot.System.Model -eq [string]$Config.System.Model) {"PASS"} else {"FAIL"})
        Detail=[string]$Snapshot.System.Model
    })

    $results.Add([pscustomobject]@{
        Section="CPU"; Check="Model"
        Status=$(if ([string]$Snapshot.CPU.Model -like "*$([string]$Config.CPU.ModelContains)*") {"PASS"} else {"FAIL"})
        Detail=[string]$Snapshot.CPU.Model
    })

    $results.Add([pscustomobject]@{
        Section="CPU"; Check="Cores"
        Status=$(if ([int]$Snapshot.CPU.CoreCount -ge [int]$Config.CPU.MinimumCores) {"PASS"} else {"FAIL"})
        Detail="$([int]$Snapshot.CPU.CoreCount) detected"
    })

    $results.Add([pscustomobject]@{
        Section="MEMORY"; Check="Total RAM"
        Status=$(if ([double]$Snapshot.Memory.TotalGB -ge [double]$Config.Memory.MinimumTotalGB) {"PASS"} else {"FAIL"})
        Detail="$([double]$Snapshot.Memory.TotalGB) GB"
    })

    $results.Add([pscustomobject]@{
        Section="MEMORY"; Check="DIMM Count"
        Status=$(if ([int]$Snapshot.Memory.DimmCount -eq [int]$Config.Memory.ExpectedDIMMs) {"PASS"} else {"FAIL"})
        Detail="$([int]$Snapshot.Memory.DimmCount) detected"
    })

    foreach ($expected in @($Config.Storage.PhysicalDisks)) {
        $actual = $Snapshot.Storage.PhysicalDisks |
            Where-Object {
                ([string]$_.FriendlyName -like "*$([string]$expected.FriendlyNameContains)*") -and
                ([string]$_.BusType -eq [string]$expected.BusType)
            } |
            Select-Object -First 1

        if ($null -eq $actual) {
            $results.Add([pscustomobject]@{
                Section="STORAGE"; Check=[string]$expected.FriendlyNameContains
                Status="FAIL"; Detail="Expected disk not found"
            })
        } else {
            $results.Add([pscustomobject]@{
                Section="STORAGE"; Check=[string]$expected.FriendlyNameContains
                Status=$(if ([double]$actual.SizeGB -ge [double]$expected.MinimumGB) {"PASS"} else {"FAIL"})
                Detail="$([double]$actual.SizeGB) GB, Health=$([string]$actual.HealthStatus), Serial=$([string]$actual.SerialNumber)"
            })
        }
    }

    foreach ($expected in @($Config.Network.Adapters)) {
        $actual = $Snapshot.Network.Adapters |
            Where-Object {
                [string]$_.InterfaceDescription -like "*$([string]$expected.AdapterContains)*"
            } |
            Select-Object -First 1

        if ($null -eq $actual) {
            $results.Add([pscustomobject]@{
                Section="NETWORK"; Check=[string]$expected.AdapterContains
                Status="FAIL"; Detail="Expected adapter not found"
            })
        } else {
            $status = "PASS"

            if ([bool]$expected.RequireUp -and [string]$actual.Status -ne "Up") {
                $status = "FAIL"
            }

            if ($null -ne $expected.MinimumLinkMbps -and $null -ne $actual.LinkSpeedMbps) {
                $min = [double]$expected.MinimumLinkMbps
                $actualMbps = [double]$actual.LinkSpeedMbps
                if ($actualMbps -lt $min) {
                    $status = "FAIL"
                }
            }

            $results.Add([pscustomobject]@{
                Section="NETWORK"; Check=[string]$expected.AdapterContains
                Status=$status
                Detail="Status=$([string]$actual.Status), Link=$([string]$actual.LinkSpeed), MAC=$([string]$actual.MacAddress)"
            })
        }
    }

    foreach ($expected in @($Config.GPU.Adapters)) {
        $actual = $Snapshot.GPU.Adapters |
            Where-Object {
                [string]$_.Name -like "*$([string]$expected.ModelContains)*"
            } |
            Select-Object -First 1

        $results.Add([pscustomobject]@{
            Section="GPU"; Check=[string]$expected.ModelContains
            Status=$(if ($null -ne $actual) {"PASS"} else {"FAIL"})
            Detail=$(if ($null -ne $actual) {[string]$actual.Name} else {"Expected GPU not found"})
        })
    }

    return @($results)
}


function Get-SerialReportFolder {
    param([string]$SerialNumber)

    return [string](Join-Path $ReportDir $SerialNumber)
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

function Get-MacsFromSummary {
    param([string]$Path)

    $records = [System.Collections.Generic.List[string]]::new()

    foreach ($line in Get-Content -Path $Path -ErrorAction Stop) {
        if ($line -match '^MAC RECORD\s*:\s*(.+)$') {
            $records.Add($matches[1].Trim().ToUpperInvariant())
        }
    }

    if ($records.Count -eq 0) {
        foreach ($line in Get-Content -Path $Path -ErrorAction Stop) {
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

    $previousSummary = Get-LatestSummary -SerialNumber $SerialNumber

    if ($null -eq $previousSummary) {
        return [pscustomobject]@{
            Section = "MAC HISTORY"
            Check = "Previous summary comparison"
            Status = "INFO"
            Detail = "No previous summary exists for this serial number. Current MAC addresses will become the baseline."
        }
    }

    $previousRecords = @(Get-MacsFromSummary -Path $previousSummary.FullName)
    $currentRecords = @(Get-CurrentMacRecords -Snapshot $Snapshot)

    if ($previousRecords.Count -eq 0) {
        return [pscustomobject]@{
            Section = "MAC HISTORY"
            Check = "Previous summary comparison"
            Status = "WARN"
            Detail = "A previous summary exists, but no MAC records could be read from '$($previousSummary.Name)'."
        }
    }

    $previousIsLegacy = @($previousRecords | Where-Object { $_ -like "MAC|*" }).Count -gt 0

    if ($previousIsLegacy) {
        $previousMacs = @(
            $previousRecords |
            ForEach-Object { ($_ -split '\|',2)[1] } |
            Sort-Object -Unique
        )

        $currentMacs = @(
            $Snapshot.Network.Adapters |
            ForEach-Object { ([string]$_.MacAddress).Trim().ToUpperInvariant() } |
            Sort-Object -Unique
        )

        $difference = @(
            Compare-Object -ReferenceObject $previousMacs -DifferenceObject $currentMacs
        )

        $oldDisplay = $previousMacs -join ", "
        $newDisplay = $currentMacs -join ", "
    }
    else {
        $difference = @(
            Compare-Object -ReferenceObject $previousRecords -DifferenceObject $currentRecords
        )

        $oldDisplay = $previousRecords -join "; "
        $newDisplay = $currentRecords -join "; "
    }

    if ($difference.Count -eq 0) {
        return [pscustomobject]@{
            Section = "MAC HISTORY"
            Check = "Previous summary comparison"
            Status = "PASS"
            Detail = "MAC addresses match the most recent summary ($($previousSummary.Name))."
        }
    }

    return [pscustomobject]@{
        Section = "MAC HISTORY"
        Check = "Previous summary comparison"
        Status = "FAIL"
        Detail = "MAC mismatch versus latest summary '$($previousSummary.Name)'. Previous: $oldDisplay | Current: $newDisplay"
    }
}

function Save-Summary {
    param(
        $SerialNumber,
        [string]$TestPhase,
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

    $failures = @($Results | Where-Object { $_.Status -eq "FAIL" })
    $overall = if ($failures.Count -eq 0 -and $RenameInfo.RenameSucceeded) {"PASS"} else {"FAIL"}

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("="*72)
    $lines.Add("HARDWARE VALIDATION SUMMARY")
    $lines.Add("="*72)
    $lines.Add("Date/Time      : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    $lines.Add("Serial Number  : $SerialNumber")
    $lines.Add("Test Phase     : $TestPhase")
    $lines.Add("Application Mode : $AppMode")
    $lines.Add("Configuration  : $([string]$Config.Name)")
    $lines.Add("BurnInTest Config : $([string]$Config.Name).bitcfg")
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


function Refresh-Configs {
    $previousSelection = $null

    if ($null -ne $cmbConfig.SelectedItem) {
        $previousSelection = [string]$cmbConfig.SelectedItem
    }

    $cmbConfig.Items.Clear()

    Get-ChildItem -Path $ConfigDir -Filter "*.json" -ErrorAction SilentlyContinue |
        Sort-Object Name |
        ForEach-Object {
            [void]$cmbConfig.Items.Add([string]$_.BaseName)
        }

    $cmbConfig.SelectedIndex = -1

    if (-not [string]::IsNullOrWhiteSpace($previousSelection)) {
        if ($cmbConfig.Items.Contains($previousSelection)) {
            $cmbConfig.SelectedItem = $previousSelection
        }
    }
}

function Get-ConfigurationNameFromSummary {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        return $null
    }

    foreach ($line in Get-Content -Path $Path -ErrorAction Stop) {
        if ($line -match '^Configuration\s*:\s*(.+)$') {
            return [string]$matches[1].Trim()
        }
    }

    return $null
}

function Find-ConfigBaseNameByConfigName {
    param([string]$ConfigName)

    if ([string]::IsNullOrWhiteSpace($ConfigName)) {
        return $null
    }

    foreach ($file in Get-ChildItem -Path $ConfigDir -Filter "*.json" -File -ErrorAction SilentlyContinue) {
        # First allow direct filename match.
        if ($file.BaseName -ieq $ConfigName) {
            return [string]$file.BaseName
        }

        # Then compare the Name stored inside the JSON config.
        try {
            $configObject = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json

            if ([string]$configObject.Name -ieq $ConfigName) {
                return [string]$file.BaseName
            }
        }
        catch {
            # Ignore an unreadable config here; validation will report it if selected manually.
        }
    }

    return $null
}

function Update-IdentityStatusAndAutoSelectConfig {
    param(
        [switch]$PreserveCurrentSelection
    )

    $existingSelection = $null

    if ($null -ne $cmbConfig.SelectedItem) {
        $existingSelection = [string]$cmbConfig.SelectedItem
    }

    if (-not $PreserveCurrentSelection) {
        $cmbConfig.SelectedIndex = -1
    }

    try {
        $script:IdentityState = Get-CurrentSystemIdentityState
    }
    catch {
        Write-ErrorLog $_
        $script:IdentityState = [pscustomobject]@{
            Status = "ERROR"
            TrustedHistory = $false
            SystemName = ([string]$env:COMPUTERNAME).Trim()
            CurrentIdentity = $null
            PreviousFingerprint = ""
            SummaryPath = ""
            Detail = $_.Exception.Message
        }
    }

    switch ($script:IdentityState.Status) {
        "MATCH" {
            $lblIdentity.Text = "Hardware Identity: MATCH"
            $lblIdentity.ForeColor = [System.Drawing.Color]::DarkGreen
        }
        "MISMATCH" {
            $lblIdentity.Text = "Hardware Identity: MISMATCH - stale hostname detected"
            $lblIdentity.ForeColor = [System.Drawing.Color]::DarkRed
        }
        "UNVERIFIED" {
            $lblIdentity.Text = "Hardware Identity: UNVERIFIED"
            $lblIdentity.ForeColor = [System.Drawing.Color]::DarkOrange
        }
        "NEW" {
            $lblIdentity.Text = "Hardware Identity: NEW / no previous history"
            $lblIdentity.ForeColor = [System.Drawing.Color]::DarkBlue
        }
        default {
            $lblIdentity.Text = "Hardware Identity: ERROR"
            $lblIdentity.ForeColor = [System.Drawing.Color]::DarkRed
        }
    }

    # When validation is already in progress, never erase or replace a
    # configuration the technician explicitly selected.
    if (
        $PreserveCurrentSelection -and
        -not [string]::IsNullOrWhiteSpace($existingSelection)
    ) {
        if ($cmbConfig.Items.Contains($existingSelection)) {
            $cmbConfig.SelectedItem = $existingSelection
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

        if (-not [string]::IsNullOrWhiteSpace($matchingBaseName)) {
            if ($cmbConfig.Items.Contains($matchingBaseName)) {
                $cmbConfig.SelectedItem = $matchingBaseName
            }
        }
    }
    catch {
        Write-ErrorLog $_
        $cmbConfig.SelectedIndex = -1
    }
}

function Add-ResultRow {
    param($Result)

    $item = New-Object System.Windows.Forms.ListViewItem([string]$Result.Status)
    [void]$item.SubItems.Add([string]$Result.Section)
    [void]$item.SubItems.Add([string]$Result.Check)
    [void]$item.SubItems.Add([string]$Result.Detail)

    if ([string]$Result.Status -eq "PASS") {
        $item.BackColor = [System.Drawing.Color]::Honeydew
    } elseif ([string]$Result.Status -eq "FAIL") {
        $item.BackColor = [System.Drawing.Color]::MistyRose
    }

    [void]$lvResults.Items.Add($item)
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "Hardware Configuration Validator - $AppMode Mode"
$form.StartPosition = "CenterScreen"
$form.Size = New-Object System.Drawing.Size(1050,800)
$form.MinimumSize = New-Object System.Drawing.Size(900,690)

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

$lblSystemName = New-Object System.Windows.Forms.Label
$lblSystemName.Text = "Current System: $env:COMPUTERNAME"
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

$btnValidate = New-Object System.Windows.Forms.Button
$btnValidate.Text = "Validate System"
$btnValidate.Location = New-Object System.Drawing.Point(510,15)
$btnValidate.Size = New-Object System.Drawing.Size(140,64)
$form.Controls.Add($btnValidate)

$btnCapture = New-Object System.Windows.Forms.Button
$btnCapture.Text = "Capture New Config"
$btnCapture.Location = New-Object System.Drawing.Point(660,15)
$btnCapture.Size = New-Object System.Drawing.Size(150,64)
$form.Controls.Add($btnCapture)

if ($AppMode -eq "Production") {
    $btnCapture.Visible = $false
}

$btnOpenReport = New-Object System.Windows.Forms.Button
$btnOpenReport.Text = "Open Report Folder"
$btnOpenReport.Location = New-Object System.Drawing.Point(820,15)
$btnOpenReport.Size = New-Object System.Drawing.Size(150,64)
$btnOpenReport.Enabled = $false
$form.Controls.Add($btnOpenReport)

$btnOpenBIT = New-Object System.Windows.Forms.Button
$btnOpenBIT.Text = "Open BIT Config Folder"
$btnOpenBIT.Location = New-Object System.Drawing.Point(20,138)
$btnOpenBIT.Size = New-Object System.Drawing.Size(220,34)
$btnOpenBIT.Visible = ($AppMode -eq "Engineer")
$form.Controls.Add($btnOpenBIT)


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

$btnRefresh.Add_Click({ Refresh-Configs; Update-IdentityStatusAndAutoSelectConfig -PreserveCurrentSelection })


$btnCapture.Add_Click({
    if ($AppMode -ne "Engineer") {
        [void][System.Windows.Forms.MessageBox]::Show(
            "Configuration capture is available only in Engineer mode.",
            "Engineer Mode Required",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        return
    }

    try {
        $name = [Microsoft.VisualBasic.Interaction]::InputBox(
            "Enter a name for this configuration:",
            "Capture Known-Good Configuration",
            ""
        )

        if ([string]::IsNullOrWhiteSpace($name)) { return }

        $snapshot = Get-HardwareSnapshot
        $warnings = @(Get-NetworkCaptureWarnings -Snapshot $snapshot)

        if (-not (Show-CaptureConfirmation -Name $name -Snapshot $snapshot -NetworkWarnings $warnings)) {
            return
        }

        $config = New-ConfigFromSnapshot -Snapshot $snapshot -Name $name
        $safeName = ($name -replace '[\\/:*?"<>|]','_')
        $path = Join-Path $ConfigDir ($safeName + ".json")

        $bitConfigResult = Ensure-BurnInTestConfigForCapture -ConfigBaseName $safeName
        if (-not $bitConfigResult.Success) {
            [void][System.Windows.Forms.MessageBox]::Show(
                "Configuration capture was cancelled because the required BurnInTest configuration was not provided.",
                "Capture Not Finalized",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            )
            return
        }

        if (Test-Path $path) {
            $overwrite = [System.Windows.Forms.MessageBox]::Show(
                "Configuration '$safeName' already exists.`n`nReplace the existing configuration?",
                "Replace Existing Configuration?",
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )

            if ($overwrite -ne [System.Windows.Forms.DialogResult]::Yes) {
                return
            }

            try { (Get-Item $path).IsReadOnly = $false } catch {}
        }

        $config | ConvertTo-Json -Depth 10 | Set-Content -Path $path -Encoding UTF8
        Register-ConfigIntegrity -ConfigPath $path

        Refresh-Configs
        $cmbConfig.SelectedItem = $safeName

        [void][System.Windows.Forms.MessageBox]::Show(
            "Configuration reviewed, captured, and integrity-registered.`n`nHardware config:`n$path`n`nBurnInTest config:`n$($bitConfigResult.Path)",
            "Capture Complete",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
    }
    catch {
        Write-ErrorLog $_
        [void][System.Windows.Forms.MessageBox]::Show(
            "$($_.Exception.Message)`n`nFull details were written to:`n$ErrorLog",
            "Capture Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
    }
})

$btnValidate.Add_Click({
    try {
        $lvResults.Items.Clear()
        $txtMacs.Clear()
        $lblOverall.Text = "OVERALL RESULT: RUNNING..."
        $lblOverall.BackColor = [System.Drawing.Color]::LightYellow
        $btnOpenReport.Enabled = $false
        $script:LastReportFolder = $null
        $form.Refresh()

        $serial = $txtSerial.Text.Trim()
$testPhase = [string]$cmbPhase.SelectedItem

        if ([string]::IsNullOrWhiteSpace($serial)) {
            [void][System.Windows.Forms.MessageBox]::Show(
                "Please enter a system serial number.",
                "Serial Number Required",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            return
        }

        if ($serial.Length -gt 15 -or $serial -notmatch '^[A-Za-z0-9-]+$') {
            [void][System.Windows.Forms.MessageBox]::Show(
                "Serial number must be 15 characters or fewer and contain only letters, numbers, or hyphens.",
                "Invalid Serial Number",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            return
        }

        if ($null -eq $cmbPhase.SelectedItem) {
            [void][System.Windows.Forms.MessageBox]::Show(
                "Please select the current test phase before running validation.",
                "Test Phase Required",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            $cmbPhase.Focus()
            return
        }

        # Re-check physical identity immediately before validation.
        # A removable/external Windows boot drive can carry an old hostname to
        # different physical hardware, so hostname history is trusted only when
        # the stored hardware fingerprint matches. Preserve any configuration
        # the technician has already selected manually.
        Update-IdentityStatusAndAutoSelectConfig -PreserveCurrentSelection

        $hardwareChangeApproved = Test-HardwareChangeApprovalForCurrentIdentity -IdentityState $script:IdentityState

        if (
            $script:IdentityState.Status -eq "MISMATCH" -and
            -not $hardwareChangeApproved
        ) {
            $changes = @(Get-HardwareChangeDetails -IdentityState $script:IdentityState)
            $changeText = if ($changes.Count -gt 0) {
                [string]::Join("`n`n", $changes)
            } else {
                "The stored and current hardware fingerprints differ."
            }

            $approval = [System.Windows.Forms.MessageBox]::Show(
                "Physical hardware mismatch detected.`n`n$changeText`n`nIf hardware was intentionally replaced during troubleshooting or repair, choose Yes to accept the current hardware as the new baseline. Choose No if this may be the wrong system or a transferred boot drive.",
                "Review Hardware Change",
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )

            if ($approval -ne [System.Windows.Forms.DialogResult]::Yes) {
                return
            }

            $reason = [Microsoft.VisualBasic.Interaction]::InputBox(
                "Enter the reason for the hardware replacement/change. Example: failed NIC replaced, motherboard swapped, storage controller replaced:",
                "Hardware Change Approval",
                ""
            )

            if ([string]::IsNullOrWhiteSpace($reason)) {
                [void][System.Windows.Forms.MessageBox]::Show(
                    "A reason is required to approve a hardware identity change.",
                    "Reason Required",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Warning
                )
                return
            }

            $approvalPath = Save-HardwareChangeApproval `
                -SystemName ([string]$script:IdentityState.SystemName) `
                -Reason $reason `
                -ApprovedByMode $AppMode `
                -IdentityState $script:IdentityState

            $hardwareChangeApproved = $true

            [void][System.Windows.Forms.MessageBox]::Show(
                "Hardware change approved and recorded:`n$approvalPath",
                "Hardware Change Approved",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            )
        }

        if (
            $script:IdentityState.Status -eq "MISMATCH" -and
            -not $hardwareChangeApproved -and
            $serial -ieq ([string]$env:COMPUTERNAME)
        ) {
            [void][System.Windows.Forms.MessageBox]::Show(
                "Hardware identity mismatch detected.`n`nThe current Windows computer name belongs to previous test history for different physical hardware. Because this boot drive appears to have moved to another system, enter the correct serial number for the CURRENT physical system. The new serial must be different from the stale computer name '$env:COMPUTERNAME'.",
                "New Serial Number Required",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            $txtSerial.Focus()
            $txtSerial.SelectAll()
            return
        }

        if ($null -eq $cmbConfig.SelectedItem) {
            [void][System.Windows.Forms.MessageBox]::Show(
                "Please select a configuration.",
                "Configuration Required",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            return
        }

        $selectedConfigBaseName = $cmbConfig.SelectedItem.ToString()
        $configPath = Join-Path $ConfigDir ($selectedConfigBaseName + ".json")

        $bitConfigPath = Get-ExpectedBurnInTestConfigPath -ConfigBaseName $selectedConfigBaseName
        $bitIntegrity = Test-BurnInTestConfigIntegrity -Path $bitConfigPath

        if (-not $bitIntegrity.Exists) {
            [void][System.Windows.Forms.MessageBox]::Show(
                "The selected hardware configuration does not have a matching BurnInTest configuration.`n`nExpected:`n$bitConfigPath`n`nValidation cannot continue until Engineer mode provides the required .bitcfg file.",
                "BurnInTest Config Missing",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            )
            return
        }

        if (-not $bitIntegrity.Valid) {
            [void][System.Windows.Forms.MessageBox]::Show(
                "$($bitIntegrity.Detail)`n`nExpected file:`n$bitConfigPath`n`nOpen Engineer mode and re-link or re-register the intended BurnInTest configuration.",
                "BurnInTest Config Integrity Failure",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            )
            return
        }

        $integrity = Test-ConfigIntegrity -ConfigPath $configPath
        if (-not $integrity.Valid) {
            [void][System.Windows.Forms.MessageBox]::Show(
                "$($integrity.Detail)`n`nProduction validation will not continue with an unregistered or modified configuration. Open Engineer mode and re-capture/re-register the intended configuration.",
                "Configuration Integrity Failure",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            )
            return
        }

        $config = Get-Content $configPath -Raw | ConvertFrom-Json

        $renameInfo = Rename-SystemToSerial -SerialNumber $serial
        $snapshot = Get-HardwareSnapshot
        $results = @(Validate-AgainstConfig -Config $config -Snapshot $snapshot)

        $historyIdentity = ([string]$renameInfo.PreviousName).Trim()

        if ($script:IdentityState.TrustedHistory -and -not $hardwareChangeApproved) {
            $macHistoryResult = Compare-MacsToLatestSummary `
                -SerialNumber $historyIdentity `
                -Snapshot $snapshot
        }
        elseif ($hardwareChangeApproved) {
            $macHistoryResult = [pscustomobject]@{
                Section = "MAC HISTORY"
                Check = "Previous summary comparison"
                Status = "INFO"
                Detail = "Intentional hardware replacement was approved. Previous MAC addresses were not used as the baseline for the replacement hardware."
            }
        }
        elseif ($script:IdentityState.Status -eq "MISMATCH") {
            $macHistoryResult = [pscustomobject]@{
                Section = "MAC HISTORY"
                Check = "Previous summary comparison"
                Status = "INFO"
                Detail = "Previous hostname history belongs to different physical hardware, so its MAC addresses were intentionally not used as a baseline."
            }
        }
        else {
            $macHistoryResult = [pscustomobject]@{
                Section = "MAC HISTORY"
                Check = "Previous summary comparison"
                Status = "INFO"
                Detail = "No trusted hardware-matched previous summary is available. Current MAC addresses will establish the baseline."
            }
        }

        $identityResult = [pscustomobject]@{
            Section = "IDENTITY"
            Check = "Hardware fingerprint"
            Status = $(if ($hardwareChangeApproved) {"PASS"} elseif ($script:IdentityState.Status -eq "MISMATCH") {"WARN"} elseif ($script:IdentityState.Status -eq "MATCH") {"PASS"} else {"INFO"})
            Detail = $(if ($hardwareChangeApproved) {"Intentional hardware change was approved in $AppMode mode for the current physical hardware."} else {[string]$script:IdentityState.Detail})
        }

        $results = @($results) + @($identityResult) + @($macHistoryResult)

        foreach ($r in $results) {
            Add-ResultRow $r
        }

        $macLines = [System.Collections.Generic.List[string]]::new()
        foreach ($a in @($snapshot.Network.Adapters)) {
            $macLines.Add("$([string]$a.InterfaceDescription) | $([string]$a.MacAddress) | $([string]$a.LinkSpeed) | $([string]$a.Status)")
        }
        $txtMacs.Text = [string]::Join([Environment]::NewLine, $macLines)

        $summary = [string](Save-Summary `
            -SerialNumber $serial `
            -TestPhase $testPhase `
            -Config $config `
            -Snapshot $snapshot `
            -RenameInfo $renameInfo `
            -Results $results)

        $script:LastReportFolder = [string](Split-Path -Parent $summary)
        $btnOpenReport.Enabled = $true

        $failures = @($results | Where-Object { $_.Status -eq "FAIL" })

        if ($failures.Count -eq 0 -and $renameInfo.RenameSucceeded) {
            $lblOverall.Text = "OVERALL RESULT: PASS"
            $lblOverall.BackColor = [System.Drawing.Color]::LightGreen
        } else {
            $lblOverall.Text = "OVERALL RESULT: FAIL"
            $lblOverall.BackColor = [System.Drawing.Color]::LightCoral
        }

        if (-not $renameInfo.RenameSucceeded) {
            [void][System.Windows.Forms.MessageBox]::Show(
                "Computer rename failed:`n$($renameInfo.Detail)",
                "Rename Error",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            )
        }
        elseif ($renameInfo.RebootRequired) {
            $choice = [System.Windows.Forms.MessageBox]::Show(
                "The computer was renamed to '$serial'.`n`nWould you like to restart now?",
                "Restart Required",
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Question
            )

            if ($choice -eq [System.Windows.Forms.DialogResult]::Yes) {
                Restart-Computer -Force
            }
        }
    }
    catch {
        Write-ErrorLog $_
        $lblOverall.Text = "OVERALL RESULT: ERROR"
        $lblOverall.BackColor = [System.Drawing.Color]::LightCoral

        [void][System.Windows.Forms.MessageBox]::Show(
            "$($_.Exception.Message)`n`nFull details were written to:`n$ErrorLog",
            "Validation Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
    }
})

$btnOpenReport.Add_Click({
    if ($script:LastReportFolder -and (Test-Path $script:LastReportFolder)) {
        Start-Process explorer.exe -ArgumentList $script:LastReportFolder
    }
})


$btnOpenBIT.Add_Click({
    try {
        if (-not (Test-Path $BurnInTestConfigDir)) {
            New-Item -ItemType Directory -Path $BurnInTestConfigDir -Force | Out-Null
        }
        Start-Process explorer.exe -ArgumentList "`"$BurnInTestConfigDir`""
    }
    catch {
        Write-ErrorLog $_
        [void][System.Windows.Forms.MessageBox]::Show(
            $_.Exception.Message,
            "Unable to Open Folder",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
    }
})

Refresh-Configs
Update-IdentityStatusAndAutoSelectConfig
[void]$form.ShowDialog()
