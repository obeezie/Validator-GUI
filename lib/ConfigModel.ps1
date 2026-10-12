# Hardware configuration files: listing, loading, normalizing, validating,
# saving, and building a new config from a captured snapshot.
#
# Config schema (Configs\<Name>.json):
#   Name
#   System  { Manufacturer, Model }
#   CPU     { ModelContains, MinimumCores, MinimumLogicalCPUs }
#   Memory  { MinimumTotalGB, ExpectedDIMMs }
#   Storage { PhysicalDisks: [ { FriendlyNameContains, BusType, MinimumGB, Required } ] }
#   Network { Adapters:      [ { AdapterContains, Required, MinimumLinkMbps, RequireUp } ] }
#   GPU     { Adapters:      [ { ModelContains, Required } ] }
#
# Required defaults to true when missing. MinimumLinkMbps may be null (no
# minimum). MinimumLogicalCPUs of 0 means "not checked".

function Get-ConfigBaseNames {
    return @(
        Get-ChildItem -Path $script:ConfigDir -Filter "*.json" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ine $script:ConfigManifestName } |
        Sort-Object Name |
        ForEach-Object { [string]$_.BaseName }
    )
}

function Get-ConfigPath {
    param([string]$ConfigBaseName)
    return (Join-Path $script:ConfigDir ($ConfigBaseName + ".json"))
}

# Turns a typed name into a file-safe base name.
# Returns @{ Name = <safe name>; Error = <message or $null> }.
function ConvertTo-SafeConfigName {
    param([string]$Name)

    $safe = ([string]$Name).Trim() -replace '[\\/:*?"<>|]','_'
    $safe = $safe.TrimEnd('.', ' ')

    if ([string]::IsNullOrWhiteSpace($safe)) {
        return @{ Name = ""; Error = "Configuration name cannot be empty." }
    }

    if (($safe + ".json") -ieq $script:ConfigManifestName) {
        return @{ Name = $safe; Error = "'$safe' is reserved by the validator. Choose a different name." }
    }

    return @{ Name = $safe; Error = $null }
}

function Get-RequiredFlag {
    param($Item)

    if ($null -eq $Item -or $null -eq $Item.PSObject.Properties["Required"] -or $null -eq $Item.Required) {
        return $true
    }

    return [bool]$Item.Required
}

function Get-OptionalDouble {
    param($Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $null
    }

    return [double]$Value
}

# Produces a config object with every field present and typed, so the rest of
# the code (and the editor) never has to guess about older or hand-edited files.
function ConvertTo-NormalizedConfig {
    param($Raw)

    return [pscustomobject][ordered]@{
        Name = [string]$Raw.Name
        System = [pscustomobject][ordered]@{
            Manufacturer = [string]$Raw.System.Manufacturer
            Model = [string]$Raw.System.Model
        }
        CPU = [pscustomobject][ordered]@{
            ModelContains = [string]$Raw.CPU.ModelContains
            MinimumCores = [int]$Raw.CPU.MinimumCores
            MinimumLogicalCPUs = [int]$Raw.CPU.MinimumLogicalCPUs
        }
        Memory = [pscustomobject][ordered]@{
            MinimumTotalGB = [double]$Raw.Memory.MinimumTotalGB
            ExpectedDIMMs = [int]$Raw.Memory.ExpectedDIMMs
        }
        Storage = [pscustomobject][ordered]@{
            PhysicalDisks = @(@($Raw.Storage.PhysicalDisks) | Where-Object { $null -ne $_ } | ForEach-Object {
                [pscustomobject][ordered]@{
                    FriendlyNameContains = [string]$_.FriendlyNameContains
                    BusType = [string]$_.BusType
                    MinimumGB = [double]$_.MinimumGB
                    Required = [bool](Get-RequiredFlag $_)
                }
            })
        }
        Network = [pscustomobject][ordered]@{
            Adapters = @(@($Raw.Network.Adapters) | Where-Object { $null -ne $_ } | ForEach-Object {
                [pscustomobject][ordered]@{
                    AdapterContains = [string]$_.AdapterContains
                    Required = [bool](Get-RequiredFlag $_)
                    MinimumLinkMbps = Get-OptionalDouble $_.MinimumLinkMbps
                    RequireUp = [bool]$_.RequireUp
                }
            })
        }
        GPU = [pscustomobject][ordered]@{
            Adapters = @(@($Raw.GPU.Adapters) | Where-Object { $null -ne $_ } | ForEach-Object {
                [pscustomobject][ordered]@{
                    ModelContains = [string]$_.ModelContains
                    Required = [bool](Get-RequiredFlag $_)
                }
            })
        }
    }
}

