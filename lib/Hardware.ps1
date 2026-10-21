# Reads the current machine's hardware into a snapshot object, and renames
# the computer to the unit serial number.

# Wi-Fi and Bluetooth adapters. NdisPhysicalMedium 9 = Native 802.11 (Wi-Fi),
# 10 = Bluetooth. Their link speed is never a pass/fail check, and Capture
# saves them as optional (ignored).
function Test-WirelessAdapter {
    param(
        [string]$PhysicalMediaType,
        $NdisPhysicalMedium,
        [string]$Description
    )

    if ($null -ne $NdisPhysicalMedium -and @("9", "10") -contains [string]$NdisPhysicalMedium) {
        return $true
    }

    if ($PhysicalMediaType -match '802\.11') {
        return $true
    }

    return ($Description -match 'Wi-?Fi|Wireless|WLAN|802\.11|Bluetooth')
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
        Sort-Object FriendlyName, SerialNumber |
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
                IsWireless = [bool](Test-WirelessAdapter `
                    -PhysicalMediaType ([string]$_.PhysicalMediaType) `
                    -NdisPhysicalMedium $_.NdisPhysicalMedium `
                    -Description ([string]$_.InterfaceDescription))
            }
        }
    )

    $devices = @(Get-DeviceList)

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
        Firmware = [pscustomobject]@{
            BiosVersion = ([string]$bios.SMBIOSBIOSVersion).Trim()
            BiosDate = Format-BiosDate $bios.ReleaseDate
            EcVersion = Format-EcVersion $bios.EmbeddedControllerMajorVersion $bios.EmbeddedControllerMinorVersion
        }
        Storage = [pscustomobject]@{ PhysicalDisks = @($disks) }
        Network = [pscustomobject]@{ Adapters = @($net) }
        GPU = [pscustomobject]@{ Adapters = @($gpus) }
        Devices = @($devices)
    }
}

# BIOS build date as MM/dd/yyyy. The firmware stores midnight UTC and CIM
# converts it to local time, which would show the previous day on US clocks,
# so convert back to UTC before formatting.
function Format-BiosDate {
    param($ReleaseDate)

    if ($null -eq $ReleaseDate) { return "" }
    return ([datetime]$ReleaseDate).ToUniversalTime().ToString('MM/dd/yyyy', [System.Globalization.CultureInfo]::InvariantCulture)
}

# Embedded controller version as xx.xx (major.minor, two digits each).
# Firmware that does not report it returns 255; that gives $null.
function Format-EcVersion {
    param($Major, $Minor)

    if ($null -eq $Major -or $null -eq $Minor -or [int]$Major -eq 255 -or [int]$Minor -eq 255) {
        return $null
    }
    return ("{0:D2}.{1:D2}" -f [int]$Major, [int]$Minor)
}

# Every device Device Manager knows on this unit (Win32_PnPEntity).
# ErrorCode is Device Manager's problem code: 0 = working, 28 = no driver,
# 24/45 = not present (see Test-DeviceNotPresent).
function Get-DeviceList {
    return @(
        Get-CimInstance Win32_PnPEntity |
        ForEach-Object {
            [pscustomobject]@{
                Name = [string]$_.Name
                Class = [string]$_.PNPClass
                HardwareIds = @(@($_.HardwareID) | Where-Object { $_ })
                InstanceId = [string]$_.PNPDeviceID
                ErrorCode = [int]$_.ConfigManagerErrorCode
            }
        }
    )
}

# Hardware IDs run from most to least specific. The revision (&REV_xx) can
# differ between otherwise identical parts, so suggest the most specific ID
# without one.
function Select-DeviceHardwareId {
    param([string[]]$HardwareIds)

    $ids = @($HardwareIds | Where-Object { $_ })
    if ($ids.Count -eq 0) { return $null }

    $withoutRevision = @($ids | Where-Object { $_ -notmatch '&REV_' })
    if ($withoutRevision.Count -gt 0) { return [string]$withoutRevision[0] }
    return [string]$ids[0]
}

# Built-in system and software devices, hidden by default in the device picker.
function Test-BuiltInDevice {
    param($Device)

    if (@("System", "SoftwareDevice", "SoftwareComponent", "Volume", "VolumeSnapshot", "LegacyDriver", "Computer", "Processor") -contains [string]$Device.Class) {
        return $true
    }
    return ([string]$Device.InstanceId -match '^(ROOT|SWD|HTREE|ACPI_HAL|STORAGE\\VOLUME)\\')
}

# Returns an error message, or $null when the serial is usable as a Windows
# computer name.
function Test-SerialNumberFormat {
    param([string]$SerialNumber)

    if ([string]::IsNullOrWhiteSpace($SerialNumber)) {
        return "Please enter a system serial number."
    }

    if ($SerialNumber.Length -gt 15 -or $SerialNumber -notmatch '^[A-Za-z0-9-]+$') {
        return "Serial number must be 15 characters or fewer and contain only letters, numbers, or hyphens."
    }

    if ($SerialNumber -match '^[0-9]+$') {
        return "Serial number cannot be only numbers, because Windows does not allow an all-numeric computer name."
    }

    return $null
}

# The name Windows will use after the next restart. Differs from
# $env:COMPUTERNAME while a rename is pending.
function Get-PendingComputerName {
    try {
        return [string](Get-ItemProperty `
            -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' `
            -Name ComputerName -ErrorAction Stop).ComputerName
    }
    catch {
        return $null
    }
}

