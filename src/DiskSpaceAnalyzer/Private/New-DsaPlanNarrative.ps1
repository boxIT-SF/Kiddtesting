function New-DsaPlanNarrative {
    <#
        .SYNOPSIS
            Turns the plan numbers into the few sentences a technician actually reads first.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] [psobject] $Plan,
        [Parameter(Mandatory)] [psobject] $Summary,
        [psobject] $Volume
    )

    $lines = New-Object System.Collections.Generic.List[string]

    if (-not $Plan.CapacityKnown) {
        $lines.Add("Free space could not be read for this location, so the figures below describe the scanned data only and no headroom target could be calculated.")
    } else {
        $lines.Add("The volume is $($Volume.PercentUsed) percent full: $($Volume.FreeText) free of $($Volume.CapacityText).")

        if ($null -ne $Plan.HeadroomMonthsBefore) {
            if ($Plan.HeadroomMonthsBefore -lt 0) {
                $lines.Add("At the estimated growth rate of $($Plan.GrowthText) per month it is already below the $($Plan.ReserveText) operating reserve.")
            } else {
                $lines.Add("At the estimated growth rate of $($Plan.GrowthText) per month that is about $($Plan.HeadroomMonthsBefore) months of headroom before it reaches the $($Plan.ReserveText) operating reserve.")
            }
        }

        if ($Plan.DeficitBytes -le 0) {
            $lines.Add("It already has the $($Plan.TargetFreeText) needed to cover $($Plan.HorizonMonths) months of growth plus the reserve, so no cleanup is strictly required. The safe items below are still worth doing to keep it that way.")
        } else {
            $lines.Add("To carry $($Plan.HorizonMonths) months it needs $($Plan.TargetFreeText) free, which is $($Plan.DeficitText) more than it has today.")
        }
    }

    $lines.Add("The scan covered $('{0:N0}' -f $Summary.FileCount) files totalling $($Summary.TotalSizeText), the oldest last written $($Summary.OldestAgeDays) days ago.")

    if ($Summary.OfflineBytes -gt 0) {
        $lines.Add("$($Summary.TotalSizeText) includes $(Format-DsaBytes $Summary.OfflineBytes) of cloud placeholders that report a size but occupy no local disk; they are excluded from everything reclaimable.")
    }

    if ($Plan.DeficitBytes -gt 0) {
        if ($Plan.AchievableWithSafeOnly) {
            $lines.Add("The target is reachable from the Safe items alone - $($Plan.ReclaimableSafeText) of caches, temporary files and superseded data that regenerate on their own. No sign-off needed.")
        } elseif ($Plan.Achievable) {
            $lines.Add("The Safe items yield $($Plan.ReclaimableSafeText), which is not enough on its own, so the plan also draws on items needing sign-off. Total planned: $($Plan.PlannedReclaimText).")
        } else {
            $lines.Add("Everything reclaimable adds up to $($Plan.PlannedReclaimText), which still leaves the volume $($Plan.ShortfallText) short of a $($Plan.HorizonMonths)-month target. Cleanup alone will not solve this - see the escalations below and plan to move data off the volume or grow it.")
        }
    }

    if ($null -ne $Plan.HeadroomMonthsAfter -and $Plan.PlannedReclaimBytes -gt 0) {
        $lines.Add("After the planned work the volume would hold roughly $($Plan.HeadroomMonthsAfter) months of headroom at the current growth rate.")
    }

    $lines.ToArray()
}
