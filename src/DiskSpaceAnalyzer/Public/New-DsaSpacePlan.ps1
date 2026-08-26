function New-DsaSpacePlan {
    <#
        .SYNOPSIS
            Works out how much space has to be freed to keep a volume healthy for a given
            number of months, and picks the actions that get there safest-first.

        .DESCRIPTION
            The target is built from three parts:

              projected growth   the estimated growth rate over the horizon, multiplied by a
                                 safety factor so a slightly wrong estimate does not blow the plan
              operating reserve  free space the volume should never dip below, so it does not
                                 hit the wall on the last day of the horizon
              current free       what is already available

            Actions are then taken in safety order - everything classed Safe first, then the
            items needing sign-off - until the deficit is covered. Nothing classed Unsafe is
            ever counted toward the target; those are reported separately as escalations with
            the supported way to shrink them.

            The plan also lists preventive controls, because a one-off cleanup that is not
            followed by a retention policy simply refills over the horizon.

        .PARAMETER Summary
            Output of Measure-DsaInventory.

        .PARAMETER Volume
            Output of Get-DsaVolumeInfo. Without it the plan can only reason about scanned
            data, not about free space.

        .PARAMETER Growth
            Output of Measure-DsaGrowthRate.

        .PARAMETER SystemOpportunity
            Output of Get-DsaSystemReclaimOpportunity.

        .PARAMETER HorizonMonths
            How many months of headroom the plan must deliver. Defaults to 6.

        .PARAMETER SafetyFactor
            Multiplier applied to projected growth. Defaults to 1.25.

        .PARAMETER MinimumFreePercent
            Operating reserve as a percentage of volume capacity. Defaults to 15.

        .PARAMETER MinimumFreeBytes
            Floor for the operating reserve regardless of capacity. Defaults to 10 GB.

        .PARAMETER MaximumReservePercent
            Ceiling for the operating reserve, so the floor cannot demand an absurd share of a
            small volume. Defaults to 25.

        .EXAMPLE
            New-DsaSpacePlan -Summary $summary -Volume $volume -Growth $growth -HorizonMonths 6
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory)] [psobject] $Summary,
        [psobject] $Volume,
        [psobject] $Growth,
        [psobject[]] $SystemOpportunity = @(),

        [ValidateRange(1, 120)] [int] $HorizonMonths = 6,
        [ValidateRange(1.0, 5.0)] [double] $SafetyFactor = 1.25,
        [ValidateRange(0, 90)] [double] $MinimumFreePercent = 15,
        [long] $MinimumFreeBytes = 10GB,
        [ValidateRange(1, 90)] [double] $MaximumReservePercent = 25
    )

    $assumptions = New-Object System.Collections.Generic.List[string]

    $capacity = if ($Volume) { $Volume.CapacityBytes } else { $null }
    $free = if ($Volume) { $Volume.FreeBytes } else { $null }
    $capacityKnown = ($null -ne $capacity -and $capacity -gt 0 -and $null -ne $free)

    $growthPerMonth = 0.0
    if ($Growth) { $growthPerMonth = [double] $Growth.BytesPerMonth }

    $projectedGrowth = [long] [math]::Round($growthPerMonth * $HorizonMonths * $SafetyFactor)

    if ($capacityKnown) {
        $percentReserve = [long] ($capacity * $MinimumFreePercent / 100)
        $reserve = [math]::Max($percentReserve, $MinimumFreeBytes)
        $reserveCap = [long] ($capacity * $MaximumReservePercent / 100)
        if ($reserve -gt $reserveCap) {
            $reserve = $reserveCap
            $assumptions.Add("Operating reserve was capped at $MaximumReservePercent percent of capacity ($(Format-DsaBytes $reserve)); the $(Format-DsaBytes $MinimumFreeBytes) floor would have been disproportionate on a volume this size.")
        }
        $assumptions.Add("Operating reserve of $(Format-DsaBytes $reserve) - the level the volume should not drop below at the end of the horizon - taken as the greater of $MinimumFreePercent percent of capacity and $(Format-DsaBytes $MinimumFreeBytes).")
    } else {
        $reserve = $MinimumFreeBytes
        $assumptions.Add('Volume capacity and free space were not available, so the plan sizes the work from scanned data only. Re-run against a local volume for a complete picture.')
    }

    $targetFree = [long] ($projectedGrowth + $reserve)
    $currentFree = if ($capacityKnown) { [long] $free } else { 0L }
    $deficit = [math]::Max(0L, $targetFree - $currentFree)

    $assumptions.Add("Growth is projected at $(Format-DsaBytes $growthPerMonth) per month over $HorizonMonths months, with a $SafetyFactor x safety factor, giving $(Format-DsaBytes $projectedGrowth) of expected new data.")
    if ($Growth) {
        $assumptions.Add("Growth estimate confidence: $($Growth.Confidence). Method: $($Growth.Method).")
        foreach ($caveat in $Growth.Caveats) { $assumptions.Add($caveat) }
    }

    #region Build candidate actions
    $candidates = New-Object System.Collections.Generic.List[psobject]
    $escalations = New-Object System.Collections.Generic.List[psobject]

    $systemIds = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($opportunity in $SystemOpportunity) {
        if (-not $opportunity.Available) { continue }
        $null = $systemIds.Add($opportunity.Id)
    }

    foreach ($opportunity in $SystemOpportunity) {
        $action = [pscustomobject]@{
            PSTypeName        = 'Dsa.PlanAction'
            Id                = $opportunity.Id
            Title             = $opportunity.Name
            Category          = $opportunity.Category
            Safety            = $opportunity.Safety
            SafetyRank        = $opportunity.SafetyRank
            SizeBytes         = if ($null -ne $opportunity.SizeBytes) { [long] $opportunity.SizeBytes } else { 0L }
            SizeText          = $opportunity.SizeText
            FileCount         = $null
            WhatItIs          = $opportunity.WhatItIs
            Reason            = $opportunity.Reason
            Remediation       = $opportunity.Remediation
            Command           = $opportunity.Command
            Method            = $opportunity.Method
            RequiresReboot    = $opportunity.RequiresReboot
            RequiresApproval  = ($opportunity.Safety -ne 'Safe')
            Confidence        = $opportunity.Confidence
            Source            = 'System probe'
            Available         = $opportunity.Available
            Unavailable       = $opportunity.Unavailable
            Examples          = @()
            Selected          = $false
        }

        if ($opportunity.Safety -eq 'Unsafe') { $escalations.Add($action) }
        elseif ($opportunity.Available -and $action.SizeBytes -gt 0) { $candidates.Add($action) }
        else { $escalations.Add($action) }
    }

    foreach ($category in $Summary.Categories) {
        # A system probe measures the same thing more accurately than a directory walk can.
        if ($systemIds.Contains($category.Id)) { continue }

        $action = [pscustomobject]@{
            PSTypeName        = 'Dsa.PlanAction'
            Id                = $category.Id
            Title             = $category.Name
            Category          = $category.Category
            Safety            = $category.Safety
            SafetyRank        = $category.SafetyRank
            SizeBytes         = [long] $category.EligibleBytes
            SizeText          = $category.EligibleSizeText
            FileCount         = $category.EligibleFileCount
            WhatItIs          = $category.WhatItIs
            Reason            = $category.Reason
            Remediation       = $category.Remediation
            Command           = $category.Command
            Method            = $category.Method
            RequiresReboot    = $category.RequiresReboot
            RequiresApproval  = ($category.Safety -ne 'Safe')
            Confidence        = if ($category.Id -eq 'unclassified') { 'Low' }
                                elseif ($category.Safety -eq 'Safe') { 'High' }
                                else { 'Medium' }
            Source            = 'Scan'
            Available         = $true
            Unavailable       = ''
            Examples          = $category.Examples
            Selected          = $false
        }

        if ($category.Safety -eq 'Unsafe') {
            # Unsafe data is never a candidate, but the large ones still need a decision.
            $action.SizeBytes = [long] $category.Bytes
            $action.SizeText = $category.SizeText
            $action.FileCount = $category.FileCount
            $escalations.Add($action)
        } elseif ($action.SizeBytes -gt 0) {
            $candidates.Add($action)
        }
    }
    #endregion

    #region Select actions, safest first
    # Ordering is safety, then how confident we are about what the data is, then size.
    # Confidence matters: proposing the deletion of data nothing could identify is worse
    # than proposing the deletion of a larger pile that has been positively identified.
    $confidenceRank = @{ 'High' = 0; 'Medium' = 1; 'Low' = 2 }
    foreach ($action in $candidates) {
        $rank = $confidenceRank[[string] $action.Confidence]
        if ($null -eq $rank) { $rank = 1 }
        $action | Add-Member -NotePropertyName 'ConfidenceRank' -NotePropertyValue $rank -Force
    }

    $ordered = @($candidates | Sort-Object `
        @{ Expression = 'SafetyRank' }, `
        @{ Expression = 'ConfidenceRank' }, `
        @{ Expression = 'SizeBytes'; Descending = $true })

    $safeTotal = 0L
    $reviewTotal = 0L
    foreach ($action in $ordered) {
        if ($action.Safety -eq 'Safe') { $safeTotal += $action.SizeBytes } else { $reviewTotal += $action.SizeBytes }
    }

    $planned = 0L
    foreach ($action in $ordered) {
        if ($planned -ge $deficit) { break }
        $action.Selected = $true
        $planned += $action.SizeBytes
    }

    # With no measurable deficit there is nothing to select, but the safe items are still
    # worth doing - they are what keeps the headroom from eroding again.
    if ($deficit -le 0) {
        foreach ($action in $ordered) {
            if ($action.Safety -eq 'Safe') { $action.Selected = $true }
        }
        $planned = $safeTotal
    }

    $escalationList = @($escalations | Sort-Object @{ Expression = 'SizeBytes'; Descending = $true })
    #endregion

    $projectedFree = $currentFree + $planned
    $achievable = (-not $capacityKnown) -or ($projectedFree -ge $targetFree)
    $shortfall = [math]::Max(0L, $targetFree - $projectedFree)

    $headroomBefore = $null
    $headroomAfter = $null
    if ($capacityKnown -and $growthPerMonth -gt 0) {
        $headroomBefore = [math]::Round(($currentFree - $reserve) / $growthPerMonth, 1)
        $headroomAfter = [math]::Round(($projectedFree - $reserve) / $growthPerMonth, 1)
    }

    $selected = @($ordered | Where-Object { $_.Selected })

    $plan = [pscustomobject]@{
        PSTypeName              = 'Dsa.SpacePlan'
        HorizonMonths           = $HorizonMonths
        SafetyFactor            = $SafetyFactor
        CapacityKnown           = $capacityKnown
        CapacityBytes           = $capacity
        CurrentFreeBytes        = if ($capacityKnown) { $currentFree } else { $null }
        CurrentFreeText         = if ($capacityKnown) { Format-DsaBytes $currentFree } else { 'n/a' }
        GrowthBytesPerMonth     = $growthPerMonth
        GrowthText              = Format-DsaBytes $growthPerMonth
        GrowthConfidence        = if ($Growth) { $Growth.Confidence } else { 'Unknown' }
        ProjectedGrowthBytes    = $projectedGrowth
        ProjectedGrowthText     = Format-DsaBytes $projectedGrowth
        ReserveBytes            = [long] $reserve
        ReserveText             = Format-DsaBytes $reserve
        TargetFreeBytes         = $targetFree
        TargetFreeText          = Format-DsaBytes $targetFree
        DeficitBytes            = [long] $deficit
        DeficitText             = Format-DsaBytes $deficit
        ReclaimableSafeBytes    = $safeTotal
        ReclaimableSafeText     = Format-DsaBytes $safeTotal
        ReclaimableReviewBytes  = $reviewTotal
        ReclaimableReviewText   = Format-DsaBytes $reviewTotal
        PlannedReclaimBytes     = [long] $planned
        PlannedReclaimText      = Format-DsaBytes $planned
        ProjectedFreeBytes      = if ($capacityKnown) { [long] $projectedFree } else { $null }
        ProjectedFreeText       = if ($capacityKnown) { Format-DsaBytes $projectedFree } else { 'n/a' }
        HeadroomMonthsBefore    = $headroomBefore
        HeadroomMonthsAfter     = $headroomAfter
        Achievable              = $achievable
        AchievableWithSafeOnly  = ((-not $capacityKnown) -or (($currentFree + $safeTotal) -ge $targetFree))
        ShortfallBytes          = [long] $shortfall
        ShortfallText           = Format-DsaBytes $shortfall
        Actions                 = $selected
        AllCandidates           = $ordered
        Escalations             = $escalationList
        Assumptions             = $assumptions.ToArray()
        PreventiveControls      = @(Get-DsaPreventiveControl -Summary $Summary -HorizonMonths $HorizonMonths)
        Recommendation          = @()
    }

    # The narrative needs the finished numbers, so it is attached after the object is built.
    $plan.Recommendation = New-DsaPlanNarrative -Plan $plan -Summary $Summary -Volume $Volume
    $plan
}
