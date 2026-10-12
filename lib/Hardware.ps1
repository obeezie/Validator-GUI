# Reads the current machine's hardware into a snapshot object, and renames
# the computer to the unit serial number.

# NdisPhysicalMedium 9 = NdisPhysicalMediumNative802_11 (Wi-Fi).
function Test-WirelessAdapter {
    param(
        [string]$PhysicalMediaType,
        $NdisPhysicalMedium,
        [string]$Description
    )

    if ($null -ne $NdisPhysicalMedium -and [string]$NdisPhysicalMedium -eq "9") {
        return $true
    }

    if ($PhysicalMediaType -match '802\.11') {
        return $true
    }

    return ($Description -match 'Wi-?Fi|Wireless|WLAN|802\.11')
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

# "None"    - computer name already matches the serial.
# "Pending" - a rename to this serial is already waiting for a restart.
# "Rename"  - the computer must be renamed (operator confirmation required).
function Get-RenameAction {
    param(
        [string]$SerialNumber,
        [string]$CurrentName,
        [string]$PendingName
    )

    if ($CurrentName -ieq $SerialNumber) {
        return "None"
    }

    if (-not [string]::IsNullOrWhiteSpace($PendingName) -and $PendingName -ieq $SerialNumber) {
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

function Rename-SystemToSerial {
    param(
        [string]$SerialNumber,
        [string]$Action
    )

    $current = [string]$env:COMPUTERNAME

    if ($Action -eq "None") {
        return New-RenameInfo $current $SerialNumber $true $false "Computer name already matches serial number."
    }

    if ($Action -eq "Pending") {
        return New-RenameInfo $current $SerialNumber $true $true "Rename to '$SerialNumber' is already pending. Reboot required."
    }

    try {
        Rename-Computer -NewName $SerialNumber -Force -ErrorAction Stop
        return New-RenameInfo $current $SerialNumber $true $true "Rename requested successfully. Reboot required."
    }
    catch {
        return New-RenameInfo $current $SerialNumber $false $false ([string]$_.Exception.Message)
    }
}
