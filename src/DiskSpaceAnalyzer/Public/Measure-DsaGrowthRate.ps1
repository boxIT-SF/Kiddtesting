function Measure-DsaGrowthRate {
    <#
        .SYNOPSIS
            Estimates how fast the scanned data is growing, in bytes per month.

        .DESCRIPTION
            Buckets the scanned files by creation month and takes the median of the most recent
            complete months. The median rather than the mean, because one month containing a
            server migration or a software rollout would otherwise dominate the forecast.

            What this measures, and what it does not:

              * It measures data *arriving*: files created in each month that still exist.
              * It does not see files that were created and later deleted, so it understates
                churn, and it does not see existing files that grow in place - databases,
                virtual disks and append-only logs are the common cases.
              * Creation timestamps are rewritten when data is copied (rather than moved)
                between volumes, so a recent bulk copy inflates the most recent months.

            Because of that this is a planning estimate, not a measurement. Where a real
            trend line exists - RMM disk-space history, a monitoring system - pass it in with
            -KnownBytesPerMonth instead.

        .PARAMETER Summary
            The output of Measure-DsaInventory.

        .PARAMETER LookbackMonths
            How many complete months to consider. Defaults to 12.

        .PARAMETER MinimumMonths
            Below this many months of usable data the estimate is flagged Low confidence and
            falls back to averaging the whole scan over the age of its data.

        .PARAMETER KnownBytesPerMonth
            An externally measured growth rate. When supplied it is used verbatim and reported
            with High confidence.

        .EXAMPLE
            $summary | Measure-DsaGrowthRate -LookbackMonths 6
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)]
        [psobject] $Summary,

        [int] $LookbackMonths = 12,

        [int] $MinimumMonths = 3,

        [Nullable[double]] $KnownBytesPerMonth
    )

    process {
        $reference = [datetime] $Summary.ReferenceTime
        $currentMonthKey = $reference.ToString('yyyy-MM')

        if ($null -ne $KnownBytesPerMonth) {
            return [pscustomobject]@{
                PSTypeName     = 'Dsa.GrowthRate'
                BytesPerMonth  = [double] $KnownBytesPerMonth
                RateText       = Format-DsaBytes ([double] $KnownBytesPerMonth)
                MedianBytes    = [double] $KnownBytesPerMonth
                MeanBytes      = [double] $KnownBytesPerMonth
                PeakBytes      = [double] $KnownBytesPerMonth
                SampleMonths   = 0
                Method         = 'Supplied by caller'
                Confidence     = 'High'
                Caveats        = @('Rate was supplied externally rather than derived from file timestamps.')
                Series         = @()
            }
        }

        # The current month is always partial, so including it drags the estimate down.
        $complete = @($Summary.CreatedByMonth | Where-Object { $_.Month -lt $currentMonthKey })
        $window = @($complete | Sort-Object Month | Select-Object -Last $LookbackMonths)

        $caveats = New-Object System.Collections.Generic.List[string]
        $caveats.Add('Based on files created per month that still exist; deleted files and files that grow in place (databases, virtual disks, append-only logs) are not visible to this method.')

        if ($window.Count -lt $MinimumMonths) {
            # Not enough monthly detail: spread everything scanned over the age of the data.
            $spanDays = if ($null -ne $Summary.OldestAgeDays -and $Summary.OldestAgeDays -gt 0) { [double] $Summary.OldestAgeDays } else { 30.0 }
            $spanMonths = [math]::Max(1.0, $spanDays / 30.44)
            $rate = [double] $Summary.TotalBytes / $spanMonths
            $caveats.Add("Only $($window.Count) complete month(s) of creation data were found, so the rate is the whole scan averaged over $([math]::Round($spanMonths,1)) months. Treat it as an order of magnitude only.")

            return [pscustomobject]@{
                PSTypeName    = 'Dsa.GrowthRate'
                BytesPerMonth = $rate
                RateText      = Format-DsaBytes $rate
                MedianBytes   = $rate
                MeanBytes     = $rate
                PeakBytes     = $rate
                SampleMonths  = $window.Count
                Method        = 'Whole-scan average (insufficient monthly detail)'
                Confidence    = 'Low'
                Caveats       = $caveats.ToArray()
                Series        = $window
            }
        }

        $values = @($window | ForEach-Object { [double] $_.Bytes } | Sort-Object)
        $middle = [int] [math]::Floor($values.Count / 2)
        $median = if ($values.Count % 2 -eq 1) { $values[$middle] } else { ($values[$middle - 1] + $values[$middle]) / 2 }

        $sum = 0.0
        foreach ($value in $values) { $sum += $value }
        $mean = $sum / $values.Count
        $peak = $values[$values.Count - 1]

        $confidence = if ($window.Count -ge 6) { 'Medium' } else { 'Low' }
        if ($window.Count -ge 6 -and $peak -le ($median * 4)) { $confidence = 'High' }
        if ($peak -gt ($median * 4)) {
            $caveats.Add("Monthly volumes are uneven - the busiest month in the window was $(Format-DsaBytes $peak) against a median of $(Format-DsaBytes $median). A single migration or rollout can produce this.")
        }

        [pscustomobject]@{
            PSTypeName    = 'Dsa.GrowthRate'
            BytesPerMonth = $median
            RateText      = Format-DsaBytes $median
            MedianBytes   = $median
            MeanBytes     = $mean
            PeakBytes     = $peak
            SampleMonths  = $window.Count
            Method        = "Median of the last $($window.Count) complete months of file creation"
            Confidence    = $confidence
            Caveats       = $caveats.ToArray()
            Series        = $window
        }
    }
}
