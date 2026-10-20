# Self-contained tests for the validator's non-UI logic.
# No modules to install: run with the PowerShell already on the machine.
#
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
#
# Exit code is the number of failed tests.

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

foreach ($name in @("Common","Integrity","Identity","Hardware","ConfigModel","Validation","UnitHistory","ValidationRun")) {
    . (Join-Path (Join-Path $repoRoot "lib") "$name.ps1")
}

$script:Passed = 0
$script:Failed = [System.Collections.Generic.List[string]]::new()

function Test-Case {
    param([string]$Name, [scriptblock]$Body)

    try {
        & $Body
        $script:Passed++
        Write-Host "  PASS  $Name" -ForegroundColor Green
    }
    catch {
        $script:Failed.Add($Name)
        Write-Host "  FAIL  $Name" -ForegroundColor Red
        Write-Host "        $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message = "")
    if ($Expected -ne $Actual) {
        throw "Expected <$Expected> but got <$Actual>. $Message"
    }
}

function Assert-True {
    param($Condition, [string]$Message = "condition was false")
    if (-not $Condition) { throw $Message }
}

function New-TestRoot {
    $root = Join-Path ([IO.Path]::GetTempPath()) ("hv-tests-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $root | Out-Null
    Initialize-ValidatorPaths -Root $root
    return $root
}

function Remove-TestRoot {
    param([string]$Root)
    Get-ChildItem -Path $Root -Recurse -File | ForEach-Object { $_.IsReadOnly = $false }
    Remove-Item -Path $Root -Recurse -Force
}

function New-TestSnapshot {
    return [pscustomobject]@{
        System = [pscustomobject]@{
            Manufacturer = "HP"; Model = "HP Laptop 15-fc0xxx"
            HardwareFingerprint = "ABC"; SystemUUID = "U"; BiosSerial = "B"; BaseboardSerial = "BB"
        }
        CPU = [pscustomobject]@{ Model = "AMD Ryzen 5 7520U with Radeon Graphics"; CoreCount = 4; LogicalProcessors = 8 }
        Memory = [pscustomobject]@{ TotalGB = 16; DimmCount = 2 }
        Storage = [pscustomobject]@{ PhysicalDisks = @(
            [pscustomobject]@{ FriendlyName = "WD PC SN740"; BusType = "NVMe"; SizeGB = 238.47; HealthStatus = "Healthy"; SerialNumber = "S1" }
        ) }
        Network = [pscustomobject]@{ Adapters = @(
            [pscustomobject]@{ Name = "Wi-Fi"; InterfaceDescription = "Realtek RTL8852BE-VS WiFi 6 802.11ax PCIe Adapter"; Status = "Up"; MacAddress = "40-1A-58-83-6F-A0"; LinkSpeed = "72.2 Mbps"; LinkSpeedMbps = 72.2; IsWireless = $true },
            [pscustomobject]@{ Name = "Ethernet"; InterfaceDescription = "Intel(R) Ethernet I219-LM"; Status = "Up"; MacAddress = "00-11-22-33-44-55"; LinkSpeed = "1 Gbps"; LinkSpeedMbps = 1000; IsWireless = $false }
        ) }
        GPU = [pscustomobject]@{ Adapters = @(
            [pscustomobject]@{ Name = "AMD Radeon(TM) Graphics"; DriverVersion = "1" }
        ) }
        Devices = @(
            (New-TestDevice "Boot Shield" @("USB\VID_1234&PID_0001&REV_0200", "USB\VID_1234&PID_0001")),
            (New-TestDevice "Intel(R) Ethernet I219-LM" @("PCI\VEN_8086&DEV_15BB&SUBSYS_00001234&REV_10", "PCI\VEN_8086&DEV_15BB&SUBSYS_00001234", "PCI\VEN_8086&DEV_15BB"))
        )
    }
}

function New-TestDevice {
    param([string]$Name, [string[]]$HardwareIds, [int]$ErrorCode = 0, [string]$Class = "USB")
    return [pscustomobject]@{ Name = $Name; Class = $Class; HardwareIds = $HardwareIds; InstanceId = ($HardwareIds[0] + "\1"); ErrorCode = $ErrorCode }
}

function Get-ResultFor {
    param($Results, [string]$Section, [string]$CheckLike)
    return @($Results | Where-Object { $_.Section -eq $Section -and $_.Check -like $CheckLike })
}

Write-Host "Common"

Test-Case "Link speed parsing" {
    Assert-Equal 1000 (Convert-LinkSpeedToMbps "1 Gbps")
    Assert-Equal 72.2 (Convert-LinkSpeedToMbps "72.2 Mbps")
    Assert-Equal $null (Convert-LinkSpeedToMbps "0 bps")
    Assert-Equal $null (Convert-LinkSpeedToMbps "")
}

Test-Case "Contains text treats brackets and wildcards literally" {
    Assert-True (Test-ContainsText "Intel(R) Ethernet [Rev 2]" "[Rev 2]")
    Assert-True (Test-ContainsText "AMD Radeon(TM) Graphics" "radeon(tm)")
    Assert-True (-not (Test-ContainsText "Intel NIC" "Intel*X"))
    Assert-True (Test-ContainsText "anything" "")
}

Test-Case "Invariant number parsing" {
    Assert-Equal 15.2 (ConvertTo-InvariantDouble "15.2")
    Assert-Equal $null (ConvertTo-InvariantDouble "abc")
}

Write-Host "Hardware / rename"

Test-Case "Wireless adapter detection" {
    Assert-True (Test-WirelessAdapter -PhysicalMediaType "Native 802.11" -NdisPhysicalMedium 9 -Description "x")
    Assert-True (Test-WirelessAdapter -PhysicalMediaType "" -NdisPhysicalMedium $null -Description "Intel(R) Wi-Fi 6E AX211")
    Assert-True (-not (Test-WirelessAdapter -PhysicalMediaType "802.3" -NdisPhysicalMedium 14 -Description "Intel(R) Ethernet I219-LM"))
}

Test-Case "Serial number format rules" {
    Assert-Equal $null (Test-SerialNumberFormat "DEV2")
    Assert-Equal $null (Test-SerialNumberFormat "ABC-123")
    Assert-True ($null -ne (Test-SerialNumberFormat ""))
    Assert-True ($null -ne (Test-SerialNumberFormat "1234567"))
    Assert-True ($null -ne (Test-SerialNumberFormat "ABCDEFGHIJKLMNOP"))
    Assert-True ($null -ne (Test-SerialNumberFormat "AB_12"))
}

Write-Host "Identity"

Test-Case "Fingerprint ignores placeholder IDs" {
    $a = New-HardwareIdentity -SystemUUID "33444335-3733-3633-4347-473637334435" -BiosSerial "5CD33736CG" -BaseboardSerial "To be filled by O.E.M."
    $b = New-HardwareIdentity -SystemUUID "33444335-3733-3633-4347-473637334435" -BiosSerial "5cd33736cg" -BaseboardSerial "Default string"
    Assert-Equal 2 $a.UsableComponentCount
    Assert-Equal $a.Fingerprint $b.Fingerprint
    $none = New-HardwareIdentity -SystemUUID "00000000-0000-0000-0000-000000000000" -BiosSerial "" -BaseboardSerial "N/A"
    Assert-Equal "" $none.Fingerprint
}

Write-Host "Config model"

Test-Case "Captured config: all components required, no Wi-Fi speed minimum" {
    $config = New-ConfigFromSnapshot -Snapshot (New-TestSnapshot) -Name "test"
    Assert-True ($config.Storage.PhysicalDisks[0].Required)
    Assert-True ($config.GPU.Adapters[0].Required)
    $wifi = @($config.Network.Adapters | Where-Object { $_.AdapterContains -like "*WiFi*" })[0]
    $lan = @($config.Network.Adapters | Where-Object { $_.AdapterContains -like "*Ethernet*" })[0]
    Assert-True ($wifi.Required)
    Assert-Equal $null $wifi.MinimumLinkMbps
    Assert-Equal 1000 $lan.MinimumLinkMbps
    Assert-Equal 15.2 $config.Memory.MinimumTotalGB
    Assert-Equal 226 $config.Storage.PhysicalDisks[0].MinimumGB
}

Test-Case "Normalizing an older config defaults Required to true" {
    $raw = '{"Name":"old","System":{"Manufacturer":"HP","Model":"M"},"CPU":{"ModelContains":"AMD","MinimumCores":4},"Memory":{"MinimumTotalGB":8,"ExpectedDIMMs":1},"Storage":{"PhysicalDisks":[{"FriendlyNameContains":"WD","BusType":"NVMe","MinimumGB":200}]},"Network":{"Adapters":[{"AdapterContains":"Intel","Required":false,"MinimumLinkMbps":null,"RequireUp":true}]},"GPU":{"Adapters":[]}}' | ConvertFrom-Json
    $config = ConvertTo-NormalizedConfig $raw
    Assert-True ($config.Storage.PhysicalDisks[0].Required)
    Assert-True (-not $config.Network.Adapters[0].Required)
    Assert-Equal 0 $config.CPU.MinimumLogicalCPUs
    Assert-Equal 0 @($config.GPU.Adapters).Count
    Assert-Equal 0 @(Test-ConfigDefinition $config).Count
}

Test-Case "Config list excludes the manifest, names are sanitized" {
    $root = New-TestRoot
    try {
        Set-Content -Path (Join-Path $script:ConfigDir "A.json") -Value "{}"
        Set-Content -Path $script:ConfigManifestPath -Value "{}"
        Assert-Equal "A" ((Get-ConfigBaseNames) -join ",")
        Assert-Equal "a_b" (ConvertTo-SafeConfigName "a/b").Name
        Assert-True ($null -ne (ConvertTo-SafeConfigName "config_manifest").Error)
        Assert-True ($null -ne (ConvertTo-SafeConfigName " . ").Error)
    }
    finally { Remove-TestRoot $root }
}

Test-Case "Save, integrity check, read back" {
    $root = New-TestRoot
    try {
        $path = Get-ConfigPath "test"
        $config = New-ConfigFromSnapshot -Snapshot (New-TestSnapshot) -Name "test"
        Save-HardwareConfig -Config $config -Path $path

        Assert-True (Test-ConfigIntegrity -ConfigPath $path).Valid
        $loaded = Read-HardwareConfig -Path $path
        Assert-Equal 1 @($loaded.Storage.PhysicalDisks).Count "single disk must stay an array"
        Assert-Equal 2 @($loaded.Network.Adapters).Count

        (Get-Item $path).IsReadOnly = $false
        Add-Content -Path $path -Value " "
        $check = Test-ConfigIntegrity -ConfigPath $path
        Assert-True (-not $check.Valid)
        Assert-True ($check.Exists)
    }
    finally { Remove-TestRoot $root }
}

Test-Case "Editor data: blank rows skipped, numbers parsed, errors reported" {
    $general = @{ Name = "t"; Manufacturer = "HP"; Model = "M"; CpuModelContains = "AMD"; MinimumCores = 4; MinimumLogicalCPUs = 8; MinimumTotalGB = 15.2; ExpectedDIMMs = 2 }
    $ok = ConvertFrom-ConfigEditorData -General $general `
        -StorageRows @(@{ FriendlyNameContains = "WD"; BusType = "NVMe"; MinimumGB = "226"; Required = $false }, @{ FriendlyNameContains = ""; BusType = $null; MinimumGB = ""; Required = $true }) `
        -NetworkRows @(@{ AdapterContains = "Intel"; Required = [System.DBNull]::Value; RequireUp = $true; MinimumLinkMbps = "" }) `
        -GpuRows @()
    Assert-Equal 0 @($ok.Errors).Count (@($ok.Errors) -join "; ")
    Assert-Equal 1 @($ok.Config.Storage.PhysicalDisks).Count
    Assert-True (-not $ok.Config.Storage.PhysicalDisks[0].Required)
    Assert-True ($ok.Config.Network.Adapters[0].Required) "new row with unset checkbox defaults to Required"
    Assert-Equal $null $ok.Config.Network.Adapters[0].MinimumLinkMbps

    $bad = ConvertFrom-ConfigEditorData -General $general `
        -StorageRows @(@{ FriendlyNameContains = "WD"; BusType = ""; MinimumGB = "lots"; Required = $true }) `
        -NetworkRows @(@{ AdapterContains = "Intel"; Required = $true; RequireUp = $true; MinimumLinkMbps = "fast" }) `
        -GpuRows @()
    Assert-Equal $null $bad.Config
    Assert-True (@($bad.Errors).Count -ge 3) (@($bad.Errors) -join "; ")
}

Test-Case "Editor note flags wireless rows whose minimum is ignored" {
    Assert-Equal "" (Get-NetworkAdapterEditorNote -AdapterContains "Intel(R) Ethernet I219-LM" -MinimumLinkMbps "1000")
    Assert-Equal "Wireless: minimum ignored, not checked" (Get-NetworkAdapterEditorNote -AdapterContains "Realtek RTL8852BE-VS WiFi 6 802.11ax PCIe Adapter" -MinimumLinkMbps "72.2")
    Assert-Equal "Wireless: link speed not checked" (Get-NetworkAdapterEditorNote -AdapterContains "Intel(R) Wi-Fi 6E AX211" -MinimumLinkMbps "")
}

Test-Case "Required Devices: normalized, edited, and need a hardware ID" {
    $raw = '{"Name":"d","System":{"Manufacturer":"HP","Model":"M"},"CPU":{"ModelContains":"AMD","MinimumCores":4},"Memory":{"MinimumTotalGB":8,"ExpectedDIMMs":1},"Devices":[{"Name":"Boot Shield","HardwareId":"USB\\VID_1234&PID_0001"}]}' | ConvertFrom-Json
    $config = ConvertTo-NormalizedConfig $raw
    Assert-Equal 1 @($config.Devices).Count
    Assert-True ($config.Devices[0].Required) "devices default to Required"
    Assert-Equal 0 @((ConvertTo-NormalizedConfig ('{"Name":"x"}' | ConvertFrom-Json)).Devices).Count "older configs have no devices"

    $general = @{ Name = "t"; Manufacturer = "HP"; Model = "M"; CpuModelContains = "AMD"; MinimumCores = 4; MinimumLogicalCPUs = 0; MinimumTotalGB = 8; ExpectedDIMMs = 1 }
    $ok = ConvertFrom-ConfigEditorData -General $general -StorageRows @() -NetworkRows @() -GpuRows @() `
        -DeviceRows @(@{ Name = "Boot Shield"; HardwareId = " USB\VID_1234&PID_0001 "; Required = [System.DBNull]::Value }, @{ Name = ""; HardwareId = ""; Required = $true })
    Assert-Equal 0 @($ok.Errors).Count (@($ok.Errors) -join "; ")
    Assert-Equal 1 @($ok.Config.Devices).Count
    Assert-Equal "USB\VID_1234&PID_0001" $ok.Config.Devices[0].HardwareId
    Assert-True ($ok.Config.Devices[0].Required)

    $bad = ConvertFrom-ConfigEditorData -General $general -StorageRows @() -NetworkRows @() -GpuRows @() `
        -DeviceRows @(@{ Name = "Boot Shield"; HardwareId = ""; Required = $true })
    Assert-True (@($bad.Errors) -match 'Device row 1').Count "missing hardware ID is an error"
}

Test-Case "Picking a device suggests a hardware ID without the revision" {
    Assert-Equal "PCI\VEN_8086&DEV_15BB&SUBSYS_00001234" (Select-DeviceHardwareId @("PCI\VEN_8086&DEV_15BB&SUBSYS_00001234&REV_10", "PCI\VEN_8086&DEV_15BB&SUBSYS_00001234", "PCI\VEN_8086&DEV_15BB"))
    Assert-Equal "ACPI\PNP0A08" (Select-DeviceHardwareId @("ACPI\PNP0A08"))
}

Write-Host "Validation"

Test-Case "Adapter enumeration (#2, #3) does not affect matching" {
    $snap = New-TestSnapshot
    $snap.Network.Adapters = @(
        [pscustomobject]@{ Name = "Ethernet 3"; InterfaceDescription = "Intel(R) I210 Gigabit Network Connection #3"; Status = "Up"; MacAddress = "00-00-00-00-00-01"; LinkSpeed = "1 Gbps"; LinkSpeedMbps = 1000; IsWireless = $false },
        [pscustomobject]@{ Name = "Ethernet"; InterfaceDescription = "Intel(R) I210 Gigabit Network Connection"; Status = "Up"; MacAddress = "00-00-00-00-00-02"; LinkSpeed = "1 Gbps"; LinkSpeedMbps = 1000; IsWireless = $false }
    )
    $config = New-ConfigFromSnapshot -Snapshot (New-TestSnapshot) -Name "t"
    $config.Network.Adapters = @(
        [pscustomobject]@{ AdapterContains = "Intel(R) I210 Gigabit Network Connection #2"; Required = $true; MinimumLinkMbps = 1000; RequireUp = $true },
        [pscustomobject]@{ AdapterContains = "Intel(R) I210 Gigabit Network Connection"; Required = $true; MinimumLinkMbps = 1000; RequireUp = $true }
    )
    $nics = @(Get-ResultFor (Test-SystemAgainstConfig -Config $config -Snapshot $snap) "NETWORK" "*")
    Assert-Equal 2 $nics.Count
    Assert-Equal "PASS,PASS" (($nics | ForEach-Object { $_.Status }) -join ",") (($nics | ForEach-Object { $_.Detail }) -join " / ")
    Assert-Equal "Intel(R) I210 Gigabit Network Connection" $nics[0].Check "the #n suffix is not shown"

    $captured = New-ConfigFromSnapshot -Snapshot $snap -Name "t"
    Assert-Equal "Intel(R) I210 Gigabit Network Connection" $captured.Network.Adapters[0].AdapterContains "capture stores the description without #n"
}

Test-Case "Optional network adapters and devices that are not installed get no row" {
    $snap = New-TestSnapshot
    $config = New-ConfigFromSnapshot -Snapshot $snap -Name "t"
    $config.Network.Adapters += [pscustomobject]@{ AdapterContains = "Bluetooth Device"; Required = $false; MinimumLinkMbps = $null; RequireUp = $false }
    $config | Add-Member -NotePropertyName Devices -NotePropertyValue @(
        [pscustomobject]@{ Name = "Smart card reader"; HardwareId = "USB\VID_9999&PID_0001"; Required = $false }
    ) -Force
    $results = Test-SystemAgainstConfig -Config $config -Snapshot $snap
    Assert-Equal 0 @(Get-ResultFor $results "NETWORK" "Bluetooth*").Count
    Assert-Equal 0 @(Get-ResultFor $results "DEVICES" "*").Count
}

Test-Case "Required Devices: only presence counts, not driver state" {
    $snap = New-TestSnapshot
    $config = New-ConfigFromSnapshot -Snapshot $snap -Name "t"
    $config | Add-Member -NotePropertyName Devices -NotePropertyValue @(
        [pscustomobject]@{ Name = "Boot Shield"; HardwareId = "usb\vid_1234&pid_0001"; Required = $true },
        [pscustomobject]@{ Name = "Second Boot Shield"; HardwareId = "USB\VID_1234&PID_0001"; Required = $true },
        [pscustomobject]@{ Name = "TPM"; HardwareId = "ACPI\MSFT0101"; Required = $true }
    ) -Force

    $rows = @(Get-ResultFor (Test-SystemAgainstConfig -Config $config -Snapshot $snap) "DEVICES" "*")
    Assert-Equal "PASS,FAIL,FAIL" (($rows | ForEach-Object { $_.Status }) -join ",") "one physical shield cannot satisfy two entries"
    Assert-True ($rows[2].Detail -like "*not found*") $rows[2].Detail

    # Missing drivers (28), disabled (22) or not started (10): still present.
    foreach ($code in @(28, 22, 10)) {
        $snap.Devices[0].ErrorCode = $code
        $row = @(Get-ResultFor (Test-SystemAgainstConfig -Config $config -Snapshot $snap) "DEVICES" "Boot Shield")[0]
        Assert-Equal "PASS" $row.Status "code $code"
    }

    # Windows keeps entries for unplugged devices (45 = not connected, 24 = not present).
    foreach ($code in @(45, 24)) {
        $snap.Devices[0].ErrorCode = $code
        $row = @(Get-ResultFor (Test-SystemAgainstConfig -Config $config -Snapshot $snap) "DEVICES" "Boot Shield")[0]
        Assert-Equal "FAIL" $row.Status "code $code"
        Assert-True ($row.Detail -like "*not found*") $row.Detail
    }
}

Test-Case "A device removed in the editor and saved is no longer checked" {
    $root = New-TestRoot
    try {
        $general = @{ Name = "d"; Manufacturer = "HP"; Model = "HP Laptop 15-fc0xxx"; CpuModelContains = "AMD"; MinimumCores = 4; MinimumLogicalCPUs = 0; MinimumTotalGB = 8; ExpectedDIMMs = 2 }
        $path = Get-ConfigPath "d"
        $both = ConvertFrom-ConfigEditorData -General $general -StorageRows @() -NetworkRows @() -GpuRows @() -DeviceRows @(
            @{ Name = "Boot Shield"; HardwareId = "USB\VID_1234&PID_0001"; Required = $true },
            @{ Name = "TPM"; HardwareId = "ACPI\MSFT0101"; Required = $true })
        Save-HardwareConfig -Config $both.Config -Path $path
        Assert-Equal "FAIL" (@(Get-ResultFor (Test-SystemAgainstConfig -Config (Read-HardwareConfig $path) -Snapshot (New-TestSnapshot)) "DEVICES" "TPM")[0]).Status

        # Remove the TPM row and save, as the editor does.
        $config = Read-HardwareConfig $path
        $rows = @($config.Devices | Where-Object { $_.Name -ne "TPM" } | ForEach-Object { @{ Name = $_.Name; HardwareId = $_.HardwareId; Required = $_.Required } })
        Save-HardwareConfig -Config (ConvertFrom-ConfigEditorData -General $general -StorageRows @() -NetworkRows @() -GpuRows @() -DeviceRows $rows).Config -Path $path

        Assert-True (Test-ConfigIntegrity -ConfigPath $path).Valid
        $rowsAfter = @(Get-ResultFor (Test-SystemAgainstConfig -Config (Read-HardwareConfig $path) -Snapshot (New-TestSnapshot)) "DEVICES" "*")
        Assert-Equal "Boot Shield" (($rowsAfter | ForEach-Object { $_.Check }) -join ",")
        Assert-Equal "PASS" $rowsAfter[0].Status

        # Removing the last device leaves no device checks at all.
        Save-HardwareConfig -Config (ConvertFrom-ConfigEditorData -General $general -StorageRows @() -NetworkRows @() -GpuRows @() -DeviceRows @()).Config -Path $path
        Assert-Equal 0 @(Get-ResultFor (Test-SystemAgainstConfig -Config (Read-HardwareConfig $path) -Snapshot (New-TestSnapshot)) "DEVICES" "*").Count
    }
    finally { Remove-TestRoot $root }
}

Test-Case "Only adapters the Config lists are reported" {
    $snap = New-TestSnapshot
    $config = New-ConfigFromSnapshot -Snapshot $snap -Name "t"
    $config.Network.Adapters = @($config.Network.Adapters | Where-Object { $_.AdapterContains -like "*Ethernet*" })
    $listed = @(Get-ConfiguredNetworkAdapters -Config $config -Snapshot $snap)
    Assert-Equal 1 $listed.Count
    Assert-Equal "Intel(R) Ethernet I219-LM" $listed[0].InterfaceDescription
}

Test-Case "Captured config passes on the same hardware" {
    $snap = New-TestSnapshot
    $results = @(Test-SystemAgainstConfig -Config (New-ConfigFromSnapshot -Snapshot $snap -Name "t") -Snapshot $snap)
    Assert-Equal 0 @($results | Where-Object { $_.Status -ne "PASS" }).Count (($results | ForEach-Object { "$($_.Status) $($_.Check)" }) -join "; ")
}

Test-Case "Two identical disks need two physical disks" {
    $snap = New-TestSnapshot
    $snap.Storage.PhysicalDisks = @(
        [pscustomobject]@{ FriendlyName = "Samsung 870"; BusType = "SATA"; SizeGB = 931; HealthStatus = "Healthy"; SerialNumber = "1" },
        [pscustomobject]@{ FriendlyName = "Samsung 870"; BusType = "SATA"; SizeGB = 931; HealthStatus = "Healthy"; SerialNumber = "2" }
    )
    $config = New-ConfigFromSnapshot -Snapshot $snap -Name "t"
    $snap.Storage.PhysicalDisks = @($snap.Storage.PhysicalDisks[0])

    $disk = Get-ResultFor (Test-SystemAgainstConfig -Config $config -Snapshot $snap) "STORAGE" "Samsung*"
    Assert-Equal 2 $disk.Count
    Assert-Equal "PASS" $disk[0].Status
    Assert-Equal "FAIL" $disk[1].Status
}

Test-Case "Optional component: absent is INFO, present but out of spec is FAIL" {
    $snap = New-TestSnapshot
    $config = New-ConfigFromSnapshot -Snapshot $snap -Name "t"
    $config.Storage.PhysicalDisks += [pscustomobject]@{ FriendlyNameContains = "Extra SSD"; BusType = "SATA"; MinimumGB = 100; Required = $false }
    $config.Storage.PhysicalDisks[0].Required = $false

    $results = Test-SystemAgainstConfig -Config $config -Snapshot $snap
    $extra = Get-ResultFor $results "STORAGE" "Extra SSD*"
    Assert-Equal "INFO" $extra[0].Status
    Assert-Equal "Extra SSD (optional)" $extra[0].Check

    $config.Storage.PhysicalDisks[0].MinimumGB = 500
    $wd = Get-ResultFor (Test-SystemAgainstConfig -Config $config -Snapshot $snap) "STORAGE" "WD*"
    Assert-Equal "FAIL" $wd[0].Status
}

Test-Case "Required entry claims a device before an optional one" {
    $snap = New-TestSnapshot
    $config = New-ConfigFromSnapshot -Snapshot $snap -Name "t"
    $config.Storage.PhysicalDisks = @(
        [pscustomobject]@{ FriendlyNameContains = "WD"; BusType = "NVMe"; MinimumGB = 1; Required = $false },
        [pscustomobject]@{ FriendlyNameContains = "WD PC"; BusType = "NVMe"; MinimumGB = 1; Required = $true }
    )
    $disks = Get-ResultFor (Test-SystemAgainstConfig -Config $config -Snapshot $snap) "STORAGE" "*"
    Assert-Equal "INFO" $disks[0].Status
    Assert-Equal "PASS" $disks[1].Status
}

Test-Case "Wi-Fi link speed never fails, even with an old minimum in the config" {
    $snap = New-TestSnapshot
    $config = New-ConfigFromSnapshot -Snapshot $snap -Name "t"
    @($config.Network.Adapters | Where-Object { $_.AdapterContains -like "*WiFi*" })[0].MinimumLinkMbps = 72.2
    $snap.Network.Adapters[0].LinkSpeedMbps = 6.5
    $snap.Network.Adapters[0].LinkSpeed = "6.5 Mbps"
    $wifi = Get-ResultFor (Test-SystemAgainstConfig -Config $config -Snapshot $snap) "NETWORK" "*WiFi*"
    Assert-Equal "PASS" $wifi[0].Status
}

Test-Case "Wired link speed below minimum fails" {
    $snap = New-TestSnapshot
    $config = New-ConfigFromSnapshot -Snapshot $snap -Name "t"
    $snap.Network.Adapters[1].LinkSpeedMbps = 100
    $lan = Get-ResultFor (Test-SystemAgainstConfig -Config $config -Snapshot $snap) "NETWORK" "*Ethernet*"
    Assert-Equal "FAIL" $lan[0].Status
}

Test-Case "Logical CPU minimum and disk health are checked" {
    $snap = New-TestSnapshot
    $config = New-ConfigFromSnapshot -Snapshot $snap -Name "t"
    $snap.CPU.LogicalProcessors = 4
    $snap.Storage.PhysicalDisks[0].HealthStatus = "Warning"
    $results = Test-SystemAgainstConfig -Config $config -Snapshot $snap
    Assert-Equal "FAIL" (Get-ResultFor $results "CPU" "Logical CPUs")[0].Status
    Assert-Equal "FAIL" (Get-ResultFor $results "STORAGE" "*")[0].Status
}

Test-Case "Overall result" {
    $ok = [pscustomobject]@{ RenameSucceeded = $true }
    $bad = [pscustomobject]@{ RenameSucceeded = $false }
    $pass = @([pscustomobject]@{ Status = "PASS" }, [pscustomobject]@{ Status = "INFO" }, [pscustomobject]@{ Status = "WARN" })
    Assert-Equal "PASS" (Get-OverallResult -Results $pass -RenameInfo $ok)
    Assert-Equal "FAIL" (Get-OverallResult -Results $pass -RenameInfo $bad)
    Assert-Equal "FAIL" (Get-OverallResult -Results ($pass + [pscustomobject]@{ Status = "FAIL" }) -RenameInfo $ok)
}

Write-Host "Unit History"

# Records one Validation Run for a unit through the real writer.
function Save-TestRun {
    param(
        [string]$Serial,
        $Snapshot,
        [string]$Result = "PASS",
        [bool]$Confirmed = $false,
        [datetime]$Now = (Get-Date),
        [string]$Phase = "Tier"
    )
    $history = Get-UnitHistory -UnitSerial $Serial
    $rename = New-RenameInfo $Serial $Serial $true $false "Computer name already matches serial number."
    return Save-ValidationRun -History $history -TestPhase $Phase -AppMode "Production" `
        -Config (New-ConfigFromSnapshot -Snapshot $Snapshot -Name "c") -Snapshot $Snapshot -RenameInfo $rename `
        -Results @(New-CheckResult "CPU" "Model" $Result "x") -TravelerConfirmed $Confirmed -Now $Now
}

# Writes a report the way versions before Run Numbers did.
function Write-LegacyReport {
    param([string]$Serial, [string]$Stamp, [string]$Fingerprint, [string]$Mac, [string]$Result = "PASS")
    $folder = Join-Path $script:ReportDir $Serial
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    $path = Join-Path $folder "${Serial}_Tier_${Stamp}_Hardware_Validation_Summary.txt"
    @(
        "Serial Number  : $Serial",
        "Configuration  : legacy",
        "Hardware Fingerprint : $Fingerprint",
        "Overall Result : $Result",
        "MAC RECORD     : Intel NIC|$Mac"
    ) | Set-Content -Path $path
    return $path
}

function New-SnapshotOnBoard {
    param($Board, [string[]]$Macs)
    $snap = New-TestSnapshot
    $snap.System.HardwareFingerprint = $Board.Fingerprint
    $snap.System.SystemUUID = $Board.SystemUUID
    $snap.System.BiosSerial = $Board.BiosSerial
    $snap.System.BaseboardSerial = $Board.BaseboardSerial
    if ($Macs) {
        $snap.Network.Adapters = @($Macs | ForEach-Object {
            [pscustomobject]@{ Name = "n"; InterfaceDescription = "Adapter $_"; Status = "Up"; MacAddress = $_; LinkSpeed = "1 Gbps"; LinkSpeedMbps = 1000; IsWireless = $false }
        })
    }
    return $snap
}

$script:BoardA = New-HardwareIdentity -SystemUUID "AAAA-1111" -BiosSerial "BIOSA" -BaseboardSerial "BOARDA"
$script:BoardB = New-HardwareIdentity -SystemUUID "BBBB-2222" -BiosSerial "BIOSB" -BaseboardSerial "BOARDB"

Test-Case "A unit with no reports is NEW and starts at Run 1" {
    $root = New-TestRoot
    try {
        $history = Get-UnitHistory -UnitSerial "SN1"
        Assert-Equal 1 $history.NextRunNumber
        Assert-Equal $null $history.LatestRun
        Assert-True (-not $history.TravelerConfirmed)
        Assert-Equal "NEW" (Get-UnitIdentityState -History $history -CurrentIdentity $script:BoardA).Status
    }
    finally { Remove-TestRoot $root }
}

Test-Case "Runs are numbered per Unit Serial and the number is in the file name and report" {
    $root = New-TestRoot
    try {
        $snap = New-SnapshotOnBoard $script:BoardA
        $first = Save-TestRun -Serial "SN1" -Snapshot $snap
        $second = Save-TestRun -Serial "SN1" -Snapshot $snap -Phase "Pre-Oven"
        Assert-True ((Split-Path -Leaf $first) -like "SN1_Run001_Tier_*_Hardware_Validation_Summary.txt") (Split-Path -Leaf $first)
        Assert-True ((Split-Path -Leaf $second) -like "SN1_Run002_Pre-Oven_*") (Split-Path -Leaf $second)
        Assert-True ((Get-Content $second) -contains "Run Number     : 2")
        $history = Get-UnitHistory -UnitSerial "SN1"
        Assert-Equal 2 $history.LatestRun.RunNumber
        Assert-Equal 3 $history.NextRunNumber
        Assert-Equal 1 @(Get-UnitHistory -UnitSerial "SN2").NextRunNumber
    }
    finally { Remove-TestRoot $root }
}

Test-Case "Latest run is decided by Run Number, not by the unit's clock" {
    $root = New-TestRoot
    try {
        [void](Save-TestRun -Serial "SN1" -Snapshot (New-SnapshotOnBoard $script:BoardA) -Now ([datetime]"2026-10-01"))
        # Board swap reset the clock to 2000: the report's timestamp and the
        # file time both come from that clock.
        $second = Save-TestRun -Serial "SN1" -Snapshot (New-SnapshotOnBoard $script:BoardB) -Now ([datetime]"2000-01-01")
        (Get-Item $second).LastWriteTime = [datetime]"2000-01-01"
        $history = Get-UnitHistory -UnitSerial "SN1"
        Assert-Equal 2 $history.LatestRun.RunNumber
        Assert-Equal $script:BoardB.Fingerprint $history.LatestRun.Fingerprint
    }
    finally { Remove-TestRoot $root }
}

Test-Case "Legacy reports are ordered by file-name timestamp and come before numbered runs" {
    $root = New-TestRoot
    try {
        $newer = Write-LegacyReport "SN1" "20261005_120000" "FPNEW" "00-00-00-00-00-02"
        $older = Write-LegacyReport "SN1" "20261001_120000" "FPOLD" "00-00-00-00-00-01"
        # File times say the opposite (e.g. copied between USB drives).
        (Get-Item $newer).LastWriteTime = [datetime]"2020-01-01"
        $history = Get-UnitHistory -UnitSerial "SN1"
        Assert-Equal "FPNEW" $history.LatestRun.Fingerprint
        Assert-Equal 3 $history.NextRunNumber "two legacy runs, so the next run is 3"

        [void](Save-TestRun -Serial "SN1" -Snapshot (New-SnapshotOnBoard $script:BoardA) -Now ([datetime]"2000-01-01"))
        Assert-Equal $script:BoardA.Fingerprint (Get-UnitHistory -UnitSerial "SN1").LatestRun.Fingerprint
    }
    finally { Remove-TestRoot $root }
}

Test-Case "Motherboard baseline comes from the latest run, even a failed one" {
    $root = New-TestRoot
    try {
        [void](Save-TestRun -Serial "SN1" -Snapshot (New-SnapshotOnBoard $script:BoardA) -Result "PASS")
        [void](Save-TestRun -Serial "SN1" -Snapshot (New-SnapshotOnBoard $script:BoardB) -Result "FAIL")
        $history = Get-UnitHistory -UnitSerial "SN1"
        Assert-Equal "FAIL" $history.LatestRun.OverallResult
        Assert-Equal "MATCH" (Get-UnitIdentityState -History $history -CurrentIdentity $script:BoardB).Status
        Assert-Equal "MISMATCH" (Get-UnitIdentityState -History $history -CurrentIdentity $script:BoardA).Status
    }
    finally { Remove-TestRoot $root }
}

Test-Case "Shared boot drive: each Unit Serial has its own history" {
    $root = New-TestRoot
    try {
        [void](Save-TestRun -Serial "SN100" -Snapshot (New-SnapshotOnBoard $script:BoardA))
        $next = Get-UnitIdentityState -History (Get-UnitHistory -UnitSerial "SN101") -CurrentIdentity $script:BoardB
        Assert-Equal "NEW" $next.Status
        Assert-Equal "SN101" $next.UnitSerial
    }
    finally { Remove-TestRoot $root }
}

Test-Case "Traveler Confirmation sets the MAC baseline; later failed runs do not move it" {
    $root = New-TestRoot
    try {
        $macs = @("40-1A-58-83-6F-A0", "00-11-22-33-44-55")
        [void](Save-TestRun -Serial "SN1" -Snapshot (New-SnapshotOnBoard $script:BoardA $macs) -Result "FAIL" -Confirmed $true)
        # A later failed run on different MACs must not become the baseline.
        [void](Save-TestRun -Serial "SN1" -Snapshot (New-SnapshotOnBoard $script:BoardA @("AA-AA-AA-AA-AA-AA")) -Result "FAIL")

        $history = Get-UnitHistory -UnitSerial "SN1"
        Assert-True $history.TravelerConfirmed
        Assert-Equal 1 $history.ConfirmedRunNumber
        Assert-Equal "PASS" (Compare-MacsToBaseline -History $history -Snapshot (New-SnapshotOnBoard $script:BoardA $macs)).Status

        $wrong = Compare-MacsToBaseline -History $history -Snapshot (New-SnapshotOnBoard $script:BoardA @("40-1A-58-83-6F-A0", "AA-AA-AA-AA-AA-AA"))
        Assert-Equal "FAIL" $wrong.Status
        Assert-True ($wrong.Detail -like "*Missing: 00-11-22-33-44-55*") $wrong.Detail
        Assert-True ($wrong.Detail -like "*Unexpected: AA-AA-AA-AA-AA-AA*") $wrong.Detail
    }
    finally { Remove-TestRoot $root }
}

Test-Case "The latest Traveler Confirmation replaces the MAC baseline" {
    $root = New-TestRoot
    try {
        [void](Save-TestRun -Serial "SN1" -Snapshot (New-SnapshotOnBoard $script:BoardA @("00-00-00-00-00-01")) -Confirmed $true)
        [void](Save-TestRun -Serial "SN1" -Snapshot (New-SnapshotOnBoard $script:BoardA @("00-00-00-00-00-02")) -Confirmed $true)
        $history = Get-UnitHistory -UnitSerial "SN1"
        Assert-Equal 2 $history.ConfirmedRunNumber
        Assert-Equal "PASS" (Compare-MacsToBaseline -History $history -Snapshot (New-SnapshotOnBoard $script:BoardA @("00-00-00-00-00-02"))).Status
        Assert-Equal "FAIL" (Compare-MacsToBaseline -History $history -Snapshot (New-SnapshotOnBoard $script:BoardA @("00-00-00-00-00-01"))).Status
    }
    finally { Remove-TestRoot $root }
}

Test-Case "Report and traveler baseline cover only the Config's adapters" {
    $root = New-TestRoot
    try {
        $snap = New-TestSnapshot
        $config = New-ConfigFromSnapshot -Snapshot $snap -Name "c"
        $config.Network.Adapters = @($config.Network.Adapters | Where-Object { $_.AdapterContains -like "*Ethernet*" })
        $rename = New-RenameInfo "SN1" "SN1" $true $false "x"
        $path = Save-ValidationRun -History (Get-UnitHistory -UnitSerial "SN1") -TestPhase "Tier" -AppMode "Production" `
            -Config $config -Snapshot $snap -RenameInfo $rename -Results @() -TravelerConfirmed $true
        $text = Get-Content $path
        Assert-True ($text -contains "Intel(R) Ethernet I219-LM")
        Assert-True (-not ($text -match 'Realtek')) "the Wi-Fi adapter is not in the Config, so it is not listed"
        Assert-Equal "Traveler MAC   : 00-11-22-33-44-55" (@($text | Where-Object { $_ -like "Traveler MAC   : *" }) -join "|")

        # The unused Wi-Fi adapter's MAC is not part of the baseline.
        $snap.Network.Adapters[0].MacAddress = "AA-AA-AA-AA-AA-AA"
        Assert-Equal "PASS" (Compare-MacsToBaseline -History (Get-UnitHistory -UnitSerial "SN1") -Snapshot $snap -Config $config).Status
    }
    finally { Remove-TestRoot $root }
}

Test-Case "MAC comparison ignores adapter model, case and separators" {
    $root = New-TestRoot
    try {
        [void](Save-TestRun -Serial "SN1" -Snapshot (New-SnapshotOnBoard $script:BoardA @("40-1a-58-83-6f-a0")) -Confirmed $true)
        $snap = New-SnapshotOnBoard $script:BoardA @("40:1A:58:83:6F:A0")
        $snap.Network.Adapters[0].InterfaceDescription = "Replacement NIC, different model"
        Assert-Equal "PASS" (Compare-MacsToBaseline -History (Get-UnitHistory -UnitSerial "SN1") -Snapshot $snap).Status
    }
    finally { Remove-TestRoot $root }
}

Test-Case "Units with only older reports still need a Traveler Confirmation" {
    $root = New-TestRoot
    try {
        [void](Write-LegacyReport "SN1" "20261001_120000" $script:BoardA.Fingerprint "00-00-00-00-00-01")
        [void](Save-TestRun -Serial "SN1" -Snapshot (New-SnapshotOnBoard $script:BoardA))
        Assert-True (-not (Get-UnitHistory -UnitSerial "SN1").TravelerConfirmed)
    }
    finally { Remove-TestRoot $root }
}

Test-Case "Hardware Change: details, approval file, only the CURRENT board is approved" {
    $root = New-TestRoot
    try {
        [void](Save-TestRun -Serial "SN1" -Snapshot (New-SnapshotOnBoard $script:BoardA))
        $history = Get-UnitHistory -UnitSerial "SN1"

        $details = @(Get-HardwareChangeDetails -History $history -CurrentIdentity $script:BoardB)
        Assert-Equal 3 $details.Count ($details -join " / ")
        Assert-True (-not (Test-HardwareChangeApproved -History $history -Fingerprint $script:BoardB.Fingerprint))

        $path = Save-HardwareChangeApproval -History $history -CurrentIdentity $script:BoardB -Reason "Board replaced" -ApprovedByMode "Production"
        Assert-True ($path -like "*SN1_Hardware_Change_Approval_*.txt")

        $history = Get-UnitHistory -UnitSerial "SN1"
        Assert-True (Test-HardwareChangeApproved -History $history -Fingerprint $script:BoardB.Fingerprint)
        Assert-True (-not (Test-HardwareChangeApproved -History $history -Fingerprint $script:BoardA.Fingerprint)) "original board must not be auto-approved"
    }
    finally { Remove-TestRoot $root }
}

Test-Case "Report keeps the fields older tools and people read" {
    $root = New-TestRoot
    try {
        $path = Save-TestRun -Serial "SN1" -Snapshot (New-SnapshotOnBoard $script:BoardA) -Confirmed $true
        $text = Get-Content $path
        Assert-True ($text -contains "Serial Number  : SN1")
        Assert-True ($text -contains "Overall Result : PASS")
        Assert-True ($text -contains "Traveler Confirmation : Confirmed by operator in Production mode")
        Assert-True (@($text | Where-Object { $_ -like "MAC RECORD     : *" }).Count -ge 1)
        Assert-Equal "c" (Get-UnitHistory -UnitSerial "SN1").LatestRun.ConfigName
    }
    finally { Remove-TestRoot $root }
}

Write-Host "Validation Run"

# Fake machine: a unit on a given motherboard with given MAC addresses.
function New-FakeMachine {
    param($Board, [string[]]$Macs, [string]$Name, [string]$Pending = $null, [switch]$RenameFails, [object[]]$ExtraAdapters = @())
    $state = @{ Renamed = $null; Board = $Board; Macs = $Macs; Name = $Name; Pending = $Pending; RenameFails = [bool]$RenameFails; Extra = $ExtraAdapters }
    return @{
        State = $state
        ReadIdentity = { return $state.Board }.GetNewClosure()
        ReadSnapshot = {
            $snap = New-SnapshotOnBoard $state.Board $state.Macs
            $snap.Network.Adapters = @($snap.Network.Adapters) + @($state.Extra)
            return $snap
        }.GetNewClosure()
        ComputerName = { return $state.Name }.GetNewClosure()
        PendingName = { if ($state.Pending) { return $state.Pending } return $state.Name }.GetNewClosure()
        Rename = { param($NewName) if ($state.RenameFails) { throw "Access denied" } $state.Renamed = $NewName }.GetNewClosure()
    }
}

# Fake operator: scripted answers, and a log of what was asked.
function New-FakeOperator {
    param([bool]$Traveler = $true, [string]$Reason = "Board replaced", [bool]$Rename = $true)
    $state = @{ Asked = [System.Collections.Generic.List[string]]::new(); Traveler = $Traveler; Reason = $Reason; Rename = $Rename; TravelerMacs = @() }
    return @{
        State = $state
        ConfirmTraveler = { param($UnitSerial, $Adapters) $state.Asked.Add("Traveler"); $state.TravelerMacs = @($Adapters | ForEach-Object { $_.Mac }); return $state.Traveler }.GetNewClosure()
        ApproveHardwareChange = { param($UnitSerial, $Changes) $state.Asked.Add("HardwareChange"); if ($state.Reason) { return $state.Reason } return $null }.GetNewClosure()
        ConfirmRename = { param($CurrentName, $UnitSerial) $state.Asked.Add("Rename"); return $state.Rename }.GetNewClosure()
    }
}

function New-RunFixture {
    $root = New-TestRoot
    $config = New-ConfigFromSnapshot -Snapshot (New-SnapshotOnBoard $script:BoardA) -Name "cfg"
    $config.Network.Adapters = @([pscustomobject]@{ AdapterContains = "Adapter"; Required = $true; MinimumLinkMbps = $null; RequireUp = $false })
    Save-HardwareConfig -Config $config -Path (Get-ConfigPath "cfg")
    return $root
}

function Invoke-TestRun {
    param([string]$Serial, $Machine, $Operator, [string]$Config = "cfg", [string]$Phase = "Pre-Oven")
    return Invoke-ValidationRun -UnitSerial $Serial -TestPhase $Phase -ConfigBaseName $Config -AppMode "Production" `
        -Operator $Operator -Machine $Machine
}

function Get-ReportFiles {
    return @(Get-ChildItem -Path $script:ReportDir -Recurse -File -ErrorAction SilentlyContinue)
}

function Get-Row {
    param($Outcome, [string]$Section)
    return @($Outcome.Results | Where-Object { $_.Section -eq $Section })[0]
}

$script:Mac1 = @("00-11-22-33-44-55")

Test-Case "First run: traveler answered No stops the run and records nothing" {
    $root = New-RunFixture
    try {
        $machine = New-FakeMachine $script:BoardA $script:Mac1 "OLDNAME"
        $operator = New-FakeOperator -Traveler $false
        $outcome = Invoke-TestRun "SN100" $machine $operator
        Assert-Equal "Stopped" $outcome.Status
        Assert-Equal "Serial" $outcome.Focus
        Assert-True ($null -ne $outcome.Message)
        Assert-Equal "Traveler" ($operator.State.Asked -join ",")
        Assert-Equal 0 (Get-ReportFiles).Count
        Assert-Equal $null $machine.State.Renamed
    }
    finally { Remove-TestRoot $root }
}

Test-Case "First run: traveler shows the detected MACs; pass renames and records the confirmation" {
    $root = New-RunFixture
    try {
        $machine = New-FakeMachine $script:BoardA $script:Mac1 "OLDNAME"
        $operator = New-FakeOperator
        $outcome = Invoke-TestRun "SN100" $machine $operator
        Assert-Equal "Completed" $outcome.Status
        Assert-Equal "PASS" $outcome.OverallResult
        Assert-Equal "Traveler,Rename" ($operator.State.Asked -join ",")
        Assert-Equal "00-11-22-33-44-55" ($operator.State.TravelerMacs -join ",")
        Assert-Equal "SN100" $machine.State.Renamed
        Assert-True $outcome.RenameInfo.RebootRequired
        Assert-True (Get-UnitHistory -UnitSerial "SN100").TravelerConfirmed
    }
    finally { Remove-TestRoot $root }
}

Test-Case "Next phase on the same unit asks nothing and checks MACs against the traveler" {
    $root = New-RunFixture
    try {
        [void](Invoke-TestRun "SN100" (New-FakeMachine $script:BoardA $script:Mac1 "SN100") (New-FakeOperator))
        $operator = New-FakeOperator
        $outcome = Invoke-TestRun "SN100" (New-FakeMachine $script:BoardA $script:Mac1 "SN100") $operator -Phase "Pre-Oven"
        Assert-Equal "PASS" $outcome.OverallResult
        Assert-Equal 0 $operator.State.Asked.Count
        Assert-Equal "PASS" (Get-Row $outcome "IDENTITY").Status
        Assert-Equal "PASS" (Get-Row $outcome "MAC ADDRESSES").Status
        Assert-True ((Get-Row $outcome "MAC ADDRESSES").Detail -like "*run 1*")
    }
    finally { Remove-TestRoot $root }
}

Test-Case "Every Tier run asks the traveler again; Yes replaces the unit's MAC baseline" {
    $root = New-RunFixture
    try {
        [void](Invoke-TestRun "SN100" (New-FakeMachine $script:BoardA @("00-00-00-00-00-01") "SN100") (New-FakeOperator) -Phase "Tier")

        # Wrong MACs were confirmed; the assembler fixes them and Tier is re-run.
        $operator = New-FakeOperator
        $outcome = Invoke-TestRun "SN100" (New-FakeMachine $script:BoardA @("00-00-00-00-00-02") "SN100") $operator -Phase "Tier"
        Assert-Equal "Traveler" ($operator.State.Asked -join ",")
        Assert-Equal "PASS" $outcome.OverallResult

        Assert-Equal "PASS" (Invoke-TestRun "SN100" (New-FakeMachine $script:BoardA @("00-00-00-00-00-02") "SN100") (New-FakeOperator)).OverallResult
        Assert-Equal "FAIL" (Invoke-TestRun "SN100" (New-FakeMachine $script:BoardA @("00-00-00-00-00-01") "SN100") (New-FakeOperator)).OverallResult
    }
    finally { Remove-TestRoot $root }
}

Test-Case "Traveler lists only the Config's adapters; unused adapters never affect the MAC check" {
    $root = New-RunFixture
    try {
        $bluetooth = [pscustomobject]@{ Name = "Bluetooth Network Connection"; InterfaceDescription = "Bluetooth Device (Personal Area Network)"; Status = "Disconnected"; MacAddress = "BB-BB-BB-BB-BB-01"; LinkSpeed = "3 Mbps"; LinkSpeedMbps = 3; IsWireless = $true }
        $operator = New-FakeOperator
        $outcome = Invoke-TestRun "SN100" (New-FakeMachine $script:BoardA $script:Mac1 "SN100" -ExtraAdapters @($bluetooth)) $operator -Phase "Tier"
        Assert-Equal "00-11-22-33-44-55" ($operator.State.TravelerMacs -join ",")
        Assert-Equal "Adapter 00-11-22-33-44-55" ((@($outcome.Adapters) | ForEach-Object { $_.InterfaceDescription }) -join ",")

        # Different (or no) Bluetooth adapter at the next phase: still PASS.
        $other = [pscustomobject]@{ Name = "Bluetooth Network Connection"; InterfaceDescription = "Bluetooth Device (Personal Area Network)"; Status = "Disconnected"; MacAddress = "BB-BB-BB-BB-BB-99"; LinkSpeed = "3 Mbps"; LinkSpeedMbps = 3; IsWireless = $true }
        Assert-Equal "PASS" (Invoke-TestRun "SN100" (New-FakeMachine $script:BoardA $script:Mac1 "SN100" -ExtraAdapters @($other)) (New-FakeOperator)).OverallResult
        Assert-Equal "PASS" (Invoke-TestRun "SN100" (New-FakeMachine $script:BoardA $script:Mac1 "SN100") (New-FakeOperator)).OverallResult
    }
    finally { Remove-TestRoot $root }
}

Test-Case "Units confirmed before V23 (every MAC in the baseline) still pass" {
    $root = New-TestRoot
    try {
        $snap = New-TestSnapshot
        $config = New-ConfigFromSnapshot -Snapshot $snap -Name "c"
        $rename = New-RenameInfo "SN1" "SN1" $true $false "x"
        # V21/V22 recorded the Wi-Fi MAC too.
        [void](Save-ValidationRun -History (Get-UnitHistory -UnitSerial "SN1") -TestPhase "Tier" -AppMode "Production" `
            -Config $config -Snapshot $snap -RenameInfo $rename -Results @() -TravelerConfirmed $true)

        $config.Network.Adapters = @($config.Network.Adapters | Where-Object { $_.AdapterContains -like "*Ethernet*" })
        $history = Get-UnitHistory -UnitSerial "SN1"
        Assert-Equal "PASS" (Compare-MacsToBaseline -History $history -Snapshot $snap -Config $config).Status

        $snap.Network.Adapters[1].MacAddress = "CC-CC-CC-CC-CC-CC"
        $changed = Compare-MacsToBaseline -History $history -Snapshot $snap -Config $config
        Assert-Equal "FAIL" $changed.Status
        Assert-True ($changed.Detail -like "*Missing: 00-11-22-33-44-55*Unexpected: CC-CC-CC-CC-CC-CC*") $changed.Detail
    }
    finally { Remove-TestRoot $root }
}

Test-Case "Tier re-confirmation answered No stops and keeps the old baseline" {
    $root = New-RunFixture
    try {
        [void](Invoke-TestRun "SN100" (New-FakeMachine $script:BoardA @("00-00-00-00-00-01") "SN100") (New-FakeOperator) -Phase "Tier")
        $outcome = Invoke-TestRun "SN100" (New-FakeMachine $script:BoardA @("00-00-00-00-00-02") "SN100") (New-FakeOperator -Traveler $false) -Phase "Tier"
        Assert-Equal "Stopped" $outcome.Status
        Assert-Equal 1 (Get-ReportFiles).Count
        Assert-Equal 1 (Get-UnitHistory -UnitSerial "SN100").ConfirmedRunNumber
    }
    finally { Remove-TestRoot $root }
}

Test-Case "Shared boot drive: the next unit is NEW, asked traveler and rename only" {
    $root = New-RunFixture
    try {
        [void](Invoke-TestRun "SN100" (New-FakeMachine $script:BoardA $script:Mac1 "SN100") (New-FakeOperator))
        $machine = New-FakeMachine $script:BoardB @("00-11-22-33-44-66") "SN100"
        $operator = New-FakeOperator
        $outcome = Invoke-TestRun "SN101" $machine $operator
        Assert-Equal "PASS" $outcome.OverallResult
        Assert-Equal "Traveler,Rename" ($operator.State.Asked -join ",")
        Assert-Equal "INFO" (Get-Row $outcome "IDENTITY").Status
        Assert-Equal "SN101" $machine.State.Renamed
        Assert-Equal 0 @(Get-ChildItem (Join-Path $script:ReportDir "SN100") -Filter "*Approval*").Count
    }
    finally { Remove-TestRoot $root }
}

Test-Case "Board swap approved, then rename declined: nothing written" {
    $root = New-RunFixture
    try {
        [void](Invoke-TestRun "SN100" (New-FakeMachine $script:BoardA $script:Mac1 "SN100") (New-FakeOperator))
        $before = (Get-ReportFiles).Count
        $operator = New-FakeOperator -Rename $false
        $outcome = Invoke-TestRun "SN100" (New-FakeMachine $script:BoardB $script:Mac1 "OTHER") $operator
        Assert-Equal "Stopped" $outcome.Status
        Assert-Equal "HardwareChange,Rename" ($operator.State.Asked -join ",")
        Assert-Equal $before (Get-ReportFiles).Count
    }
    finally { Remove-TestRoot $root }
}

Test-Case "Board swap declined stops at the serial box" {
    $root = New-RunFixture
    try {
        [void](Invoke-TestRun "SN100" (New-FakeMachine $script:BoardA $script:Mac1 "SN100") (New-FakeOperator))
        $outcome = Invoke-TestRun "SN100" (New-FakeMachine $script:BoardB $script:Mac1 "SN100") (New-FakeOperator -Reason "")
        Assert-Equal "Stopped" $outcome.Status
        Assert-Equal "Serial" $outcome.Focus
        Assert-Equal 1 (Get-ReportFiles).Count
    }
    finally { Remove-TestRoot $root }
}

Test-Case "Board swap approved: approval recorded, MACs still checked, next run just MATCHes" {
    $root = New-RunFixture
    try {
        [void](Invoke-TestRun "SN100" (New-FakeMachine $script:BoardA $script:Mac1 "SN100") (New-FakeOperator))
        $outcome = Invoke-TestRun "SN100" (New-FakeMachine $script:BoardB @("AA-AA-AA-AA-AA-AA") "SN100") (New-FakeOperator)
        Assert-Equal "PASS" (Get-Row $outcome "IDENTITY").Status
        Assert-True ((Get-Row $outcome "IDENTITY").Detail -like "*approved*")
        Assert-Equal "FAIL" (Get-Row $outcome "MAC ADDRESSES").Status
        Assert-Equal 1 @(Get-ChildItem (Join-Path $script:ReportDir "SN100") -Filter "*Approval*").Count

        $operator = New-FakeOperator
        $next = Invoke-TestRun "SN100" (New-FakeMachine $script:BoardB $script:Mac1 "SN100") $operator
        Assert-Equal 0 $operator.State.Asked.Count
        Assert-True ((Get-Row $next "IDENTITY").Detail -like "*matches*")
        Assert-Equal "PASS" $next.OverallResult "the failed run did not move the MAC baseline"
    }
    finally { Remove-TestRoot $root }
}

Test-Case "A failing unit is not renamed" {
    $root = New-RunFixture
    try {
        $machine = New-FakeMachine $script:BoardA $script:Mac1 "OLDNAME"
        $config = Read-HardwareConfig (Get-ConfigPath "cfg")
        $config.Memory.ExpectedDIMMs = 4
        Save-HardwareConfig -Config $config -Path (Get-ConfigPath "cfg")

        $outcome = Invoke-TestRun "SN100" $machine (New-FakeOperator)
        Assert-Equal "FAIL" $outcome.OverallResult
        Assert-Equal $null $machine.State.Renamed
        Assert-True ($outcome.RenameInfo.Detail -like "*skipped*")
        Assert-True (-not $outcome.RenameInfo.RebootRequired)
    }
    finally { Remove-TestRoot $root }
}

Test-Case "Rename failure fails the run and is reported" {
    $root = New-RunFixture
    try {
        $outcome = Invoke-TestRun "SN100" (New-FakeMachine $script:BoardA $script:Mac1 "OLDNAME" -RenameFails) (New-FakeOperator)
        Assert-Equal "FAIL" $outcome.OverallResult
        Assert-True (-not $outcome.RenameInfo.RenameSucceeded)
        Assert-True ($outcome.RenameInfo.Detail -like "*Access denied*")
    }
    finally { Remove-TestRoot $root }
}

Test-Case "Rename already pending to this serial: no prompt, restart still required" {
    $root = New-RunFixture
    try {
        $machine = New-FakeMachine $script:BoardA $script:Mac1 "OLDNAME" -Pending "SN100"
        $operator = New-FakeOperator
        $outcome = Invoke-TestRun "SN100" $machine $operator
        Assert-Equal "Traveler" ($operator.State.Asked -join ",")
        Assert-Equal $null $machine.State.Renamed
        Assert-True $outcome.RenameInfo.RebootRequired
    }
    finally { Remove-TestRoot $root }
}

Test-Case "Automatic refusals come before any question and write nothing" {
    $root = New-RunFixture
    try {
        $cases = @(
            @{ Serial = "12345"; Phase = "Tier"; Config = "cfg"; Machine = (New-FakeMachine $script:BoardA $script:Mac1 "OLDNAME"); Focus = "Serial" },
            @{ Serial = "SN100"; Phase = ""; Config = "cfg"; Machine = (New-FakeMachine $script:BoardA $script:Mac1 "OLDNAME"); Focus = "Phase" },
            @{ Serial = "SN100"; Phase = "Tier"; Config = ""; Machine = (New-FakeMachine $script:BoardA $script:Mac1 "OLDNAME"); Focus = "Config" },
            @{ Serial = "SN100"; Phase = "Tier"; Config = "cfg"; Machine = (New-FakeMachine $script:BoardA $script:Mac1 "SN100" -Pending "OTHER"); Focus = "Serial" }
        )
        foreach ($c in $cases) {
            $operator = New-FakeOperator
            $outcome = Invoke-TestRun $c.Serial $c.Machine $operator -Config $c.Config -Phase $c.Phase
            Assert-Equal "Stopped" $outcome.Status "case $($c.Focus)"
            Assert-Equal $c.Focus $outcome.Focus
            Assert-Equal 0 $operator.State.Asked.Count
        }

        # A Config changed outside the validator.
        Set-FileReadOnlyState -Path (Get-ConfigPath "cfg") -ReadOnly $false
        Add-Content -Path (Get-ConfigPath "cfg") -Value " "
        $operator = New-FakeOperator
        $outcome = Invoke-TestRun "SN100" (New-FakeMachine $script:BoardA $script:Mac1 "OLDNAME") $operator
        Assert-Equal "Stopped" $outcome.Status
        Assert-Equal 0 $operator.State.Asked.Count
        Assert-Equal 0 (Get-ReportFiles).Count
    }
    finally { Remove-TestRoot $root }
}

Write-Host "Syntax"

Test-Case "Every .ps1 file parses" {
    $problems = [System.Collections.Generic.List[string]]::new()
    foreach ($file in Get-ChildItem -Path $repoRoot -Filter "*.ps1" -Recurse -File) {
        $tokens = $null
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
        foreach ($e in @($parseErrors)) {
            $problems.Add("$($file.Name):$($e.Extent.StartLineNumber) $($e.Message)")
        }
    }
    Assert-Equal 0 $problems.Count ($problems -join "; ")
}

Write-Host ""
Write-Host "$($script:Passed) passed, $($script:Failed.Count) failed"
exit $script:Failed.Count
