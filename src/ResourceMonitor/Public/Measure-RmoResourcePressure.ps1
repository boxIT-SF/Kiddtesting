function Measure-RmoResourcePressure {
    <#
        .SYNOPSIS
            Works out which resource is actually making the machine slow.

        .DESCRIPTION
            Four resources decide whether a Windows machine feels usable, and they fail in
            different ways, so each is judged on the measurement that matters for it:

              CPU      total busy time, and how much of it cannot be attributed to any process.
                       Unattributed time is interrupt and deferred-procedure-call work, which
                       means a driver, not an application.
              Memory   how much is actually available, and how close the commit charge is to the
                       limit. Hard page faults and the size of the compressed page store say
                       whether the shortage has started costing disk time.
              Disk     average latency per transfer first, utilisation second. A disk at 100%
                       utilisation with 1 ms latency is keeping up; a disk at 40% with 80 ms
                       latency is the reason nothing responds.
              Network  throughput against the link speed of each adapter.

            Each gets a 0-100 pressure score, and the highest score above the "a person would
            notice this" line becomes the primary constraint. That single answer is what the plan
            is built around: there is no point closing browser tabs on a machine whose problem is
            a 5400 rpm disk.

        .PARAMETER System
            A snapshot from Get-RmoSystemSnapshot.

        .PARAMETER Process
            Samples from Get-RmoProcessSample, used for the attributed share of CPU and memory.

        .PARAMETER Deep
            Also read per-disk, per-adapter and GPU counters.

        .PARAMETER ErrorSink
            Optional list for counters that could not be read.

        .EXAMPLE
            Measure-RmoResourcePressure -System $system -Process $processes
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory)] [psobject] $System,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Process,
        [switch] $Deep,
        [System.Collections.IList] $ErrorSink
    )

    $logical = [math]::Max(1, $System.Cpu.LogicalProcessors)

    #region CPU
    $attributed = 0
    foreach ($item in $Process) {
        if ($null -ne $item.CpuPercent) { $attributed += $item.CpuPercent }
    }
    $attributed = Limit-RmoValue $attributed 0 100

    $processorCounter = Get-RmoFirstOrDefault (Invoke-RmoCim -ClassName 'Win32_PerfFormattedData_PerfOS_Processor' `
        -Filter "Name = '_Total'" -ErrorSink $ErrorSink)
    $counterTotal = Get-RmoObjectValue $processorCounter 'PercentProcessorTime'
    $interruptTime = Get-RmoObjectValue $processorCounter 'PercentInterruptTime'
    $privilegedTime = Get-RmoObjectValue $processorCounter 'PercentPrivilegedTime'

    $cpuTotal = if ($null -ne $counterTotal) {
        Limit-RmoValue ([double] $counterTotal) 0 100
    } else {
        $attributed
    }
    # Work the scheduler charged to no process at all: interrupt handling and DPCs. Sustained
    # time here is a driver, and no amount of closing applications will touch it.
    $unattributed = Limit-RmoValue ($cpuTotal - $attributed) 0 100

    $systemCounter = Get-RmoFirstOrDefault (Invoke-RmoCim -ClassName 'Win32_PerfFormattedData_PerfOS_System' -ErrorSink $ErrorSink)
    $queueLength = Get-RmoObjectValue $systemCounter 'ProcessorQueueLength'
    $contextSwitches = Get-RmoObjectValue $systemCounter 'ContextSwitchesPersec'
    $queuePerCore = if ($null -ne $queueLength) { [double] $queueLength / $logical } else { $null }

    $cpuScore = Get-RmoCpuPressureScore $cpuTotal $queuePerCore

    # Not the bottleneck, but worth naming: a laptop pinned well below its rated clock is being
    # throttled by power policy or heat, and no amount of tuning software will fix that.
    $clockRatio = $null
    if ($System.Cpu.MaxClockMhz -gt 0 -and $System.Cpu.CurrentClockMhz -gt 0) {
        $clockRatio = [math]::Round(($System.Cpu.CurrentClockMhz / $System.Cpu.MaxClockMhz) * 100, 0)
    }
    #endregion

    #region Memory
    $totalMemory = [double] $System.Memory.TotalBytes
    $available = [double] $System.Memory.AvailableBytes
    $usedPercent = if ($totalMemory -gt 0) { Limit-RmoValue ((1 - ($available / $totalMemory)) * 100) 0 100 } else { $null }

    $commitPercent = $null
    if ($null -ne $System.Memory.CommittedBytes -and $null -ne $System.Memory.CommitLimit -and $System.Memory.CommitLimit -gt 0) {
        $commitPercent = Limit-RmoValue (($System.Memory.CommittedBytes / $System.Memory.CommitLimit) * 100) 0 100
    }

    $memoryCounter = Get-RmoFirstOrDefault (Invoke-RmoCim -ClassName 'Win32_PerfFormattedData_PerfOS_Memory' -ErrorSink $ErrorSink)
    $hardFaults = Get-RmoObjectValue $memoryCounter 'PageReadsPersec'
    $pagesPerSecond = Get-RmoObjectValue $memoryCounter 'PagesPersec'
    $poolPaged = Get-RmoObjectValue $memoryCounter 'PoolPagedBytes'
    $poolNonPaged = Get-RmoObjectValue $memoryCounter 'PoolNonpagedBytes'

    $compressed = 0
    foreach ($item in $Process) {
        if ($item.Name -in 'Memory Compression', 'MemCompression') { $compressed += $item.WorkingSetBytes }
    }

    $memoryScore = Get-RmoMemoryPressureScore $usedPercent $commitPercent $hardFaults $available $compressed $totalMemory
    #endregion

    #region Disk
    $diskTotal = Get-RmoFirstOrDefault (Invoke-RmoCim -ClassName 'Win32_PerfFormattedData_PerfDisk_PhysicalDisk' `
        -Filter "Name = '_Total'" -ErrorSink $ErrorSink)
    $diskBusy = Get-RmoObjectValue $diskTotal 'PercentDiskTime'
    $diskQueue = Get-RmoObjectValue $diskTotal 'CurrentDiskQueueLength'
    $diskBytes = Get-RmoObjectValue $diskTotal 'DiskBytesPersec'
    $diskTransfers = Get-RmoObjectValue $diskTotal 'DiskTransfersPersec'
    $secPerTransfer = Get-RmoObjectValue $diskTotal 'AvgDisksecPerTransfer'
    $latencyMs = if ($null -ne $secPerTransfer) { [math]::Round([double] $secPerTransfer * 1000, 2) } else { $null }
    $diskBusyPercent = if ($null -ne $diskBusy) { Limit-RmoValue ([double] $diskBusy) 0 100 } else { $null }

    $perDisk = @()
    if ($Deep) {
        $perDisk = foreach ($disk in Invoke-RmoCim -ClassName 'Win32_PerfFormattedData_PerfDisk_PhysicalDisk' -ErrorSink $ErrorSink) {
            $name = [string] (Get-RmoObjectValue $disk 'Name' '')
            if ($name -eq '_Total') { continue }
            $perTransfer = Get-RmoObjectValue $disk 'AvgDisksecPerTransfer'
            [pscustomobject]@{
                Name          = $name
                BusyPercent   = Limit-RmoValue ([double] (Get-RmoObjectValue $disk 'PercentDiskTime' 0)) 0 100
                QueueLength   = [double] (Get-RmoObjectValue $disk 'CurrentDiskQueueLength' 0)
                BytesPerSecond = [double] (Get-RmoObjectValue $disk 'DiskBytesPersec' 0)
                LatencyMs     = $(if ($null -ne $perTransfer) { [math]::Round([double] $perTransfer * 1000, 2) } else { $null })
            }
        }
    }

    $diskScore = Get-RmoDiskPressureScore $diskBusyPercent $latencyMs $(if ($null -ne $diskQueue) { [double] $diskQueue } else { $null })

    $systemDiskMedia = 'Unknown'
    foreach ($disk in $System.Storage) {
        if ($disk.DeviceId -match '(?i)PHYSICALDRIVE0$') { $systemDiskMedia = $disk.MediaType }
    }
    if ($systemDiskMedia -eq 'Unknown' -and @($System.Storage).Count -eq 1) {
        $systemDiskMedia = @($System.Storage)[0].MediaType
    }
    #endregion

    #region Network
    $adapters = @()
    $networkBytes = 0
    foreach ($adapter in Invoke-RmoCim -ClassName 'Win32_PerfFormattedData_Tcpip_NetworkInterface' -ErrorSink $ErrorSink) {
        $name = [string] (Get-RmoObjectValue $adapter 'Name' '')
        # The loopback pseudo-interface carries local traffic and would dominate the total.
        if ($name -match '(?i)loopback|isatap|teredo') { continue }
        $bytes = [double] (Get-RmoObjectValue $adapter 'BytesTotalPersec' 0)
        $bandwidth = [double] (Get-RmoObjectValue $adapter 'CurrentBandwidth' 0)
        $utilisation = $null
        if ($bandwidth -gt 0) {
            $utilisation = Limit-RmoValue ((($bytes * 8) / $bandwidth) * 100) 0 100
        }
        $networkBytes += $bytes
        if ($Deep -or $bytes -gt 0) {
            $adapters += [pscustomobject]@{
                Name             = $name
                BytesPerSecond   = $bytes
                LinkSpeedBitsPerSecond = $bandwidth
                UtilisationPercent = $utilisation
            }
        }
    }
    $networkScore = 0
    foreach ($adapter in $adapters) {
        if ($null -ne $adapter.UtilisationPercent -and $adapter.UtilisationPercent -gt $networkScore) {
            $networkScore = $adapter.UtilisationPercent
        }
    }
    #endregion

    #region GPU
    $gpuPercent = $null
    if ($Deep) {
        try {
            $samples = (Get-Counter -Counter '\GPU Engine(*)\Utilization Percentage' -ErrorAction Stop).CounterSamples
            $total = 0
            foreach ($sample in $samples) { $total += [double] $sample.CookedValue }
            $gpuPercent = Limit-RmoValue $total 0 100
        } catch {
            Write-Verbose "GPU engine counters are unavailable: $($_.Exception.Message)"
        }
    }
    #endregion

    $threadTotal = 0
    $handleTotal = 0
    foreach ($item in $Process) {
        $threadTotal += $item.ThreadCount
        $handleTotal += $item.HandleCount
    }

    #region Which of them is the problem
    $dimensions = @(
        [pscustomobject]@{ Name = 'CPU';     Score = $cpuScore }
        [pscustomobject]@{ Name = 'Memory';  Score = $memoryScore }
        [pscustomobject]@{ Name = 'Disk';    Score = $diskScore }
        [pscustomobject]@{ Name = 'Network'; Score = $networkScore }
    )
    $ranked = @($dimensions | Sort-Object Score -Descending)
    $primary = 'None'
    $secondary = ''
    # 65 is the point at which a resource stops being busy and starts being felt.
    if ($ranked[0].Score -ge 65) { $primary = $ranked[0].Name }
    if ($ranked.Count -gt 1 -and $ranked[1].Score -ge 65) { $secondary = $ranked[1].Name }

    # A machine out of memory drives its disk hard, so the disk will often score highest on a
    # machine whose actual problem is memory. Hard page faults are what separate the two: they
    # are the memory manager reading pages back from disk, so where they are running with little
    # memory left, the disk is a symptom and naming it as the constraint sends the reader off to
    # replace the wrong component.
    $pagingUnderPressure = ($memoryScore -ge 90) -and
                           ($null -ne $hardFaults) -and ([double] $hardFaults -gt 50)
    if ($primary -eq 'Disk' -and $pagingUnderPressure) {
        $primary = 'Memory'
        $secondary = 'Disk'
    }
    #endregion

    [pscustomobject]@{
        PSTypeName = 'Rmo.ResourcePressure'
        Cpu        = [pscustomobject]@{
            TotalPercent        = [math]::Round($cpuTotal, 1)
            AttributedPercent   = [math]::Round($attributed, 1)
            UnattributedPercent = [math]::Round($unattributed, 1)
            InterruptPercent    = $(if ($null -ne $interruptTime) { [math]::Round([double] $interruptTime, 1) } else { $null })
            PrivilegedPercent   = $(if ($null -ne $privilegedTime) { [math]::Round([double] $privilegedTime, 1) } else { $null })
            QueueLength         = $(if ($null -ne $queueLength) { [double] $queueLength } else { $null })
            QueuePerCore        = $(if ($null -ne $queuePerCore) { [math]::Round($queuePerCore, 2) } else { $null })
            ContextSwitchesPerSecond = $(if ($null -ne $contextSwitches) { [double] $contextSwitches } else { $null })
            ClockRatioPercent   = $clockRatio
            Score               = [math]::Round($cpuScore, 0)
            Level               = Get-RmoPressureLevel $cpuScore 70 90
        }
        Memory     = [pscustomobject]@{
            TotalBytes        = $totalMemory
            AvailableBytes    = $available
            UsedPercent       = $(if ($null -ne $usedPercent) { [math]::Round($usedPercent, 1) } else { $null })
            CommittedBytes    = $System.Memory.CommittedBytes
            CommitLimitBytes  = $System.Memory.CommitLimit
            CommitPercent     = $(if ($null -ne $commitPercent) { [math]::Round($commitPercent, 1) } else { $null })
            HardFaultsPerSecond = $(if ($null -ne $hardFaults) { [double] $hardFaults } else { $null })
            PagesPerSecond    = $(if ($null -ne $pagesPerSecond) { [double] $pagesPerSecond } else { $null })
            CompressedBytes   = $compressed
            PoolPagedBytes    = $(if ($null -ne $poolPaged) { [double] $poolPaged } else { $null })
            PoolNonPagedBytes = $(if ($null -ne $poolNonPaged) { [double] $poolNonPaged } else { $null })
            Score             = [math]::Round($memoryScore, 0)
            Level             = Get-RmoPressureLevel $memoryScore 80 92
        }
        Disk       = [pscustomobject]@{
            BusyPercent     = $diskBusyPercent
            LatencyMs       = $latencyMs
            QueueLength     = $(if ($null -ne $diskQueue) { [double] $diskQueue } else { $null })
            BytesPerSecond  = $(if ($null -ne $diskBytes) { [double] $diskBytes } else { $null })
            TransfersPerSecond = $(if ($null -ne $diskTransfers) { [double] $diskTransfers } else { $null })
            SystemDiskMedia = $systemDiskMedia
            PerDisk         = @($perDisk)
            Score           = [math]::Round($diskScore, 0)
            Level           = Get-RmoPressureLevel $diskScore 60 85
        }
        Network    = [pscustomobject]@{
            BytesPerSecond = $networkBytes
            Adapters       = @($adapters)
            Score          = [math]::Round($networkScore, 0)
            Level          = Get-RmoPressureLevel $networkScore 70 90
        }
        Gpu        = [pscustomobject]@{
            UtilisationPercent = $gpuPercent
            Adapters           = $System.Graphics
        }
        Counts     = [pscustomobject]@{
            Processes = @($Process).Count
            Threads   = $threadTotal
            Handles   = $handleTotal
        }
        Bottleneck = [pscustomobject]@{
            Primary   = $primary
            Secondary = $secondary
            Ranked    = $ranked
        }
    }
}
