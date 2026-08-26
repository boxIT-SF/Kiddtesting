function New-RmoTextReport {
    <#
        .SYNOPSIS
            Renders the analysis as plain text - for the console, the UI summary tab, an email
            or a ticket note.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [psobject] $Result,
        [int] $Width = 100
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $system = $Result.System
    $pressure = $Result.Pressure
    $plan = $Result.Plan

    function Add-Heading {
        param([string] $Text)
        $lines.Add('')
        $lines.Add($Text.ToUpperInvariant())
        $lines.Add('-' * [math]::Min($Width, [math]::Max(20, $Text.Length)))
    }

    #region Header
    $lines.Add('=' * $Width)
    $lines.Add("RESOURCE REPORT - $($system.ComputerName)")
    $lines.Add('=' * $Width)
    $lines.Add("Scan            $($Result.ScanMode), $($Result.DurationSeconds)s, $($Result.ScanStartedUtc.ToString('yyyy-MM-dd HH:mm:ss')) UTC")
    $lines.Add("Machine         $($system.Manufacturer) $($system.Model)$(if ($system.IsLaptop) { ' (portable)' })")
    $lines.Add("Operating sys   $($system.Os.Caption) build $($system.Os.BuildNumber), $($system.Os.Architecture)")
    $lines.Add("Processor       $($system.Cpu.Name) - $($system.Cpu.Cores) cores, $($system.Cpu.LogicalProcessors) logical")
    $lines.Add("Memory          $(Format-RmoBytes $system.Memory.TotalBytes) fitted, $($system.Memory.UsedSlots) of $($system.Memory.TotalSlots) slots used")
    $lines.Add("System disk     $($pressure.Disk.SystemDiskMedia)")
    $lines.Add("Uptime          $(Format-RmoDuration $system.Os.UptimeSeconds)")
    $lines.Add("Power plan      $($system.PowerPlan.Name)$(if ($system.OnBattery) { ' (on battery)' })")
    $lines.Add("Privileges      $(if ($Result.Elevated) { 'Administrator' } else { 'Standard user - some processes could not be read' })")
    if ($Result.Cancelled) {
        $lines.Add('NOTE            The scan was cancelled early. Figures below are incomplete.')
    }
    #endregion

    #region Verdict
    Add-Heading 'Verdict'
    foreach ($line in $plan.Narrative) {
        if ($line -eq '' -or $line.StartsWith('  ')) { $lines.Add($line); continue }
        foreach ($wrapped in Format-RmoWrappedText $line $Width) { $lines.Add($wrapped) }
    }
    #endregion

    #region Top consumers
    Add-Heading 'Top consumers by product'
    $lines.Add(('{0,-38} {1,-26} {2,10} {3,8} {4,11} {5,4}' -f 'Product', 'Manufacturer', 'Memory', 'CPU', 'Disk', 'Proc'))
    foreach ($family in @($Result.Hogs.TopFamilyMemory | Select-Object -First 12)) {
        $lines.Add(('{0,-38} {1,-26} {2,10} {3,8} {4,11} {5,4}' -f
            (Limit-RmoText $family.Family 38), (Limit-RmoText $family.Vendor 26),
            $family.MemoryText, $family.CpuText, $family.DiskText, $family.ProcessCount))
    }

    if (@($Result.Hogs.TopFamilyCpu).Count -gt 0) {
        Add-Heading 'Top consumers by processor time'
        $lines.Add(('{0,-38} {1,-26} {2,8} {3,10}' -f 'Product', 'Manufacturer', 'CPU', 'Memory'))
        foreach ($family in @($Result.Hogs.TopFamilyCpu | Select-Object -First 10)) {
            $lines.Add(('{0,-38} {1,-26} {2,8} {3,10}' -f
                (Limit-RmoText $family.Family 38), (Limit-RmoText $family.Vendor 26),
                $family.CpuText, $family.MemoryText))
        }
    }

    Add-Heading 'Heaviest individual processes'
    $lines.Add(('{0,-24} {1,6} {2,10} {3,8} {4,11} {5}' -f 'Process', 'PID', 'Memory', 'CPU', 'Disk', 'What it is'))
    foreach ($item in @($Result.Hogs.TopMemory | Select-Object -First 15)) {
        $what = $item.Identity.Name
        if ($item.ServiceText) { $what = "$what [$($item.ServiceText)]" }
        $lines.Add(('{0,-24} {1,6} {2,10} {3,8} {4,11} {5}' -f
            (Limit-RmoText $item.Name 24), $item.ProcessId, $item.MemoryText,
            $item.CpuText, $item.DiskText, (Limit-RmoText $what ($Width - 62))))
    }
    #endregion

    #region The plan
    Add-Heading "Plan - $($plan.HighImpactCount) high, $($plan.MediumImpactCount) medium, $($plan.LowImpactCount) low"
    if (@($plan.Actions).Count -eq 0) {
        $lines.Add('Nothing found that is worth changing.')
    } else {
        $number = 1
        foreach ($action in $plan.Actions) {
            $lines.Add('')
            $lines.Add("[$($action.Impact.ToUpperInvariant())] $number. $($action.Title)")
            $lines.Add("     Category: $($action.Category) | Effort: $($action.Effort) | Risk: $($action.Safety)")
            foreach ($wrapped in Format-RmoWrappedText "Measured: $($action.Evidence)" $Width '     ') { $lines.Add($wrapped) }
            foreach ($wrapped in Format-RmoWrappedText "What it is: $($action.Detail)" $Width '     ') { $lines.Add($wrapped) }
            foreach ($wrapped in Format-RmoWrappedText "Do this: $($action.Recommendation)" $Width '     ') { $lines.Add($wrapped) }
            if ($action.Gain) {
                foreach ($wrapped in Format-RmoWrappedText "Expected gain: $($action.Gain)" $Width '     ') { $lines.Add($wrapped) }
            }
            if ($action.Command) { $lines.Add("     Command: $($action.Command)") }
            $number++
        }
        $lines.Add('')
        $lines.Add("Reclaimable by the software changes above: $($plan.RecoverableMemoryText) of memory and $($plan.RecoverableCpuPercent)% of the processor.")
    }
    #endregion

    #region Startup
    $enabled = @($Result.StartupItems | Where-Object { $_.Enabled })
    if ($enabled.Count -gt 0) {
        Add-Heading "Starts automatically ($($enabled.Count) entries)"
        $lines.Add(('{0,-32} {1,-24} {2,-8} {3,10} {4}' -f 'Entry', 'Manufacturer', 'Impact', 'Memory', 'Running'))
        foreach ($item in @($enabled | Sort-Object MemoryBytes -Descending)) {
            $lines.Add(('{0,-32} {1,-24} {2,-8} {3,10} {4}' -f
                (Limit-RmoText $item.Name 32), (Limit-RmoText $item.Identity.Vendor 24),
                $item.Impact, $item.MemoryText, $(if ($item.Running) { "yes ($($item.InstanceCount))" } else { 'no' })))
        }
    }
    #endregion

    #region Anything the scan could not do
    if (@($Result.ScanErrors).Count -gt 0) {
        Add-Heading 'Readings that could not be taken'
        foreach ($item in @($Result.ScanErrors | Select-Object -Unique -First 20)) {
            foreach ($wrapped in Format-RmoWrappedText "- $item" $Width) { $lines.Add($wrapped) }
        }
    }
    #endregion

    $lines.Add('')
    $lines.Add("Memory is reported as the private working set where the performance counters could supply it.")
    $lines.Add("Generated by ResourceMonitor $($script:RmoModuleVersion).")

    $lines -join [Environment]::NewLine
}

function Limit-RmoText {
    <#
        .SYNOPSIS
            Truncates a string to fit a fixed-width column, with an ellipsis when it had to cut.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)] [AllowEmptyString()] [AllowNull()] [string] $Text,
        [Parameter(Position = 1)] [int] $Length = 40
    )

    if ([string]::IsNullOrEmpty($Text)) { return '' }
    if ($Length -lt 4) { $Length = 4 }
    if ($Text.Length -le $Length) { return $Text }
    $Text.Substring(0, $Length - 3) + '...'
}
