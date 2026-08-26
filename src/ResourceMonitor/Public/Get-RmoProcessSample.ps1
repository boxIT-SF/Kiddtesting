function Get-RmoProcessSample {
    <#
        .SYNOPSIS
            Measures what every process on the machine is actually consuming, and names it.

        .DESCRIPTION
            CPU use cannot be read; it can only be measured. A single snapshot of a process shows
            the total processor time it has used since it started, which on a process that has
            been running for a week says nothing about now. So this takes two or more snapshots
            separated by a real interval and differences them:

                CPU %  =  (processor time used in the interval)
                          / (interval x logical processors)  x  100

            reported the way Task Manager reports it, where 100% is the whole machine rather than
            one core. Disk figures are differenced the same way, from the per-process transfer
            counters.

            Everything comes from Win32_Process, which - unlike Get-Process - carries the command
            line, the parent, the session, and the I/O counters, and does not need a handle on
            each process to read them. Where the performance counter classes are healthy, the
            private working set is read from them as well, because that is the number Task
            Manager shows in its Memory column.

            Every process is then identified: what it is, who publishes it, what normal looks
            like for it, and which services it is hosting.

        .PARAMETER SampleCount
            Snapshots to take. Two gives one measured interval. More gives a mean and a peak,
            which is what separates a process that is genuinely busy from one that was caught
            mid-burst.

        .PARAMETER IntervalMilliseconds
            Gap between snapshots. Below about 500 ms the numbers get noisy, because the
            counters are updated on the scheduler's clock tick.

        .PARAMETER Identifier
            A compiled identifier from New-RmoIdentifier. Built from the shipped catalogue when
            omitted.

        .PARAMETER ServiceMap
            Process-id to services lookup, from New-RmoServiceMap. Without it, svchost and the
            other service hosts cannot be explained.

        .PARAMETER VerifySignature
            Verify Authenticode signatures while identifying. Slower, and the reason a complete
            scan takes longer than a quick one.

        .PARAMETER IncludeOwner
            Look up the account each of the heaviest processes is running as. One CIM method call
            per process, so it is limited to the processes that matter.

        .PARAMETER OwnerLookupCount
            How many of the heaviest processes to look the owner up for.

        .PARAMETER ErrorSink
            Optional list for readings that could not be taken.

        .PARAMETER StatusSink
            Optional dictionary updated with progress, for the UI.

        .PARAMETER CancellationSink
            Optional dictionary polled between snapshots; set 'Cancelled' to stop early.

        .EXAMPLE
            Get-RmoProcessSample | Sort-Object CpuPercent -Descending | Select-Object -First 10

        .EXAMPLE
            Get-RmoProcessSample -SampleCount 4 -IntervalMilliseconds 2000 -VerifySignature
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [ValidateRange(2, 20)] [int] $SampleCount = 2,
        [ValidateRange(200, 60000)] [int] $IntervalMilliseconds = 1500,
        [psobject] $Identifier,
        [hashtable] $ServiceMap,
        [switch] $VerifySignature,
        [switch] $IncludeOwner,
        [ValidateRange(1, 200)] [int] $OwnerLookupCount = 30,
        [System.Collections.IList] $ErrorSink,
        [System.Collections.IDictionary] $StatusSink,
        [System.Collections.IDictionary] $CancellationSink
    )

    if (-not (Test-RmoWindows)) {
        throw 'Process sampling reads Win32_Process, which requires Windows.'
    }
    if ($null -eq $Identifier) {
        $Identifier = New-RmoIdentifier -Entry (Get-RmoProcessCatalogEntry)
    }

    $processorCount = [math]::Max(1, [Environment]::ProcessorCount)
    $properties = @(
        'Handle', 'ProcessId', 'ParentProcessId', 'Name', 'ExecutablePath', 'CommandLine', 'SessionId',
        'CreationDate', 'KernelModeTime', 'UserModeTime', 'WorkingSetSize', 'PeakWorkingSetSize',
        'PrivatePageCount', 'PageFaults', 'HandleCount', 'ThreadCount',
        'ReadTransferCount', 'WriteTransferCount', 'ReadOperationCount', 'WriteOperationCount')

    #region Snapshots
    $snapshots = [System.Collections.Generic.List[object]]::new()
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    for ($index = 0; $index -lt $SampleCount; $index++) {
        if ($index -gt 0) {
            if (Test-RmoCancelled $CancellationSink) { break }
            Start-Sleep -Milliseconds $IntervalMilliseconds
        }

        Set-RmoStatus $StatusSink 'Sampling processes' "Snapshot $($index + 1) of $SampleCount"
        $elapsed = $stopwatch.Elapsed.TotalSeconds
        $instances = Invoke-RmoCim -ClassName 'Win32_Process' -Property $properties -ErrorSink $ErrorSink
        if (@($instances).Count -eq 0) {
            throw 'Win32_Process returned nothing. WMI is unavailable or the repository needs repair; try "winmgmt /verifyrepository".'
        }

        $table = @{}
        foreach ($instance in $instances) {
            $id = [int] (Get-RmoObjectValue $instance 'ProcessId' -1)
            # Process 0 is the idle placeholder, not a consumer. Keeping it would put "Idle" at
            # the top of every CPU table on a healthy machine.
            if ($id -le 0) { continue }
            $table[$id] = $instance
        }
        $snapshots.Add([pscustomobject]@{ Time = $elapsed; Table = $table })
    }
    $stopwatch.Stop()

    if ($snapshots.Count -lt 2) {
        throw 'The scan was cancelled before a second snapshot could be taken, so no rate could be measured.'
    }
    #endregion

    #region Per-interval rates
    # Every process seen in any snapshot gets an entry; rates are averaged over the intervals in
    # which the process was present in both ends, so a program that started mid-scan is reported
    # on the time it was actually running rather than diluted across the whole scan.
    $accumulator = @{}

    for ($index = 1; $index -lt $snapshots.Count; $index++) {
        $previous = $snapshots[$index - 1]
        $current = $snapshots[$index]
        $duration = $current.Time - $previous.Time
        if ($duration -le 0) { continue }

        foreach ($id in $current.Table.Keys) {
            if (-not $previous.Table.ContainsKey($id)) { continue }
            $now = $current.Table[$id]
            $before = $previous.Table[$id]

            # Windows reuses process ids. If the creation time moved, this is a different
            # program wearing the same number, and differencing the two would invent a figure.
            $startNow = Get-RmoObjectValue $now 'CreationDate'
            $startBefore = Get-RmoObjectValue $before 'CreationDate'
            if ($null -ne $startNow -and $null -ne $startBefore -and $startNow -ne $startBefore) { continue }

            $cpuTicks = [double] (Get-RmoObjectValue $now 'KernelModeTime' 0) +
                        [double] (Get-RmoObjectValue $now 'UserModeTime' 0) -
                        [double] (Get-RmoObjectValue $before 'KernelModeTime' 0) -
                        [double] (Get-RmoObjectValue $before 'UserModeTime' 0)
            # 100-nanosecond units, and a counter that appears to have gone backwards is a
            # rollover or a re-created process, not negative CPU use.
            $cpuSeconds = if ($cpuTicks -gt 0) { $cpuTicks / 1e7 } else { 0 }
            $cpuPercent = Limit-RmoValue (($cpuSeconds / ($duration * $processorCount)) * 100) 0 100

            $readDelta = [double] (Get-RmoObjectValue $now 'ReadTransferCount' 0) - [double] (Get-RmoObjectValue $before 'ReadTransferCount' 0)
            $writeDelta = [double] (Get-RmoObjectValue $now 'WriteTransferCount' 0) - [double] (Get-RmoObjectValue $before 'WriteTransferCount' 0)
            $opsDelta = [double] (Get-RmoObjectValue $now 'ReadOperationCount' 0) + [double] (Get-RmoObjectValue $now 'WriteOperationCount' 0) -
                        [double] (Get-RmoObjectValue $before 'ReadOperationCount' 0) - [double] (Get-RmoObjectValue $before 'WriteOperationCount' 0)
            $faultDelta = [double] (Get-RmoObjectValue $now 'PageFaults' 0) - [double] (Get-RmoObjectValue $before 'PageFaults' 0)

            if (-not $accumulator.ContainsKey($id)) {
                $accumulator[$id] = [pscustomobject]@{
                    Intervals   = 0
                    CpuTotal    = [double] 0
                    CpuPeak     = [double] 0
                    ReadTotal   = [double] 0
                    WriteTotal  = [double] 0
                    OpsTotal    = [double] 0
                    FaultTotal  = [double] 0
                    Seconds     = [double] 0
                }
            }
            $entry = $accumulator[$id]
            $entry.Intervals++
            $entry.Seconds += $duration
            $entry.CpuTotal += $cpuPercent * $duration
            if ($cpuPercent -gt $entry.CpuPeak) { $entry.CpuPeak = $cpuPercent }
            if ($readDelta -gt 0) { $entry.ReadTotal += $readDelta }
            if ($writeDelta -gt 0) { $entry.WriteTotal += $writeDelta }
            if ($opsDelta -gt 0) { $entry.OpsTotal += $opsDelta }
            if ($faultDelta -gt 0) { $entry.FaultTotal += $faultDelta }
        }
    }
    #endregion

    #region Private working set from the performance counters
    # Win32_Process reports the whole working set, which includes pages shared with other
    # processes - so adding it up across thirty browser processes counts the same memory
    # thirty times. WorkingSetPrivate is the number Task Manager shows, when the counter
    # class is healthy enough to read.
    $privateWorkingSet = @{}
    $perfInstances = Invoke-RmoCim -ClassName 'Win32_PerfFormattedData_PerfProc_Process' `
        -Property @('IDProcess', 'WorkingSetPrivate') -ErrorSink $ErrorSink
    foreach ($instance in $perfInstances) {
        $id = [int] (Get-RmoObjectValue $instance 'IDProcess' -1)
        if ($id -le 0) { continue }
        $value = Get-RmoObjectValue $instance 'WorkingSetPrivate'
        if ($null -ne $value) { $privateWorkingSet[$id] = [double] $value }
    }
    #endregion

    Set-RmoStatus $StatusSink 'Identifying processes' 'Reading publishers and matching the catalogue'

    $final = $snapshots[$snapshots.Count - 1].Table
    $now = [datetime]::UtcNow
    $results = [System.Collections.Generic.List[object]]::new()

    foreach ($id in $final.Keys) {
        $instance = $final[$id]
        $rawName = [string] (Get-RmoObjectValue $instance 'Name' '')
        $name = if ($rawName -match '^(?<base>.+)\.exe$') { $Matches['base'] } else { $rawName }
        $path = [string] (Get-RmoObjectValue $instance 'ExecutablePath' '')
        $commandLine = [string] (Get-RmoObjectValue $instance 'CommandLine' '')

        $identity = Resolve-RmoProcessIdentity -Name $name -Path $path -Identifier $Identifier `
            -VerifySignature:$VerifySignature.IsPresent -ErrorSink $ErrorSink

        $rates = if ($accumulator.ContainsKey($id)) { $accumulator[$id] } else { $null }
        if ($null -ne $rates -and $rates.Seconds -gt 0) {
            $cpuPercent = $rates.CpuTotal / $rates.Seconds
            $cpuPeak = $rates.CpuPeak
            $readRate = $rates.ReadTotal / $rates.Seconds
            $writeRate = $rates.WriteTotal / $rates.Seconds
            $opsRate = $rates.OpsTotal / $rates.Seconds
            $faultRate = $rates.FaultTotal / $rates.Seconds
            $measured = $true
        } else {
            # Started during the scan, or exited and its id was reused. It has a size but no
            # measured rate, and saying 0% would be a claim the scan cannot support.
            $cpuPercent = $null
            $cpuPeak = $null
            $readRate = $null
            $writeRate = $null
            $opsRate = $null
            $faultRate = $null
            $measured = $false
        }

        $workingSet = [double] (Get-RmoObjectValue $instance 'WorkingSetSize' 0)
        $private = [double] (Get-RmoObjectValue $instance 'PrivatePageCount' 0)
        $privateWs = if ($privateWorkingSet.ContainsKey($id)) { $privateWorkingSet[$id] } else { $null }

        $started = Get-RmoObjectValue $instance 'CreationDate'
        $ageSeconds = $null
        if ($null -ne $started) {
            try { $ageSeconds = ($now - $started.ToUniversalTime()).TotalSeconds } catch { $ageSeconds = $null }
        }

        $services = @()
        if ($null -ne $ServiceMap -and $ServiceMap.ContainsKey([int] $id)) {
            $services = @($ServiceMap[[int] $id])
        }

        # svchost -k <group> names the service group even when the service map is unavailable.
        $serviceGroup = ''
        if ($commandLine -match '-k\s+(?<group>[\w\.-]+)') { $serviceGroup = $Matches['group'] }

        $results.Add([pscustomobject]@{
            PSTypeName              = 'Rmo.ProcessSample'
            ProcessId               = [int] $id
            ParentProcessId         = [int] (Get-RmoObjectValue $instance 'ParentProcessId' 0)
            ParentName              = ''
            Name                    = $name
            ImageName               = $rawName
            ExecutablePath          = $path
            CommandLine             = $commandLine
            SessionId               = [int] (Get-RmoObjectValue $instance 'SessionId' 0)
            Owner                   = ''
            StartedUtc              = $started
            AgeSeconds              = $ageSeconds
            Measured                = $measured
            CpuPercent              = $cpuPercent
            CpuPeakPercent          = $cpuPeak
            WorkingSetBytes         = $workingSet
            PrivateBytes            = $private
            PrivateWorkingSetBytes  = $privateWs
            PeakWorkingSetBytes     = ([double] (Get-RmoObjectValue $instance 'PeakWorkingSetSize' 0)) * 1024
            ReadBytesPerSecond      = $readRate
            WriteBytesPerSecond     = $writeRate
            IoBytesPerSecond        = $(if ($measured) { $readRate + $writeRate } else { $null })
            IoOperationsPerSecond   = $opsRate
            PageFaultsPerSecond     = $faultRate
            HandleCount             = [int] (Get-RmoObjectValue $instance 'HandleCount' 0)
            ThreadCount             = [int] (Get-RmoObjectValue $instance 'ThreadCount' 0)
            Services                = $services
            ServiceGroup            = $serviceGroup
            Identity                = $identity
            CimInstance             = $instance
        })
    }

    #region Parent names and owners
    $byId = @{}
    foreach ($item in $results) { $byId[$item.ProcessId] = $item }
    foreach ($item in $results) {
        if ($item.ParentProcessId -gt 0 -and $byId.ContainsKey($item.ParentProcessId)) {
            # Only trust the parent if it started before the child; otherwise the parent has
            # exited and its id has been handed to something unrelated.
            $parent = $byId[$item.ParentProcessId]
            if ($null -eq $item.StartedUtc -or $null -eq $parent.StartedUtc -or $parent.StartedUtc -le $item.StartedUtc) {
                $item.ParentName = $parent.Name
            }
        }
    }

    if ($IncludeOwner) {
        Set-RmoStatus $StatusSink 'Resolving process owners' ''
        $ranked = @($results |
            Sort-Object -Property @{ Expression = {
                $cpu = if ($null -ne $_.CpuPercent) { $_.CpuPercent } else { 0 }
                $cpu * 100 + ($_.WorkingSetBytes / 1GB)
            } } -Descending |
            Select-Object -First $OwnerLookupCount)

        foreach ($item in $ranked) {
            try {
                $owner = Invoke-CimMethod -InputObject $item.CimInstance -MethodName GetOwner -ErrorAction Stop
                if ($owner -and $owner.ReturnValue -eq 0 -and $owner.User) {
                    $item.Owner = if ($owner.Domain) { "$($owner.Domain)\$($owner.User)" } else { [string] $owner.User }
                }
            } catch {
                Write-Verbose "Could not read the owner of process $($item.ProcessId): $($_.Exception.Message)"
            }
        }
    }
    #endregion

    # Responding and the window title only come from the .NET view of a process, and both are
    # worth having: a process with a window that is not responding is exactly what the person
    # using the machine is complaining about.
    try {
        foreach ($process in Get-Process -ErrorAction Stop) {
            if (-not $byId.ContainsKey($process.Id)) { continue }
            $item = $byId[$process.Id]
            try {
                $item | Add-Member -NotePropertyName Responding -NotePropertyValue ([bool] $process.Responding) -Force
                $item | Add-Member -NotePropertyName MainWindowTitle -NotePropertyValue ([string] $process.MainWindowTitle) -Force
            } catch {
                Write-Verbose "Could not read window state for process $($process.Id): $($_.Exception.Message)"
            }
        }
    } catch {
        Write-Verbose "Get-Process was unavailable: $($_.Exception.Message)"
    }
    foreach ($item in $results) {
        if (-not $item.PSObject.Properties['Responding']) {
            $item | Add-Member -NotePropertyName Responding -NotePropertyValue $true -Force
        }
        if (-not $item.PSObject.Properties['MainWindowTitle']) {
            $item | Add-Member -NotePropertyName MainWindowTitle -NotePropertyValue '' -Force
        }
    }

    @($results)
}
