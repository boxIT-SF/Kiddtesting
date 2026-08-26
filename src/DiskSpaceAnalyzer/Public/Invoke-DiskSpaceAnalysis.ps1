function Invoke-DiskSpaceAnalysis {
    <#
        .SYNOPSIS
            Scans a volume or folder tree and returns the complete analysis: what the data is,
            how old it is, what is safe to delete, what to do about what is not, and a plan
            sized to keep the volume healthy for a chosen number of months.

        .DESCRIPTION
            This is the one call that ties the module together. It:

              1. reads the volume's capacity and free space;
              2. walks the tree, streaming file records so memory stays flat;
              3. classifies every file against the rule set;
              4. probes the system for space a file walk cannot see (hibernation file, shadow
                 copy allocation, component store, stale profiles);
              5. estimates the growth rate;
              6. builds the reclamation plan.

            The result object feeds Export-DsaReport, New-DsaRemediationScript and the UI.

        .PARAMETER Path
            One or more roots to analyse. Defaults to the system drive.

        .PARAMETER HorizonMonths
            Months of headroom the plan must deliver. Defaults to 6.

        .PARAMETER MinFileSizeBytes
            Ignore files smaller than this. Raising it to 1MB makes a scan of a large volume
            several times faster while barely changing the reclaimable totals.

        .PARAMETER TopCount
            Rows to keep in each "largest" table.

        .PARAMETER OldestCount
            Rows to keep in the oldest-data table.

        .PARAMETER OldestMinSizeBytes
            Minimum size for a file to qualify for the oldest-data table.

        .PARAMETER ExcludePattern
            Regular expressions matched against directory paths; matches are skipped entirely.

        .PARAMETER MaxDepth
            Limit the walk to this many directory levels below each root. 0 means unlimited.

        .PARAMETER DirectoryDepth
            How many levels below each root the "where the space went" table rolls up to.

        .PARAMETER DeepSystemProbe
            Also run DISM component store analysis. Accurate, slow, needs elevation.

        .PARAMETER KnownGrowthBytesPerMonth
            A growth rate measured elsewhere (RMM history, monitoring). Overrides the estimate.

        .PARAMETER RuleFile
            Additional classification rule files to overlay on the shipped set.

        .PARAMETER SafetyFactor
            Multiplier applied to projected growth when sizing the target. Defaults to 1.25.

        .PARAMETER MinimumFreePercent
            Operating reserve as a percentage of capacity. Defaults to 15.

        .PARAMETER MinimumFreeBytes
            Floor for the operating reserve. Defaults to 10 GB.

        .PARAMETER FollowReparsePoint
            Follow junctions and symlinks. Off by default; following them double counts data.

        .PARAMETER StatusSink
            Dictionary updated with live scan progress. Use a synchronized one when calling
            from a background runspace, as the UI does.

        .PARAMETER CancellationSink
            Dictionary polled during the scan; set 'Cancelled' to stop it early.

        .PARAMETER Quiet
            Suppress the progress bar.

        .EXAMPLE
            Invoke-DiskSpaceAnalysis -Path C:\ -HorizonMonths 6

        .EXAMPLE
            Invoke-DiskSpaceAnalysis -Path D:\ -MinFileSizeBytes 1MB -DeepSystemProbe |
                Export-DsaReport -Path .\D-drive.html
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Position = 0)] [string[]] $Path,

        [ValidateRange(1, 120)] [int] $HorizonMonths = 6,
        [long] $MinFileSizeBytes = 0,
        [int] $TopCount = 25,
        [int] $OldestCount = 25,
        [long] $OldestMinSizeBytes = 1MB,
        [string[]] $ExcludePattern,
        [int] $MaxDepth = 0,
        [int] $DirectoryDepth = 2,
        [switch] $DeepSystemProbe,
        [Nullable[double]] $KnownGrowthBytesPerMonth,
        [string[]] $RuleFile,
        [ValidateRange(1.0, 5.0)] [double] $SafetyFactor = 1.25,
        [ValidateRange(0, 90)] [double] $MinimumFreePercent = 15,
        [long] $MinimumFreeBytes = 10GB,
        [switch] $FollowReparsePoint,
        [System.Collections.IDictionary] $StatusSink,
        [System.Collections.IDictionary] $CancellationSink,
        [switch] $Quiet
    )

    if (-not $Path -or $Path.Count -eq 0) {
        $Path = @(if ((Test-DsaWindows) -and $env:SystemDrive) { "$env:SystemDrive\" } else { '/' })
    }

    # A typo in the path must fail loudly. Without this the scan finds nothing, the plan is
    # built from an empty inventory, and the result reads as "this volume needs more capacity".
    $missing = @($Path | Where-Object { -not (Test-Path -LiteralPath $_) })
    if ($missing.Count -eq $Path.Count) {
        throw "None of the requested paths exist: $($missing -join ', ')"
    }
    if ($missing.Count -gt 0) {
        Write-Warning "Skipping paths that do not exist: $($missing -join ', ')"
        $Path = @($Path | Where-Object { $_ -notin $missing })
    }

    $started = [datetime]::UtcNow
    $reference = $started

    $rules = if ($RuleFile) { Get-DsaClassificationRule -Path $RuleFile -Force } else { Get-DsaClassificationRule }
    $classifier = New-DsaClassifier -Rule $rules

    $volume = Get-DsaVolumeInfo -Path $Path[0]

    $scanErrors = New-Object System.Collections.ArrayList
    if ($null -eq $StatusSink) { $StatusSink = @{} }
    $StatusSink['Phase'] = 'Scanning'
    $StatusSink['Complete'] = $false

    Write-Verbose "Scanning $($Path -join ', ')"

    $inventoryArgs = @{
        Path             = $Path
        MinFileSizeBytes = $MinFileSizeBytes
        MaxDepth         = $MaxDepth
        ReferenceTime    = $reference
        ErrorSink        = $scanErrors
        StatusSink       = $StatusSink
    }
    if ($ExcludePattern) { $inventoryArgs['ExcludePattern'] = $ExcludePattern }
    if ($FollowReparsePoint) { $inventoryArgs['FollowReparsePoint'] = $true }
    if ($null -ne $CancellationSink) { $inventoryArgs['CancellationSink'] = $CancellationSink }

    # Progress is emitted from the pipeline rather than from inside the enumerator, so that
    # the cost of updating it is paid once per few thousand files instead of once per file.
    $progressCounter = 0
    $summary = Get-DsaFileInventory @inventoryArgs |
        ForEach-Object {
            $progressCounter++
            if (-not $Quiet -and ($progressCounter % 5000) -eq 0) {
                Write-Progress -Activity 'Analysing disk usage' `
                    -Status "$('{0:N0}' -f $progressCounter) files, $(Format-DsaBytes $StatusSink['BytesScanned'])" `
                    -CurrentOperation ([string] $StatusSink['CurrentPath'])
            }
            $_
        } |
        Measure-DsaInventory -Classifier $classifier -TopCount $TopCount -OldestCount $OldestCount `
            -OldestMinSizeBytes $OldestMinSizeBytes -RootPath $Path -DirectoryDepth $DirectoryDepth `
            -ReferenceTime $reference

    if (-not $Quiet) { Write-Progress -Activity 'Analysing disk usage' -Completed }

    $StatusSink['Phase'] = 'Probing system'
    $probeArgs = @{ Path = $Path[0] }
    if ($DeepSystemProbe) { $probeArgs['Deep'] = $true }
    $opportunities = @(Get-DsaSystemReclaimOpportunity @probeArgs)

    $StatusSink['Phase'] = 'Estimating growth'
    $growthArgs = @{ Summary = $summary }
    if ($null -ne $KnownGrowthBytesPerMonth) { $growthArgs['KnownBytesPerMonth'] = $KnownGrowthBytesPerMonth }
    $growth = Measure-DsaGrowthRate @growthArgs

    $StatusSink['Phase'] = 'Building plan'
    $plan = New-DsaSpacePlan -Summary $summary -Volume $volume -Growth $growth `
        -SystemOpportunity $opportunities -HorizonMonths $HorizonMonths -SafetyFactor $SafetyFactor `
        -MinimumFreePercent $MinimumFreePercent -MinimumFreeBytes $MinimumFreeBytes

    $finished = [datetime]::UtcNow
    $StatusSink['Phase'] = 'Complete'
    $StatusSink['Complete'] = $true

    $cancelled = ($null -ne $CancellationSink -and $CancellationSink['Cancelled'])

    [pscustomobject]@{
        PSTypeName          = 'Dsa.AnalysisResult'
        ComputerName        = [System.Environment]::MachineName
        Path                = $Path
        ScanStartedUtc      = $started
        ScanFinishedUtc     = $finished
        DurationSeconds     = [math]::Round(($finished - $started).TotalSeconds, 1)
        Elevated            = Test-DsaElevated
        Cancelled           = [bool] $cancelled
        Volume              = $volume
        Summary             = $summary
        Growth              = $growth
        SystemOpportunities = $opportunities
        Plan                = $plan
        ScanErrors          = @($scanErrors)
        Parameters          = [pscustomobject]@{
            HorizonMonths      = $HorizonMonths
            MinFileSizeBytes   = $MinFileSizeBytes
            OldestMinSizeBytes = $OldestMinSizeBytes
            MaxDepth           = $MaxDepth
            DirectoryDepth     = $DirectoryDepth
            ExcludePattern     = $ExcludePattern
            SafetyFactor       = $SafetyFactor
            MinimumFreePercent = $MinimumFreePercent
            MinimumFreeBytes   = $MinimumFreeBytes
            DeepSystemProbe    = [bool] $DeepSystemProbe
            FollowReparsePoint = [bool] $FollowReparsePoint
            RuleFile           = $RuleFile
        }
    }
}
