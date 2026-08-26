function New-RmoPlanNarrative {
    <#
        .SYNOPSIS
            Writes the plain-language explanation that goes at the top of the plan.

        .DESCRIPTION
            A table of percentages does not tell somebody what is wrong with their computer. This
            turns the measurements into the four sentences a person actually needs: which resource
            is the constraint, what the evidence for that is, what is consuming it, and what to do
            first.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] [psobject] $System,
        [Parameter(Mandatory)] [psobject] $Pressure,
        [Parameter(Mandatory)] [psobject] $Hogs,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Action,
        [Parameter(Mandatory)] [string] $ScanMode
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $primary = $Pressure.Bottleneck.Primary

    #region The verdict
    switch ($primary) {
        'CPU' {
            $lines.Add("This machine is processor-bound. The CPU was $(Format-RmoPercent $Pressure.Cpu.TotalPercent) busy across $($System.Cpu.LogicalProcessors) logical processors during the scan, and work was queuing for a core.")
        }
        'Memory' {
            $lines.Add("This machine is short of memory. $(Format-RmoBytes $Pressure.Memory.AvailableBytes) was available of $(Format-RmoBytes $Pressure.Memory.TotalBytes) fitted, which is $(Format-RmoPercent $Pressure.Memory.UsedPercent) in use.")
        }
        'Disk' {
            $lines.Add("This machine is waiting on its disk. Each transfer was taking $($Pressure.Disk.LatencyMs) ms on average, against a few milliseconds on a healthy SSD, with the disk $(Format-RmoPercent $Pressure.Disk.BusyPercent) busy.")
        }
        'Network' {
            $lines.Add('This machine is limited by its network connection rather than by anything on it. An adapter was close to its link speed for the duration of the scan.')
        }
        default {
            $lines.Add('No single resource was constrained during the scan. The processor, memory and disk all had headroom, so whatever the machine feels like, it was not being held back by capacity at the moment it was measured.')
        }
    }
    #endregion

    #region The evidence, for each resource in turn
    $lines.Add('')
    $lines.Add('What was measured:')
    $lines.Add("  CPU      $(Format-RmoPercent $Pressure.Cpu.TotalPercent) busy - $(Format-RmoPercent $Pressure.Cpu.AttributedPercent) attributed to processes, $(Format-RmoPercent $Pressure.Cpu.UnattributedPercent) to interrupts and drivers. Pressure $($Pressure.Cpu.Score)/100 ($($Pressure.Cpu.Level)).")
    $lines.Add("  Memory   $(Format-RmoBytes $Pressure.Memory.AvailableBytes) available of $(Format-RmoBytes $Pressure.Memory.TotalBytes). Pressure $($Pressure.Memory.Score)/100 ($($Pressure.Memory.Level)).")
    $diskDetail = if ($null -ne $Pressure.Disk.LatencyMs) { "$($Pressure.Disk.LatencyMs) ms per transfer" } else { 'latency not available' }
    $lines.Add("  Disk     $(Format-RmoPercent $Pressure.Disk.BusyPercent) busy, $diskDetail, media $($Pressure.Disk.SystemDiskMedia). Pressure $($Pressure.Disk.Score)/100 ($($Pressure.Disk.Level)).")
    $lines.Add("  Network  $(Format-RmoRate $Pressure.Network.BytesPerSecond) across all adapters. Pressure $($Pressure.Network.Score)/100 ($($Pressure.Network.Level)).")

    if ($Pressure.Cpu.UnattributedPercent -ge 15) {
        $lines.Add('')
        $lines.Add("Note that $(Format-RmoPercent $Pressure.Cpu.UnattributedPercent) of the processor time belongs to no process at all. That is interrupt and deferred-procedure-call work, which means a device driver. Closing applications will not reduce it.")
    }
    if ($Pressure.Memory.CompressedBytes -gt 512MB) {
        $lines.Add('')
        $lines.Add("The compressed page store holds $(Format-RmoBytes $Pressure.Memory.CompressedBytes). Windows only compresses pages when it is trying to avoid writing them to disk, so this is direct evidence of a memory shortage rather than an inference from a percentage.")
    }
    #endregion

    #region What is consuming it
    $lines.Add('')
    switch ($primary) {
        'CPU'    { $consumers = @($Hogs.TopFamilyCpu | Select-Object -First 3) }
        'Memory' { $consumers = @($Hogs.TopFamilyMemory | Select-Object -First 3) }
        'Disk'   { $consumers = @($Hogs.Families | Sort-Object DiskBytesPerSecond -Descending | Select-Object -First 3) }
        default  { $consumers = @($Hogs.TopFamilyMemory | Select-Object -First 3) }
    }
    if ($consumers.Count -gt 0) {
        $lines.Add('Largest consumers, grouped by product:')
        foreach ($consumer in $consumers) {
            $instances = if ($consumer.ProcessCount -gt 1) { " across $($consumer.ProcessCount) processes" } else { '' }
            $lines.Add("  $($consumer.Family) ($($consumer.Vendor)) - $($consumer.MemoryText) memory, $($consumer.CpuText) CPU, $($consumer.DiskText) disk$instances.")
        }
    }
    #endregion

    #region What to do first
    $ordered = @($Action | Where-Object { $_.Impact -in 'High', 'Medium' } | Select-Object -First 3)
    if ($ordered.Count -gt 0) {
        $lines.Add('')
        $lines.Add('Where to start:')
        $step = 1
        foreach ($action in $ordered) {
            $lines.Add("  $step. $($action.Title)")
            $lines.Add("     $($action.Recommendation)")
            if ($action.Gain) { $lines.Add("     Expected: $($action.Gain)") }
            $step++
        }
    } elseif (@($Action).Count -eq 0) {
        $lines.Add('')
        $lines.Add('Nothing on this machine is worth changing on the strength of these measurements.')
    }
    #endregion

    #region What this scan could not see
    $caveats = [System.Collections.Generic.List[string]]::new()
    if ($ScanMode -eq 'Quick') {
        $caveats.Add('This was a quick scan: one measured interval, no signature checks, no scheduled tasks and no event log history. A complete scan measures over a longer window and will catch a process that is busy in bursts.')
    }
    if (-not (Test-RmoElevated)) {
        $caveats.Add('The scan ran without administrator rights, so the path and command line of processes belonging to other users and to the system could not be read. Some of those are named only by their executable.')
    }
    if ($Pressure.Bottleneck.Primary -eq 'None' -and $Pressure.Cpu.Score -lt 40 -and $Pressure.Memory.Score -lt 60) {
        $caveats.Add('A scan measures the machine as it is now. If the complaint is that it is slow at a particular moment - first thing in the morning, during a meeting, when a specific application is used - run the scan again while that is happening.')
    }
    if ($caveats.Count -gt 0) {
        $lines.Add('')
        $lines.Add('What this scan could not see:')
        foreach ($caveat in $caveats) { $lines.Add("  - $caveat") }
    }
    #endregion

    $lines.ToArray()
}
