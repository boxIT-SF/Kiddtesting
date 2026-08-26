function Invoke-ResourceAnalysis {
    <#
        .SYNOPSIS
            Scans the machine, works out why it is slow, and returns a plan for making it usable.

        .DESCRIPTION
            The one call that ties the module together. In order, it:

              1. loads the catalogue that names processes and their publishers;
              2. describes the machine - processor, memory, disks, graphics, power, antivirus;
              3. maps running services to the processes hosting them, so svchost means something;
              4. samples every process over a real interval to measure CPU, memory and disk;
              5. ranks the consumers, individually and grouped by product;
              6. measures pressure on CPU, memory, disk and network and decides which of them is
                 the constraint;
              7. lists what starts itself, and what that is costing right now;
              8. checks the things that slow a machine without appearing in any process list;
              9. builds an ordered plan.

            Two modes:

              Quick     one measured interval of about 1.5 seconds, publishers from file version
                        information, Run keys and startup folders. Around five to fifteen
                        seconds in total. Enough to answer "what is it doing right now".
              Complete  four intervals over about ten seconds, Authenticode signatures verified,
                        scheduled tasks, process owners, per-disk and GPU counters, and crash,
                        hang and shutdown history from the event log. A minute or two, and the
                        mode that finds intermittent and reliability problems.

            Nothing is changed. The result feeds Export-RmoReport, New-RmoRemediationScript and
            the UI.

        .PARAMETER ScanMode
            Quick or Complete. Defaults to Quick.

        .PARAMETER SampleCount
            Override the number of snapshots for the chosen mode.

        .PARAMETER IntervalMilliseconds
            Override the gap between snapshots for the chosen mode.

        .PARAMETER TopCount
            Rows to keep in each ranking table.

        .PARAMETER CatalogFile
            Additional catalogue files, so site-specific software is named and attributed
            properly instead of appearing as a filename.

        .PARAMETER HistoryDays
            How far back the complete scan looks for crashes, hangs and unexpected shutdowns.

        .PARAMETER StatusSink
            Dictionary updated with live progress. Use a synchronized one when calling from a
            background runspace, as the UI does.

        .PARAMETER CancellationSink
            Dictionary polled during the scan; set 'Cancelled' to stop it early.

        .PARAMETER Quiet
            Suppress the progress bar.

        .EXAMPLE
            Invoke-ResourceAnalysis

        .EXAMPLE
            Invoke-ResourceAnalysis -ScanMode Complete | Export-RmoReport -Path .\report.html

        .EXAMPLE
            $result = Invoke-ResourceAnalysis -ScanMode Complete
            $result.Plan.Actions | Where-Object Impact -eq 'High' | Format-List Title, Recommendation
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Position = 0)] [ValidateSet('Quick', 'Complete')] [string] $ScanMode = 'Quick',
        [ValidateRange(2, 20)] [int] $SampleCount,
        [ValidateRange(200, 60000)] [int] $IntervalMilliseconds,
        [ValidateRange(1, 500)] [int] $TopCount = 15,
        [string[]] $CatalogFile,
        [ValidateRange(1, 90)] [int] $HistoryDays = 14,
        [System.Collections.IDictionary] $StatusSink,
        [System.Collections.IDictionary] $CancellationSink,
        [switch] $Quiet
    )

    if (-not (Test-RmoWindows)) {
        throw 'ResourceMonitor reads Windows process, performance and configuration data, so it requires Windows.'
    }

    $complete = ($ScanMode -eq 'Complete')
    if (-not $PSBoundParameters.ContainsKey('SampleCount')) {
        $SampleCount = if ($complete) { 4 } else { 2 }
    }
    if (-not $PSBoundParameters.ContainsKey('IntervalMilliseconds')) {
        $IntervalMilliseconds = if ($complete) { 2500 } else { 1500 }
    }

    $started = [datetime]::UtcNow
    $scanErrors = [System.Collections.ArrayList]::new()
    if ($null -eq $StatusSink) { $StatusSink = @{} }
    $StatusSink['Complete'] = $false

    # The phases are weighted roughly by how long each takes, so the progress bar moves at
    # something like a constant rate rather than sitting at 20% for the whole sampling window.
    $phases = @(
        [pscustomobject]@{ Name = 'Loading the process catalogue'; Weight = 3 }
        [pscustomobject]@{ Name = 'Reading the machine'; Weight = 12 }
        [pscustomobject]@{ Name = 'Mapping services to processes'; Weight = 5 }
        [pscustomobject]@{ Name = 'Sampling processes'; Weight = 45 }
        [pscustomobject]@{ Name = 'Ranking consumers'; Weight = 5 }
        [pscustomobject]@{ Name = 'Measuring resource pressure'; Weight = 8 }
        [pscustomobject]@{ Name = 'Reading startup entries'; Weight = 10 }
        [pscustomobject]@{ Name = 'Checking the machine'; Weight = 10 }
        [pscustomobject]@{ Name = 'Building the plan'; Weight = 2 }
    )
    $totalWeight = 0
    foreach ($phase in $phases) { $totalWeight += $phase.Weight }
    $done = 0

    function Step-Phase {
        param([int] $Index)
        $phase = $phases[$Index]
        Set-RmoStatus $StatusSink $phase.Name ''
        if (-not $Quiet) {
            Write-Progress -Activity "Resource scan ($ScanMode)" -Status $phase.Name `
                -PercentComplete ([int] (($done / $totalWeight) * 100))
        }
        Write-Verbose $phase.Name
        $phase.Weight
    }

    #region 1. Catalogue
    $done += Step-Phase 0
    $catalogArgs = @{}
    if ($CatalogFile) { $catalogArgs['Path'] = $CatalogFile; $catalogArgs['Force'] = $true }
    $catalog = Get-RmoProcessCatalogEntry @catalogArgs
    $identifier = New-RmoIdentifier -Entry $catalog
    foreach ($collision in $identifier.Collisions) { $null = $scanErrors.Add($collision) }
    #endregion

    #region 2. The machine
    $done += Step-Phase 1
    $system = Get-RmoSystemSnapshot -ErrorSink $scanErrors
    #endregion

    #region 3. Services
    $done += Step-Phase 2
    $services = Get-RmoServiceLoad -ErrorSink $scanErrors
    $serviceMap = New-RmoServiceMap -Service $services
    #endregion

    #region 4. Processes - the part that takes the time
    $done += Step-Phase 3
    $processes = Get-RmoProcessSample -SampleCount $SampleCount -IntervalMilliseconds $IntervalMilliseconds `
        -Identifier $identifier -ServiceMap $serviceMap -VerifySignature:$complete -IncludeOwner:$complete `
        -ErrorSink $scanErrors -StatusSink $StatusSink -CancellationSink $CancellationSink
    #endregion

    #region 5. Rankings
    $done += Step-Phase 4
    $hogs = Get-RmoResourceHog -Process $processes -TopCount $TopCount -SystemMemoryBytes $system.Memory.TotalBytes
    #endregion

    #region 6. Pressure and the bottleneck
    $done += Step-Phase 5
    $pressure = Measure-RmoResourcePressure -System $system -Process $processes -Deep:$complete -ErrorSink $scanErrors
    #endregion

    #region 7. Startup
    $done += Step-Phase 6
    $startupItems = @()
    if (-not (Test-RmoCancelled $CancellationSink)) {
        $startupItems = Get-RmoStartupItem -Process $hogs.Processes -Identifier $identifier `
            -IncludeScheduledTasks:$complete -VerifySignature:$complete -ErrorSink $scanErrors
    }
    #endregion

    #region 8. The things that do not appear in a process list
    $done += Step-Phase 7
    $findings = @()
    if (-not (Test-RmoCancelled $CancellationSink)) {
        $findings = Get-RmoSystemHealthCheck -System $system -Pressure $pressure -StartupItem $startupItems `
            -Service $services -Deep:$complete -HistoryDays $HistoryDays -ErrorSink $scanErrors
    }
    #endregion

    #region 9. The plan
    $done += Step-Phase 8
    $plan = New-RmoRemediationPlan -System $system -Pressure $pressure -Hogs $hogs `
        -StartupItem $startupItems -Finding $findings -ScanMode $ScanMode
    #endregion

    if (-not $Quiet) { Write-Progress -Activity "Resource scan ($ScanMode)" -Completed }

    $finished = [datetime]::UtcNow
    Set-RmoStatus $StatusSink 'Complete' ''
    $StatusSink['Complete'] = $true

    [pscustomobject]@{
        PSTypeName      = 'Rmo.AnalysisResult'
        ScanMode        = $ScanMode
        ComputerName    = $system.ComputerName
        ScanStartedUtc  = $started
        ScanFinishedUtc = $finished
        DurationSeconds = [math]::Round(($finished - $started).TotalSeconds, 1)
        Elevated        = Test-RmoElevated
        Cancelled       = [bool] (Test-RmoCancelled $CancellationSink)
        SampleCount     = $SampleCount
        System          = $system
        Pressure        = $pressure
        Hogs            = $hogs
        Services        = $services
        StartupItems    = @($startupItems)
        Findings        = @($findings)
        Plan            = $plan
        CatalogEntryCount = @($catalog).Count
        ScanErrors      = @($scanErrors)
        Parameters      = [pscustomobject]@{
            ScanMode             = $ScanMode
            SampleCount          = $SampleCount
            IntervalMilliseconds = $IntervalMilliseconds
            TopCount             = $TopCount
            HistoryDays          = $HistoryDays
            CatalogFile          = $CatalogFile
        }
    }
}
