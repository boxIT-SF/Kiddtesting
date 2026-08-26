function New-DsaTextReport {
    <#
        .SYNOPSIS
            Renders the analysis as plain text for a console, a ticket note or an RMM script
            output pane.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [psobject] $Result,
        [int] $MaxRows = 12,
        [int] $Width = 100
    )

    $summary = $Result.Summary
    $plan = $Result.Plan
    $volume = $Result.Volume

    $sb = New-Object System.Text.StringBuilder
    function Add-Line { param([string] $Text = '') $null = $sb.AppendLine($Text) }
    function Add-Rule { Add-Line ('-' * $Width) }
    function Add-Heading {
        param([string] $Text)
        Add-Line
        Add-Line $Text.ToUpperInvariant()
        Add-Rule
    }

    Add-Rule
    Add-Line "DISK SPACE ANALYSIS - $($Result.ComputerName) - $($volume.Root)"
    Add-Line "Scanned $($Result.Path -join ', ') at $($Result.ScanFinishedUtc.ToString('yyyy-MM-dd HH:mm')) UTC in $($Result.DurationSeconds)s"
    Add-Rule

    Add-Heading 'Recommendation'
    foreach ($line in $plan.Recommendation) {
        foreach ($wrapped in (Split-DsaTextBlock -Text "* $line" -Width $Width -HangingIndent 2)) { Add-Line $wrapped }
    }

    Add-Heading "Capacity target ($($plan.HorizonMonths) months)"
    Add-Line ("  {0,-34}{1}" -f 'Capacity', $volume.CapacityText)
    Add-Line ("  {0,-34}{1}" -f 'Free now', $volume.FreeText)
    Add-Line ("  {0,-34}{1} / month ({2} confidence)" -f 'Estimated growth', $plan.GrowthText, $plan.GrowthConfidence)
    Add-Line ("  {0,-34}{1}" -f "Growth over $($plan.HorizonMonths) months (x$($plan.SafetyFactor))", $plan.ProjectedGrowthText)
    Add-Line ("  {0,-34}{1}" -f 'Operating reserve', $plan.ReserveText)
    Add-Line ("  {0,-34}{1}" -f 'Free space required', $plan.TargetFreeText)
    Add-Line ("  {0,-34}{1}" -f 'Shortfall today', $plan.DeficitText)
    Add-Line ("  {0,-34}{1}" -f 'Planned reclaim', $plan.PlannedReclaimText)
    Add-Line ("  {0,-34}{1}" -f 'Projected free after plan', $plan.ProjectedFreeText)
    Add-Line ("  {0,-34}{1}" -f 'Target met', $(if ($plan.Achievable) { 'Yes' } else { "No - short by $($plan.ShortfallText)" }))

    Add-Heading 'Step 1 - reclaim (safest first)'
    if ($plan.Actions.Count -eq 0) { Add-Line '  Nothing reclaimable was found.' }
    foreach ($action in $plan.Actions) {
        Add-Line ("  [{0,-6}] {1,10}  {2}" -f $action.Safety, $action.SizeText, $action.Title)
        foreach ($wrapped in (Split-DsaTextBlock -Text $action.WhatItIs -Width $Width -Indent 13)) { Add-Line $wrapped }
        if ($action.Safety -ne 'Safe' -and $action.Remediation) {
            foreach ($wrapped in (Split-DsaTextBlock -Text "Do: $($action.Remediation)" -Width $Width -Indent 13)) { Add-Line $wrapped }
        }
        if ($action.Command) { Add-Line ("{0}{1}" -f (' ' * 15), $action.Command) }
    }

    Add-Heading 'Step 2 - large data that must not simply be deleted'
    $escalations = @($plan.Escalations | Where-Object { $_.SizeBytes -gt 0 } | Select-Object -First $MaxRows)
    if ($escalations.Count -eq 0) { Add-Line '  None found.' }
    foreach ($item in $escalations) {
        Add-Line ("  [{0,-6}] {1,10}  {2}" -f $item.Safety, $item.SizeText, $item.Title)
        foreach ($wrapped in (Split-DsaTextBlock -Text "Why: $($item.Reason)" -Width $Width -Indent 13)) { Add-Line $wrapped }
        foreach ($wrapped in (Split-DsaTextBlock -Text "Do: $($item.Remediation)" -Width $Width -Indent 13)) { Add-Line $wrapped }
        if ($item.Command) { Add-Line ("{0}{1}" -f (' ' * 15), $item.Command) }
    }

    Add-Heading 'Step 3 - keep it clear'
    foreach ($control in $plan.PreventiveControls) {
        Add-Line ("  {0}: {1}" -f $control.Trigger, $control.Name)
        foreach ($wrapped in (Split-DsaTextBlock -Text $control.Detail -Width $Width -Indent 6)) { Add-Line $wrapped }
    }

    Add-Heading 'Oldest data'
    Add-Line ("  {0,6}  {1,10}  {2,-30}  {3}" -f 'AGE', 'SIZE', 'CLASSIFICATION', 'PATH')
    foreach ($file in ($summary.OldestFiles | Select-Object -First $MaxRows)) {
        Add-Line ("  {0,5}d  {1,10}  {2,-30}  {3}" -f $file.AgeDays, $file.SizeText, $file.Category, $file.FullName)
    }

    Add-Heading 'Age profile'
    foreach ($bucket in $summary.AgeBuckets) {
        $blocks = if ($summary.TotalBytes -gt 0) { [int] [math]::Round(40 * $bucket.Bytes / $summary.TotalBytes) } else { 0 }
        Add-Line ("  {0,-16} {1,10} {2,6}%  {3}" -f $bucket.Name, $bucket.SizeText, $bucket.PercentOfScan, ('#' * $blocks))
    }

    Add-Heading 'Where the space went'
    foreach ($directory in ($summary.TopDirectories | Select-Object -First $MaxRows)) {
        Add-Line ("  {0,10} {1,6}%  {2}" -f $directory.SizeText, $directory.PercentOfScan, $directory.Path)
    }

    Add-Heading 'Method and coverage'
    foreach ($assumption in $plan.Assumptions) {
        foreach ($wrapped in (Split-DsaTextBlock -Text "* $assumption" -Width $Width -HangingIndent 2)) { Add-Line $wrapped }
    }
    Add-Line ("  Scanned {0:N0} files totalling {1}." -f $summary.FileCount, $summary.TotalSizeText)
    if ($summary.OfflineFileCount -gt 0) {
        Add-Line ("  {0:N0} cloud placeholders ({1}) report a size but occupy no local space; excluded from reclaimable totals." -f $summary.OfflineFileCount, (Format-DsaBytes $summary.OfflineBytes))
    }
    if (-not $Result.Elevated) {
        Add-Line '  Session was not elevated - some system probes and remediation steps need elevation.'
    }
    if ($Result.Cancelled) { Add-Line '  SCAN WAS CANCELLED - figures are partial.' }
    if ($Result.ScanErrors.Count -gt 0) {
        Add-Line ("  {0} location(s) could not be read and are not included." -f $Result.ScanErrors.Count)
    }

    $sb.ToString()
}

function Split-DsaTextBlock {
    <#
        .SYNOPSIS
            Word-wraps a block of text to a fixed console width with an optional indent.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [AllowEmptyString()] [string] $Text,
        [int] $Width = 100,
        [int] $Indent = 0,
        [int] $HangingIndent = 0
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }

    $firstPrefix = ' ' * ($Indent + 2)
    $restPrefix = ' ' * ($Indent + 2 + $HangingIndent)
    $limit = [math]::Max(20, $Width - $restPrefix.Length)

    $lines = New-Object System.Collections.Generic.List[string]
    $current = ''
    foreach ($word in ($Text -split '\s+')) {
        if ([string]::IsNullOrEmpty($word)) { continue }
        if ($current.Length -eq 0) { $current = $word }
        elseif (($current.Length + 1 + $word.Length) -le $limit) { $current = "$current $word" }
        else { $lines.Add($current); $current = $word }
    }
    if ($current.Length -gt 0) { $lines.Add($current) }

    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($i -eq 0) { $firstPrefix + $lines[$i] } else { $restPrefix + $lines[$i] }
    }
}
