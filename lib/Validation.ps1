# Compares a hardware snapshot against a configuration.
#
# Result statuses: PASS, FAIL, WARN, INFO. Only FAIL affects the overall result.
#
# Required / optional components (disks, network adapters, GPUs):
#   Required + missing          -> FAIL
#   Optional + missing          -> INFO ("optional, not installed")
#   Present (either) but out of spec -> FAIL. Optional means "may be absent",
#   not "may be broken".

function New-CheckResult {
    param(
        [string]$Section,
        [string]$Check,
        [string]$Status,
        [string]$Detail
    )

    return [pscustomobject]@{
        Section = $Section
        Check = $Check
        Status = $Status
        Detail = $Detail
    }
}

function Get-PassFail {
    param([bool]$Condition)
    if ($Condition) { return "PASS" }
    return "FAIL"
}

# Pairs each expected component with a different physical component.
# Required entries pick first, so an optional entry can never "steal" the
# only device that a required entry needs. Two identical disks therefore need
# two physical disks, not one disk matched twice.
# Returns an array (same order as $Expected) of the matched actual item or $null.
function Find-ComponentMatches {
    param(
        [object[]]$Expected,
        [object[]]$Actual,
        [scriptblock]$IsMatch
    )

    $expectedList = @($Expected)
    $actualList = @($Actual)
    $matched = New-Object object[] $expectedList.Count
    $claimed = New-Object bool[] $actualList.Count

    foreach ($pass in @($true, $false)) {
        for ($e = 0; $e -lt $expectedList.Count; $e++) {
            if ((Get-RequiredFlag $expectedList[$e]) -ne $pass) { continue }

            for ($a = 0; $a -lt $actualList.Count; $a++) {
                if ($claimed[$a]) { continue }
                if (& $IsMatch $expectedList[$e] $actualList[$a]) {
                    $claimed[$a] = $true
                    $matched[$e] = $actualList[$a]
                    break
                }
            }
        }
    }

    return ,$matched
}

function Get-ComponentCheckName {
    param([string]$Name, $Expected)

    if (Get-RequiredFlag $Expected) { return $Name }
    return "$Name (optional)"
}

function New-MissingComponentResult {
    param([string]$Section, [string]$CheckName, $Expected, [string]$Noun)

    if (Get-RequiredFlag $Expected) {
        return New-CheckResult $Section $CheckName "FAIL" "Expected $Noun not found"
    }
    return New-CheckResult $Section $CheckName "INFO" "Optional $Noun not installed"
}