function Read-HardwareConfig {
    param([string]$Path)

    $raw = Get-Content -Path $Path -Raw | ConvertFrom-Json
    return ConvertTo-NormalizedConfig $raw
}

# Returns a list of problems; empty when the config is usable.
function Test-ConfigDefinition {
    param($Config)

    $errors = [System.Collections.Generic.List[string]]::new()

    if ([string]::IsNullOrWhiteSpace($Config.System.Manufacturer)) { $errors.Add("System manufacturer is required.") }
    if ([string]::IsNullOrWhiteSpace($Config.System.Model)) { $errors.Add("System model is required.") }
    if ([string]::IsNullOrWhiteSpace($Config.CPU.ModelContains)) { $errors.Add("CPU model text is required.") }
    if ([int]$Config.CPU.MinimumCores -lt 1) { $errors.Add("CPU minimum cores must be at least 1.") }
    if ([int]$Config.CPU.MinimumLogicalCPUs -lt 0) { $errors.Add("CPU minimum logical CPUs cannot be negative.") }
    if ([double]$Config.Memory.MinimumTotalGB -le 0) { $errors.Add("Memory minimum total GB must be greater than 0.") }
    if ([int]$Config.Memory.ExpectedDIMMs -lt 0) { $errors.Add("Expected DIMM count cannot be negative.") }

    $i = 0
    foreach ($d in @($Config.Storage.PhysicalDisks)) {
        $i++
        if ([string]::IsNullOrWhiteSpace($d.FriendlyNameContains)) { $errors.Add("Storage row ${i}: disk name text is required.") }
        if ([string]::IsNullOrWhiteSpace($d.BusType)) { $errors.Add("Storage row ${i}: bus type is required.") }
        if ([double]$d.MinimumGB -lt 0) { $errors.Add("Storage row ${i}: minimum GB cannot be negative.") }
    }

    $i = 0
    foreach ($a in @($Config.Network.Adapters)) {
        $i++
        if ([string]::IsNullOrWhiteSpace($a.AdapterContains)) { $errors.Add("Network row ${i}: adapter text is required.") }
        if ($null -ne $a.MinimumLinkMbps -and [double]$a.MinimumLinkMbps -le 0) { $errors.Add("Network row ${i}: minimum link Mbps must be greater than 0, or blank for no minimum.") }
    }

    $i = 0
    foreach ($g in @($Config.GPU.Adapters)) {
        $i++
        if ([string]::IsNullOrWhiteSpace($g.ModelContains)) { $errors.Add("GPU row ${i}: GPU model text is required.") }
    }

    return @($errors)
}

function Save-HardwareConfig {
    param(
        $Config,
        [string]$Path
    )

    Set-FileReadOnlyState -Path $Path -ReadOnly $false
    $Config | ConvertTo-Json -Depth 10 | Set-Content -Path $Path -Encoding UTF8
    Register-ConfigIntegrity -ConfigPath $Path
}

function Find-ConfigBaseNameByConfigName {
    param([string]$ConfigName)

    if ([string]::IsNullOrWhiteSpace($ConfigName)) {
        return $null
    }

    $baseNames = @(Get-ConfigBaseNames)

    # First allow direct filename match.
    foreach ($baseName in $baseNames) {
        if ($baseName -ieq $ConfigName) {
            return $baseName
        }
    }

    # Then compare the Name stored inside the JSON config.
    foreach ($baseName in $baseNames) {
        try {
            $configObject = Get-Content -Path (Get-ConfigPath $baseName) -Raw | ConvertFrom-Json

            if ([string]$configObject.Name -ieq $ConfigName) {
                return $baseName
            }
        }
        catch {
            # Ignore an unreadable config here; validation will report it if selected manually.
        }
    }

    return $null
}

