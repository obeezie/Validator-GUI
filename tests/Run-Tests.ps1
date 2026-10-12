# Self-contained tests for the validator's non-UI logic.
# No modules to install: run with the PowerShell already on the machine.
#
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
#
# Exit code is the number of failed tests.

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

foreach ($name in @("Common","Integrity","Identity","Hardware","ConfigModel","Validation","Reports")) {
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
    }
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

Test-Case "Rename only needed when serial differs from computer name" {
    Assert-Equal "None" (Get-RenameAction -SerialNumber "dev2" -CurrentName "DEV2" -PendingName "DEV2")
    Assert-Equal "Pending" (Get-RenameAction -SerialNumber "DEV3" -CurrentName "DEV2" -PendingName "dev3")
    Assert-Equal "Rename" (Get-RenameAction -SerialNumber "DEV3" -CurrentName "DEV2" -PendingName "DEV2")
    Assert-Equal "Rename" (Get-RenameAction -SerialNumber "DEV3" -CurrentName "DEV2" -PendingName $null)
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

Test-Case "Approval only trusts the CURRENT HARDWARE fingerprint" {
    $root = New-TestRoot
    try {
        $state = [pscustomobject]@{
            Status = "MISMATCH"; SystemName = "UNIT1"; SummaryPath = ""
            CurrentIdentity = [pscustomobject]@{ Fingerprint = "NEWFP"; SystemUUID = "N"; BiosSerial = "N"; BaseboardSerial = "N" }
        }
        $path = Save-HardwareChangeApproval -SystemName "UNIT1" -Reason "NIC swap" -ApprovedByMode "Engineer" -IdentityState $state
        # Put a "previous" fingerprint in the file the way a real approval has one.
        (Get-Content $path) -replace '^(Fingerprint\s*:\s*)$', '${1}OLDFP' | Set-Content $path

        Assert-Equal "NEWFP" ((Get-ApprovedFingerprintsFromApproval -Path $path) -join ",")
        Assert-True (Test-HardwareChangeApprovalForCurrentIdentity -IdentityState $state)

        $state.CurrentIdentity.Fingerprint = "OLDFP"
        Assert-True (-not (Test-HardwareChangeApprovalForCurrentIdentity -IdentityState $state)) "original hardware must not be auto-approved"
    }
    finally { Remove-TestRoot $root }
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

Write-Host "Validation"

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

Write-Host "Reports"

Test-Case "Summary round trip: fingerprint, config name, MAC history" {
    $root = New-TestRoot
    try {
        $snap = New-TestSnapshot
        $config = New-ConfigFromSnapshot -Snapshot $snap -Name "My Config"
        $rename = New-RenameInfo "UNIT1" "UNIT1" $true $false "Computer name already matches serial number."
        $path = Save-Summary -SerialNumber "UNIT1" -TestPhase "Pre-Oven" -AppMode "Production" `
            -Config $config -Snapshot $snap -RenameInfo $rename -Results @(New-CheckResult "CPU" "Model" "PASS" "x")

        Assert-True ($path -like "*UNIT1_Pre-Oven_*_Hardware_Validation_Summary.txt")
        Assert-Equal "ABC" (Get-HardwareFingerprintFromSummary -Path $path)
        Assert-Equal "My Config" (Get-ConfigurationNameFromSummary -Path $path)
        Assert-True (-not ((Get-Content $path) -match 'BurnInTest|bitcfg'))
        Assert-Equal "PASS" (Compare-MacsToLatestSummary -SerialNumber "UNIT1" -Snapshot $snap).Status

        $snap.Network.Adapters[1].MacAddress = "AA-AA-AA-AA-AA-AA"
        Assert-Equal "FAIL" (Compare-MacsToLatestSummary -SerialNumber "UNIT1" -Snapshot $snap).Status
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