function Test-SystemAgainstConfig {
    param($Config,$Snapshot)

    $results = [System.Collections.Generic.List[object]]::new()

    $results.Add((New-CheckResult "SYSTEM" "Manufacturer" `
        (Get-PassFail (([string]$Snapshot.System.Manufacturer).Trim() -ieq ([string]$Config.System.Manufacturer).Trim())) `
        ([string]$Snapshot.System.Manufacturer)))

    $results.Add((New-CheckResult "SYSTEM" "Model" `
        (Get-PassFail (([string]$Snapshot.System.Model).Trim() -ieq ([string]$Config.System.Model).Trim())) `
        ([string]$Snapshot.System.Model)))

    $results.Add((New-CheckResult "CPU" "Model" `
        (Get-PassFail (Test-ContainsText ([string]$Snapshot.CPU.Model) ([string]$Config.CPU.ModelContains))) `
        ([string]$Snapshot.CPU.Model)))

    $results.Add((New-CheckResult "CPU" "Cores" `
        (Get-PassFail ([int]$Snapshot.CPU.CoreCount -ge [int]$Config.CPU.MinimumCores)) `
        "$([int]$Snapshot.CPU.CoreCount) detected (minimum $([int]$Config.CPU.MinimumCores))"))

    if ([int]$Config.CPU.MinimumLogicalCPUs -gt 0) {
        $results.Add((New-CheckResult "CPU" "Logical CPUs" `
            (Get-PassFail ([int]$Snapshot.CPU.LogicalProcessors -ge [int]$Config.CPU.MinimumLogicalCPUs)) `
            "$([int]$Snapshot.CPU.LogicalProcessors) detected (minimum $([int]$Config.CPU.MinimumLogicalCPUs))"))
    }

    $results.Add((New-CheckResult "MEMORY" "Total RAM" `
        (Get-PassFail ([double]$Snapshot.Memory.TotalGB -ge [double]$Config.Memory.MinimumTotalGB)) `
        "$([double]$Snapshot.Memory.TotalGB) GB (minimum $([double]$Config.Memory.MinimumTotalGB) GB)"))

    $results.Add((New-CheckResult "MEMORY" "DIMM Count" `
        (Get-PassFail ([int]$Snapshot.Memory.DimmCount -eq [int]$Config.Memory.ExpectedDIMMs)) `
        "$([int]$Snapshot.Memory.DimmCount) detected (expected $([int]$Config.Memory.ExpectedDIMMs))"))

    # Storage
    $expectedDisks = @(@($Config.Storage.PhysicalDisks) | Where-Object { $null -ne $_ })
    $diskMatches = Find-ComponentMatches -Expected $expectedDisks -Actual @($Snapshot.Storage.PhysicalDisks) -IsMatch {
        param($exp, $act)
        (Test-ContainsText ([string]$act.FriendlyName) ([string]$exp.FriendlyNameContains)) -and
        ([string]$act.BusType -ieq [string]$exp.BusType)
    }

    for ($i = 0; $i -lt $expectedDisks.Count; $i++) {
        $expected = $expectedDisks[$i]
        $actual = $diskMatches[$i]
        $checkName = Get-ComponentCheckName ([string]$expected.FriendlyNameContains) $expected

        if ($null -eq $actual) {
            $results.Add((New-MissingComponentResult "STORAGE" $checkName $expected "disk"))
            continue
        }

        $problems = [System.Collections.Generic.List[string]]::new()
        if ([double]$actual.SizeGB -lt [double]$expected.MinimumGB) {
            $problems.Add("below minimum $([double]$expected.MinimumGB) GB")
        }
        if (@("Warning","Unhealthy") -contains [string]$actual.HealthStatus) {
            $problems.Add("disk health is $([string]$actual.HealthStatus)")
        }

        $detail = "$([double]$actual.SizeGB) GB, Health=$([string]$actual.HealthStatus), Serial=$([string]$actual.SerialNumber)"
        if ($problems.Count -gt 0) {
            $detail = "$detail - " + [string]::Join("; ", $problems)
        }

        $results.Add((New-CheckResult "STORAGE" $checkName (Get-PassFail ($problems.Count -eq 0)) $detail))
    }

    # Network
    $expectedNics = @(@($Config.Network.Adapters) | Where-Object { $null -ne $_ })
    $nicMatches = Find-ComponentMatches -Expected $expectedNics -Actual @($Snapshot.Network.Adapters) -IsMatch {
        param($exp, $act)
        Test-ContainsText ([string]$act.InterfaceDescription) ([string]$exp.AdapterContains)
    }

    for ($i = 0; $i -lt $expectedNics.Count; $i++) {
        $expected = $expectedNics[$i]
        $actual = $nicMatches[$i]
        $checkName = Get-ComponentCheckName ([string]$expected.AdapterContains) $expected

        if ($null -eq $actual) {
            $results.Add((New-MissingComponentResult "NETWORK" $checkName $expected "adapter"))
            continue
        }

        $problems = [System.Collections.Generic.List[string]]::new()

        if ([bool]$expected.RequireUp -and [string]$actual.Status -ne "Up") {
            $problems.Add("link must be Up")
        }

        # Wi-Fi link rates vary with signal, so a minimum is never enforced
        # for wireless adapters, even when an older config specifies one.
        $isWireless = [bool]$actual.IsWireless
        if (-not $isWireless -and $null -ne $expected.MinimumLinkMbps -and $null -ne $actual.LinkSpeedMbps) {
            if ([double]$actual.LinkSpeedMbps -lt [double]$expected.MinimumLinkMbps) {
                $problems.Add("link below minimum $([double]$expected.MinimumLinkMbps) Mbps")
            }
        }

        $detail = "Status=$([string]$actual.Status), Link=$([string]$actual.LinkSpeed), MAC=$([string]$actual.MacAddress)"
        if ($isWireless) {
            $detail = "$detail, Wireless (link speed not checked)"
        }
        if ($problems.Count -gt 0) {
            $detail = "$detail - " + [string]::Join("; ", $problems)
        }

        $results.Add((New-CheckResult "NETWORK" $checkName (Get-PassFail ($problems.Count -eq 0)) $detail))
    }

    # GPU
    $expectedGpus = @(@($Config.GPU.Adapters) | Where-Object { $null -ne $_ })
    $gpuMatches = Find-ComponentMatches -Expected $expectedGpus -Actual @($Snapshot.GPU.Adapters) -IsMatch {
        param($exp, $act)
        Test-ContainsText ([string]$act.Name) ([string]$exp.ModelContains)
    }

    for ($i = 0; $i -lt $expectedGpus.Count; $i++) {
        $expected = $expectedGpus[$i]
        $actual = $gpuMatches[$i]
        $checkName = Get-ComponentCheckName ([string]$expected.ModelContains) $expected

        if ($null -eq $actual) {
            $results.Add((New-MissingComponentResult "GPU" $checkName $expected "GPU"))
        } else {
            $results.Add((New-CheckResult "GPU" $checkName "PASS" ([string]$actual.Name)))
        }
    }

    return @($results)
}

function Get-OverallResult {
    param(
        $Results,
        $RenameInfo
    )

    $failures = @(@($Results) | Where-Object { $_.Status -eq "FAIL" })

    if ($failures.Count -eq 0 -and [bool]$RenameInfo.RenameSucceeded) {
        return "PASS"
    }
    return "FAIL"
}