# ---------------------------------------------------------------------------
# Capture
# ---------------------------------------------------------------------------

function New-ConfigFromSnapshot {
    param($Snapshot,[string]$Name)

    return [pscustomobject][ordered]@{
        Name = $Name
        System = [pscustomobject][ordered]@{
            Manufacturer = [string]$Snapshot.System.Manufacturer
            Model = [string]$Snapshot.System.Model
        }
        CPU = [pscustomobject][ordered]@{
            ModelContains = [string]$Snapshot.CPU.Model
            MinimumCores = [int]$Snapshot.CPU.CoreCount
            MinimumLogicalCPUs = [int]$Snapshot.CPU.LogicalProcessors
        }
        Memory = [pscustomobject][ordered]@{
            MinimumTotalGB = [double]([math]::Floor(([double]$Snapshot.Memory.TotalGB * 0.95) * 100) / 100)
            ExpectedDIMMs = [int]$Snapshot.Memory.DimmCount
        }
        Storage = [pscustomobject][ordered]@{
            PhysicalDisks = @(@($Snapshot.Storage.PhysicalDisks) | ForEach-Object {
                [pscustomobject][ordered]@{
                    FriendlyNameContains = [string]$_.FriendlyName
                    BusType = [string]$_.BusType
                    MinimumGB = [double][math]::Floor(([double]$_.SizeGB * 0.95))
                    Required = $true
                }
            })
        }
        Network = [pscustomobject][ordered]@{
            Adapters = @(@($Snapshot.Network.Adapters) | ForEach-Object {
                # Wi-Fi link rates change constantly, so they are never captured
                # as a pass/fail minimum.
                $minimum = $null
                if (-not [bool]$_.IsWireless -and $null -ne $_.LinkSpeedMbps) {
                    $minimum = [double]$_.LinkSpeedMbps
                }

                [pscustomobject][ordered]@{
                    AdapterContains = [string]$_.InterfaceDescription
                    Required = $true
                    MinimumLinkMbps = $minimum
                    RequireUp = ([string]$_.Status -eq "Up")
                }
            })
        }
        GPU = [pscustomobject][ordered]@{
            Adapters = @(@($Snapshot.GPU.Adapters) | ForEach-Object {
                [pscustomobject][ordered]@{
                    ModelContains = [string]$_.Name
                    Required = $true
                }
            })
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
        $kind = if ([bool]$a.IsWireless) { " (wireless - link speed not enforced)" } else { "" }
        $lines.Add("  $([string]$a.InterfaceDescription)$kind")
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
    $lines.Add("All components are saved as Required. Use Edit Config afterwards to")
    $lines.Add("mark components optional or adjust limits.")
    $lines.Add("")
    $lines.Add("Confirm that the above hardware is the intended known-good configuration.")

    return [string]::Join([Environment]::NewLine, $lines)
}

# ---------------------------------------------------------------------------
# Config editor data conversion
# ---------------------------------------------------------------------------

function Test-BlankEditorRow {
    param([hashtable]$Row, [string[]]$TextKeys)

    foreach ($k in $TextKeys) {
        if (-not [string]::IsNullOrWhiteSpace([string]$Row[$k])) {
            return $false
        }
    }
    return $true
}

# Explains, next to a network row in the editor, that a minimum link speed
# will be ignored because the adapter looks wireless. Validation decides
# wireless from the real adapter; the editor can only guess from the text.
function Get-NetworkAdapterEditorNote {
    param(
        [string]$AdapterContains,
        [string]$MinimumLinkMbps
    )

    if (-not (Test-WirelessAdapter -Description $AdapterContains)) {
        return ""
    }

    if ([string]::IsNullOrWhiteSpace($MinimumLinkMbps)) {
        return "Wireless: link speed not checked"
    }
    return "Wireless: minimum ignored, not checked"
}

# Checkbox cells for brand-new grid rows can be null/DBNull: treat as default.
function ConvertTo-EditorBool {
    param($Value, [bool]$Default)

    if ($null -eq $Value -or $Value -is [System.DBNull]) {
        return $Default
    }
    return [bool]$Value
}

# Builds a config object from the editor's raw values.
#   General:      hashtable with Name, Manufacturer, Model, CpuModelContains,
#                 MinimumCores, MinimumLogicalCPUs, MinimumTotalGB, ExpectedDIMMs
#   StorageRows:  hashtables with FriendlyNameContains, BusType, MinimumGB (text), Required
#   NetworkRows:  hashtables with AdapterContains, Required, RequireUp, MinimumLinkMbps (text)
#   GpuRows:      hashtables with ModelContains, Required
# Returns @{ Config = <config or $null>; Errors = <string[]> }.
function ConvertFrom-ConfigEditorData {
    param(
        [hashtable]$General,
        [object[]]$StorageRows,
        [object[]]$NetworkRows,
        [object[]]$GpuRows
    )

    $errors = [System.Collections.Generic.List[string]]::new()

    $disks = [System.Collections.Generic.List[object]]::new()
    $i = 0
    foreach ($row in @($StorageRows)) {
        if ($null -eq $row -or (Test-BlankEditorRow $row @("FriendlyNameContains","BusType","MinimumGB"))) { continue }
        $i++
        $minGB = ConvertTo-InvariantDouble ([string]$row.MinimumGB)
        if ($null -eq $minGB) {
            $errors.Add("Storage row ${i}: minimum GB '$([string]$row.MinimumGB)' is not a number.")
            $minGB = 0
        }
        $disks.Add([pscustomobject][ordered]@{
            FriendlyNameContains = ([string]$row.FriendlyNameContains).Trim()
            BusType = ([string]$row.BusType).Trim()
            MinimumGB = [double]$minGB
            Required = ConvertTo-EditorBool $row.Required $true
        })
    }

    $nics = [System.Collections.Generic.List[object]]::new()
    $i = 0
    foreach ($row in @($NetworkRows)) {
        if ($null -eq $row -or (Test-BlankEditorRow $row @("AdapterContains","MinimumLinkMbps"))) { continue }
        $i++
        $minText = ([string]$row.MinimumLinkMbps).Trim()
        $minMbps = $null
        if ($minText -ne "") {
            $minMbps = ConvertTo-InvariantDouble $minText
            if ($null -eq $minMbps) {
                $errors.Add("Network row ${i}: minimum link Mbps '$minText' is not a number. Leave it blank for no minimum.")
            }
        }
        $nics.Add([pscustomobject][ordered]@{
            AdapterContains = ([string]$row.AdapterContains).Trim()
            Required = ConvertTo-EditorBool $row.Required $true
            MinimumLinkMbps = $minMbps
            RequireUp = ConvertTo-EditorBool $row.RequireUp $false
        })
    }

    $gpus = [System.Collections.Generic.List[object]]::new()
    foreach ($row in @($GpuRows)) {
        if ($null -eq $row -or (Test-BlankEditorRow $row @("ModelContains"))) { continue }
        $gpus.Add([pscustomobject][ordered]@{
            ModelContains = ([string]$row.ModelContains).Trim()
            Required = ConvertTo-EditorBool $row.Required $true
        })
    }

    $config = [pscustomobject][ordered]@{
        Name = [string]$General.Name
        System = [pscustomobject][ordered]@{
            Manufacturer = ([string]$General.Manufacturer).Trim()
            Model = ([string]$General.Model).Trim()
        }
        CPU = [pscustomobject][ordered]@{
            ModelContains = ([string]$General.CpuModelContains).Trim()
            MinimumCores = [int]$General.MinimumCores
            MinimumLogicalCPUs = [int]$General.MinimumLogicalCPUs
        }
        Memory = [pscustomobject][ordered]@{
            MinimumTotalGB = [double]$General.MinimumTotalGB
            ExpectedDIMMs = [int]$General.ExpectedDIMMs
        }
        Storage = [pscustomobject][ordered]@{ PhysicalDisks = @($disks) }
        Network = [pscustomobject][ordered]@{ Adapters = @($nics) }
        GPU = [pscustomobject][ordered]@{ Adapters = @($gpus) }
    }

    foreach ($e in @(Test-ConfigDefinition $config)) {
        $errors.Add($e)
    }

    if ($errors.Count -gt 0) {
        return @{ Config = $null; Errors = @($errors) }
    }

    return @{ Config = $config; Errors = @() }
}
