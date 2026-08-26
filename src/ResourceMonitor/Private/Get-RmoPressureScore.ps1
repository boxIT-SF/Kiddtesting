# The scoring rules, separated from the counter reading so that each can be reasoned about and
# tested without a machine under load to reproduce.

function Get-RmoCpuPressureScore {
    <#
        .SYNOPSIS
            0-100 for how much the processor is holding the machine back.
        .DESCRIPTION
            Busy time alone is not the whole answer. A processor at 100% with nothing waiting is
            a machine doing work; a processor at 100% with four threads per core queued behind it
            is a machine that will not respond to a mouse click. The run queue is what separates
            the two, so once it is deeper than about two threads per core the score is raised into
            the critical band regardless of the utilisation figure.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory, Position = 0)] [double] $TotalPercent,
        [Parameter(Position = 1)] [AllowNull()] [System.Nullable[double]] $QueuePerCore
    )

    $score = Limit-RmoValue $TotalPercent 0 100
    if ($null -ne $QueuePerCore -and $QueuePerCore -gt 2) {
        $score = [math]::Max($score, 85 + (Limit-RmoValue ([double] $QueuePerCore - 2) 0 15))
    }
    Limit-RmoValue $score 0 100
}

function Get-RmoMemoryPressureScore {
    <#
        .SYNOPSIS
            0-100 for how short of memory the machine is.
        .DESCRIPTION
            Three independent signals, and the worst of them wins:

              how much is left        the headline figure, and on its own the least reliable,
                                      because Windows will happily use most of the memory for
                                      cache on a machine that is perfectly healthy;
              commit against limit    the number that decides whether an allocation succeeds;
              hard faults             pages being read back from disk while little memory is
                                      left, which is thrashing and is the worst state a machine
                                      can be in.

            A compressed page store past a tenth of physical memory is treated as near-critical
            on its own: Windows only compresses to avoid writing to disk, so its size is direct
            evidence rather than an inference.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Position = 0)] [AllowNull()] [System.Nullable[double]] $UsedPercent,
        [Parameter(Position = 1)] [AllowNull()] [System.Nullable[double]] $CommitPercent,
        [Parameter(Position = 2)] [AllowNull()] [System.Nullable[double]] $HardFaultsPerSecond,
        [Parameter(Position = 3)] [double] $AvailableBytes = 0,
        [Parameter(Position = 4)] [double] $CompressedBytes = 0,
        [Parameter(Position = 5)] [double] $TotalBytes = 0
    )

    $score = 0
    if ($null -ne $UsedPercent) { $score = [double] $UsedPercent }
    if ($null -ne $CommitPercent) { $score = [math]::Max($score, [double] $CommitPercent) }
    if ($null -ne $HardFaultsPerSecond -and [double] $HardFaultsPerSecond -gt 50 -and $AvailableBytes -lt 1GB) {
        $score = [math]::Max($score, 95)
    }
    if ($TotalBytes -gt 0 -and $CompressedBytes -gt ($TotalBytes * 0.1)) {
        $score = [math]::Max($score, 88)
    }
    Limit-RmoValue $score 0 100
}

function Get-RmoDiskPressureScore {
    <#
        .SYNOPSIS
            0-100 for how much the storage is holding the machine back.
        .DESCRIPTION
            Latency is the honest measure and utilisation is not. "Disk 100%" in Task Manager
            means the queue was never empty, which on an NVMe device happens during any file copy
            without anybody noticing. Thirty milliseconds per transfer is where a person starts
            to feel it, so that is the point the latency term reaches full scale; utilisation
            only contributes at a discount, and a queue deeper than four outstanding requests
            raises the floor.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Position = 0)] [AllowNull()] [System.Nullable[double]] $BusyPercent,
        [Parameter(Position = 1)] [AllowNull()] [System.Nullable[double]] $LatencyMs,
        [Parameter(Position = 2)] [AllowNull()] [System.Nullable[double]] $QueueLength
    )

    $score = 0
    if ($null -ne $BusyPercent) { $score = (Limit-RmoValue ([double] $BusyPercent) 0 100) * 0.6 }
    if ($null -ne $LatencyMs) {
        $score = [math]::Max($score, (Limit-RmoValue ((([double] $LatencyMs) / 30) * 100) 0 100))
    }
    if ($null -ne $QueueLength -and [double] $QueueLength -gt 4) {
        $score = [math]::Max($score, 80)
    }
    Limit-RmoValue $score 0 100
}