# Decided before validation runs:
# "None"     - computer name already matches the serial, nothing pending.
# "Pending"  - a rename to this serial is already waiting for a restart.
# "Rename"   - the computer must be renamed (operator confirmation required).
# "Conflict" - the name matches the serial, but a rename to a DIFFERENT name
#              is waiting for a restart. Validation must stop: the report
#              would say the name matches while Windows is about to change it.
function Get-RenameAction {
    param(
        [string]$SerialNumber,
        [string]$CurrentName,
        [string]$PendingName
    )

    $hasPending = -not [string]::IsNullOrWhiteSpace($PendingName) -and $PendingName -ine $CurrentName

    if ($CurrentName -ieq $SerialNumber) {
        if ($hasPending) { return "Conflict" }
        return "None"
    }

    if ($hasPending -and $PendingName -ieq $SerialNumber) {
        return "Pending"
    }

    return "Rename"
}

function New-RenameInfo {
    param(
        [string]$PreviousName,
        [string]$RequestedName,
        [bool]$RenameSucceeded,
        [bool]$RebootRequired,
        [string]$Detail
    )

    return [pscustomobject]@{
        PreviousName = $PreviousName
        RequestedName = $RequestedName
        RenameSucceeded = $RenameSucceeded
        RebootRequired = $RebootRequired
        Detail = $Detail
    }
}

# Carries out the rename decision through the machine port. Action is one of
# Get-RenameAction's values, or "Skip" when the run failed.
function Rename-SystemToSerial {
    param(
        [string]$SerialNumber,
        [string]$Action,
        $Machine
    )

    $current = [string](& $Machine.ComputerName)

    if ($Action -eq "None") {
        return New-RenameInfo $current $SerialNumber $true $false "Computer name already matches serial number."
    }

    if ($Action -eq "Skip") {
        return New-RenameInfo $current $SerialNumber $true $false "Rename to '$SerialNumber' skipped because validation failed."
    }

    if ($Action -eq "Pending") {
        return New-RenameInfo $current $SerialNumber $true $true "Rename to '$SerialNumber' is already pending. Reboot required."
    }

    try {
        & $Machine.Rename $SerialNumber
        return New-RenameInfo $current $SerialNumber $true $true "Rename requested successfully. Reboot required."
    }
    catch {
        return New-RenameInfo $current $SerialNumber $false $false ([string]$_.Exception.Message)
    }
}

# The machine port for a real Windows unit. Tests pass a fake with the same
# keys: ReadIdentity, ReadSnapshot, ComputerName, PendingName, Rename.
function New-WindowsMachine {
    return @{
        ReadIdentity = { Get-HardwareIdentity }
        ReadSnapshot = { Get-HardwareSnapshot }
        ComputerName = { [string]$env:COMPUTERNAME }
        PendingName = { Get-PendingComputerName }
        Rename = { param($NewName) Rename-Computer -NewName $NewName -Force -ErrorAction Stop }
    }
}
