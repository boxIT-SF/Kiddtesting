function New-DsaHtmlReport {
    <#
        .SYNOPSIS
            Renders the analysis as a single self-contained HTML file.
        .NOTES
            No external assets: the file has to survive being emailed, dropped into a ticket
            or opened from a share with no internet access.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [psobject] $Result,
        [int] $MaxRows = 25
    )

    $summary = $Result.Summary
    $plan = $Result.Plan
    $volume = $Result.Volume

    $sb = New-Object System.Text.StringBuilder
    function Add-Line { param([string] $Text) $null = $sb.AppendLine($Text) }
    function Esc { param([AllowNull()] $Value) ConvertTo-DsaHtmlText ([string] $Value) }

    $title = "Disk space analysis - $($Result.ComputerName) - $($volume.Root)"
    $generated = $Result.ScanFinishedUtc.ToString('yyyy-MM-dd HH:mm') + ' UTC'

    Add-Line '<!DOCTYPE html>'
    Add-Line '<html lang="en"><head><meta charset="utf-8">'
    Add-Line '<meta name="viewport" content="width=device-width, initial-scale=1">'
    Add-Line "<title>$(Esc $title)</title>"
    Add-Line @'
<style>
:root{
  --bg:#f6f7f9; --card:#ffffff; --ink:#1d2129; --muted:#5c6570; --line:#dfe3e8;
  --safe:#1f7a4d; --safe-bg:#e8f5ee; --review:#8a6100; --review-bg:#fdf3e0;
  --unsafe:#a52222; --unsafe-bg:#fbeaea; --accent:#1f4f82; --bar:#1f4f82;
}
@media (prefers-color-scheme: dark){
  :root{
    --bg:#14171a; --card:#1c2024; --ink:#e7eaee; --muted:#9aa4b0; --line:#2c3238;
    --safe:#5fce9b; --safe-bg:#16302a; --review:#e0b25c; --review-bg:#30290f;
    --unsafe:#f08a8a; --unsafe-bg:#331a1a; --accent:#7fb2e8; --bar:#7fb2e8;
  }
}
*{box-sizing:border-box}
body{margin:0;padding:24px;background:var(--bg);color:var(--ink);
     font:14px/1.5 "Segoe UI",system-ui,-apple-system,sans-serif}
.wrap{max-width:1180px;margin:0 auto}
h1{font-size:22px;margin:0 0 4px}
h2{font-size:16px;margin:28px 0 10px;padding-bottom:6px;border-bottom:1px solid var(--line)}
.sub{color:var(--muted);margin:0 0 18px}
.card{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:16px;margin-bottom:16px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:12px}
.stat{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:12px 14px}
.stat .k{color:var(--muted);font-size:12px;text-transform:uppercase;letter-spacing:.04em}
.stat .v{font-size:20px;font-weight:600;margin-top:2px}
.stat .n{color:var(--muted);font-size:12px;margin-top:2px}
.gauge{height:14px;background:var(--line);border-radius:7px;overflow:hidden;margin:10px 0 6px}
.gauge > span{display:block;height:100%;background:var(--bar)}
table{width:100%;border-collapse:collapse;margin-top:8px;font-size:13px}
th,td{text-align:left;padding:7px 9px;border-bottom:1px solid var(--line);vertical-align:top}
th{color:var(--muted);font-weight:600;font-size:12px;text-transform:uppercase;letter-spacing:.03em}
td.num,th.num{text-align:right;white-space:nowrap;font-variant-numeric:tabular-nums}
tr:last-child td{border-bottom:none}
.tag{display:inline-block;padding:1px 8px;border-radius:10px;font-size:12px;font-weight:600;white-space:nowrap}
.tag.Safe{color:var(--safe);background:var(--safe-bg)}
.tag.Review{color:var(--review);background:var(--review-bg)}
.tag.Unsafe{color:var(--unsafe);background:var(--unsafe-bg)}
code{background:var(--bg);border:1px solid var(--line);border-radius:4px;padding:1px 5px;
     font:12px/1.5 Consolas,"Cascadia Mono",monospace;word-break:break-all}
.path{font:12px/1.5 Consolas,"Cascadia Mono",monospace;word-break:break-all}
ul.plain{margin:6px 0 0;padding-left:18px}
ul.plain li{margin-bottom:5px}
.lead li{margin-bottom:8px;font-size:15px}
.muted{color:var(--muted)}
.bar{background:var(--line);border-radius:4px;height:10px;min-width:2px;display:block}
.bar > span{display:block;height:100%;background:var(--bar);border-radius:4px}
.scroll{overflow-x:auto}
footer{color:var(--muted);font-size:12px;margin-top:28px;text-align:center}
@media print{body{background:#fff;padding:0}.card,.stat{break-inside:avoid}}
</style>
'@
    Add-Line '</head><body><div class="wrap">'

    Add-Line "<h1>$(Esc $title)</h1>"
    Add-Line "<p class=""sub"">Scanned $(Esc ($Result.Path -join ', ')) on $(Esc $generated) &middot; took $($Result.DurationSeconds)s &middot; horizon $($plan.HorizonMonths) months</p>"

    #region Headline stats
    Add-Line '<div class="grid">'
    Add-Line "<div class=""stat""><div class=""k"">Free now</div><div class=""v"">$(Esc $volume.FreeText)</div><div class=""n"">of $(Esc $volume.CapacityText) &middot; $(Esc $volume.PercentUsed)% used</div></div>"
    Add-Line "<div class=""stat""><div class=""k"">Needed for $($plan.HorizonMonths) months</div><div class=""v"">$(Esc $plan.TargetFreeText)</div><div class=""n"">growth $(Esc $plan.ProjectedGrowthText) + reserve $(Esc $plan.ReserveText)</div></div>"
    Add-Line "<div class=""stat""><div class=""k"">Shortfall today</div><div class=""v"">$(Esc $plan.DeficitText)</div><div class=""n"">$(if ($plan.DeficitBytes -le 0) { 'already covered' } else { 'must be reclaimed or added' })</div></div>"
    Add-Line "<div class=""stat""><div class=""k"">Plan reclaims</div><div class=""v"">$(Esc $plan.PlannedReclaimText)</div><div class=""n"">safe $(Esc $plan.ReclaimableSafeText) &middot; with sign-off $(Esc $plan.ReclaimableReviewText)</div></div>"
    $headroomText = if ($null -ne $plan.HeadroomMonthsAfter) { "$($plan.HeadroomMonthsAfter) months" } else { 'n/a' }
    $headroomNote = if ($null -ne $plan.HeadroomMonthsBefore) { "was $($plan.HeadroomMonthsBefore) months" } else { 'growth rate unknown' }
    Add-Line "<div class=""stat""><div class=""k"">Headroom after plan</div><div class=""v"">$(Esc $headroomText)</div><div class=""n"">$(Esc $headroomNote)</div></div>"
    Add-Line "<div class=""stat""><div class=""k"">Growth estimate</div><div class=""v"">$(Esc $plan.GrowthText)/mo</div><div class=""n"">confidence $(Esc $plan.GrowthConfidence)</div></div>"
    Add-Line '</div>'

    if ($volume.CapacityBytes) {
        $usedPercent = [math]::Min(100, [math]::Max(0, [double] $volume.PercentUsed))
        Add-Line '<div class="card">'
        Add-Line "<div class=""gauge""><span style=""width:$usedPercent%""></span></div>"
        Add-Line "<div class=""muted"">$(Esc $volume.UsedText) used &middot; $(Esc $volume.FreeText) free &middot; operating reserve $(Esc $plan.ReserveText)</div>"
        Add-Line '</div>'
    }
    #endregion

    #region Recommendation
    Add-Line '<h2>Recommendation</h2><div class="card"><ul class="plain lead">'
    foreach ($line in $plan.Recommendation) { Add-Line "<li>$(Esc $line)</li>" }
    Add-Line '</ul></div>'
    #endregion

    #region Plan
    Add-Line "<h2>Step 1 &ndash; reclaim $($plan.PlannedReclaimText)</h2>"
    Add-Line '<div class="card"><p class="muted">Ordered safest first. Everything marked Safe regenerates on its own and needs no sign-off; the rest needs a decision from the owner named in the reason.</p><div class="scroll"><table>'
    Add-Line '<tr><th>Safety</th><th>What it is</th><th class="num">Reclaims</th><th>Why / what to do</th><th>How</th></tr>'
    if ($plan.Actions.Count -eq 0) {
        Add-Line '<tr><td colspan="5" class="muted">Nothing reclaimable was found.</td></tr>'
    }
    foreach ($action in $plan.Actions) {
        $detail = if ($action.Safety -eq 'Safe') { $action.Reason } else { "$($action.Reason) $($action.Remediation)".Trim() }
        $countText = if ($null -ne $action.FileCount) { "$('{0:N0}' -f $action.FileCount) files" } else { '' }
        $command = if ($action.Command) { "<code>$(Esc $action.Command)</code>" } else { '<span class="muted">-</span>' }
        Add-Line "<tr><td><span class=""tag $(Esc $action.Safety)"">$(Esc $action.Safety)</span></td>"
        Add-Line "<td><strong>$(Esc $action.Title)</strong><div class=""muted"">$(Esc $action.WhatItIs)</div></td>"
        Add-Line "<td class=""num"">$(Esc $action.SizeText)<div class=""muted"">$(Esc $countText)</div></td>"
        Add-Line "<td>$(Esc $detail)</td><td>$command</td></tr>"
    }
    Add-Line '</table></div></div>'
    #endregion

    #region Escalations
    $escalations = @($plan.Escalations | Where-Object { $_.SizeBytes -gt 0 } | Select-Object -First $MaxRows)
    Add-Line '<h2>Step 2 &ndash; large data that must not simply be deleted</h2>'
    Add-Line '<div class="card"><p class="muted">None of this counts toward the target above. It is listed because it is where the space actually went, and each row names the supported way to shrink or move it.</p><div class="scroll"><table>'
    Add-Line '<tr><th>Safety</th><th>What it is</th><th class="num">Size</th><th>Why it cannot just be deleted</th><th>What to do instead</th></tr>'
    if ($escalations.Count -eq 0) {
        Add-Line '<tr><td colspan="5" class="muted">Nothing in this category was found.</td></tr>'
    }
    foreach ($item in $escalations) {
        $command = if ($item.Command) { "<div><code>$(Esc $item.Command)</code></div>" } else { '' }
        Add-Line "<tr><td><span class=""tag $(Esc $item.Safety)"">$(Esc $item.Safety)</span></td>"
        Add-Line "<td><strong>$(Esc $item.Title)</strong><div class=""muted"">$(Esc $item.WhatItIs)</div></td>"
        Add-Line "<td class=""num"">$(Esc $item.SizeText)</td><td>$(Esc $item.Reason)</td>"
        Add-Line "<td>$(Esc $item.Remediation)$command</td></tr>"
    }
    Add-Line '</table></div></div>'
    #endregion

    #region Preventive controls
    Add-Line '<h2>Step 3 &ndash; keep it clear</h2>'
    Add-Line "<div class=""card""><p class=""muted"">A one-off cleanup refills. These controls are what make the $($plan.HorizonMonths)-month figure hold.</p><div class=""scroll""><table>"
    Add-Line '<tr><th>Trigger</th><th>Control</th><th>Detail</th><th>How</th></tr>'
    foreach ($control in $plan.PreventiveControls) {
        $command = if ($control.Command) { "<code>$(Esc $control.Command)</code>" } else { '<span class="muted">-</span>' }
        Add-Line "<tr><td>$(Esc $control.Trigger)</td><td><strong>$(Esc $control.Name)</strong></td><td>$(Esc $control.Detail)</td><td>$command</td></tr>"
    }
    Add-Line '</table></div></div>'
    #endregion

    #region Oldest data
    Add-Line '<h2>Oldest data on the volume</h2>'
    Add-Line "<div class=""card""><p class=""muted"">Files at least $(Format-DsaBytes $Result.Parameters.OldestMinSizeBytes), sorted by how long since anything last wrote to them.</p><div class=""scroll""><table>"
    Add-Line '<tr><th class="num">Age</th><th class="num">Size</th><th>Path</th><th>What it probably is</th><th>Safe to delete?</th></tr>'
    foreach ($file in ($summary.OldestFiles | Select-Object -First $MaxRows)) {
        $verdict = switch ($file.Safety) {
            'Safe'   { 'Yes' }
            'Review' { 'Needs a decision' }
            default  { 'No' }
        }
        Add-Line "<tr><td class=""num"">$('{0:N0}' -f $file.AgeDays) d</td><td class=""num"">$(Esc $file.SizeText)</td>"
        Add-Line "<td class=""path"">$(Esc $file.FullName)</td><td>$(Esc $file.Category)<div class=""muted"">$(Esc $file.WhatItIs)</div></td>"
        Add-Line "<td><span class=""tag $(Esc $file.Safety)"">$(Esc $verdict)</span></td></tr>"
    }
    Add-Line '</table></div></div>'
    #endregion

    #region Age profile
    Add-Line '<h2>How old the data is</h2><div class="card"><div class="scroll"><table>'
    Add-Line '<tr><th>Age band</th><th class="num">Size</th><th class="num">Files</th><th class="num">Share</th><th style="width:34%">&nbsp;</th></tr>'
    $maxBucket = 0
    foreach ($bucket in $summary.AgeBuckets) { if ($bucket.Bytes -gt $maxBucket) { $maxBucket = $bucket.Bytes } }
    foreach ($bucket in $summary.AgeBuckets) {
        $width = if ($maxBucket -gt 0) { [math]::Round(100 * $bucket.Bytes / $maxBucket, 1) } else { 0 }
        Add-Line "<tr><td>$(Esc $bucket.Name)</td><td class=""num"">$(Esc $bucket.SizeText)</td>"
        Add-Line "<td class=""num"">$('{0:N0}' -f $bucket.FileCount)</td><td class=""num"">$(Esc $bucket.PercentOfScan)%</td>"
        Add-Line "<td><span class=""bar""><span style=""width:$width%""></span></span></td></tr>"
    }
    Add-Line '</table></div></div>'
    #endregion

    #region Categories
    Add-Line '<h2>What the data is</h2><div class="card"><div class="scroll"><table>'
    Add-Line '<tr><th>Safety</th><th>Classification</th><th class="num">Total</th><th class="num">Reclaimable</th><th class="num">Files</th><th class="num">Oldest</th></tr>'
    foreach ($category in ($summary.Categories | Select-Object -First $MaxRows)) {
        $oldest = if ($null -ne $category.OldestAgeDays) { "$('{0:N0}' -f $category.OldestAgeDays) d" } else { '-' }
        Add-Line "<tr><td><span class=""tag $(Esc $category.Safety)"">$(Esc $category.Safety)</span></td>"
        Add-Line "<td><strong>$(Esc $category.Name)</strong><div class=""muted"">$(Esc $category.WhatItIs)</div></td>"
        Add-Line "<td class=""num"">$(Esc $category.SizeText)<div class=""muted"">$(Esc $category.PercentOfScan)%</div></td>"
        Add-Line "<td class=""num"">$(Esc $category.EligibleSizeText)</td>"
        Add-Line "<td class=""num"">$('{0:N0}' -f $category.FileCount)</td><td class=""num"">$oldest</td></tr>"
    }
    Add-Line '</table></div></div>'
    #endregion

    #region Directories and largest files
    Add-Line '<h2>Where the space went</h2><div class="card"><div class="scroll"><table>'
    Add-Line '<tr><th>Folder</th><th class="num">Size</th><th class="num">Files</th><th class="num">Share</th></tr>'
    foreach ($directory in $summary.TopDirectories) {
        Add-Line "<tr><td class=""path"">$(Esc $directory.Path)</td><td class=""num"">$(Esc $directory.SizeText)</td>"
        Add-Line "<td class=""num"">$('{0:N0}' -f $directory.FileCount)</td><td class=""num"">$(Esc $directory.PercentOfScan)%</td></tr>"
    }
    Add-Line '</table></div></div>'

    Add-Line '<h2>Largest files</h2><div class="card"><div class="scroll"><table>'
    Add-Line '<tr><th class="num">Size</th><th class="num">Age</th><th>Path</th><th>Classification</th><th>Safety</th></tr>'
    foreach ($file in $summary.LargestFiles) {
        Add-Line "<tr><td class=""num"">$(Esc $file.SizeText)</td><td class=""num"">$('{0:N0}' -f $file.AgeDays) d</td>"
        Add-Line "<td class=""path"">$(Esc $file.FullName)</td><td>$(Esc $file.Category)</td>"
        Add-Line "<td><span class=""tag $(Esc $file.Safety)"">$(Esc $file.Safety)</span></td></tr>"
    }
    Add-Line '</table></div></div>'
    #endregion

    #region Method and coverage
    Add-Line '<h2>How these numbers were produced</h2><div class="card"><ul class="plain">'
    foreach ($assumption in $plan.Assumptions) { Add-Line "<li>$(Esc $assumption)</li>" }
    Add-Line "<li>Scanned $('{0:N0}' -f $summary.FileCount) files totalling $(Esc $summary.TotalSizeText)$(if ($summary.OfflineFileCount -gt 0) { ", of which $('{0:N0}' -f $summary.OfflineFileCount) cloud placeholders ($(Format-DsaBytes $summary.OfflineBytes)) occupy no local space and are excluded from reclaimable totals" }).</li>"
    Add-Line "<li>Session was $(if ($Result.Elevated) { 'elevated' } else { 'not elevated - some system probes and remediation steps need elevation' }).</li>"
    if ($Result.Cancelled) { Add-Line '<li><strong>The scan was cancelled before it finished, so these figures are partial.</strong></li>' }
    Add-Line '</ul>'

    if ($Result.ScanErrors.Count -gt 0) {
        Add-Line "<p class=""muted"">$($Result.ScanErrors.Count) location(s) could not be read, so their contents are not included:</p><div class=""scroll""><table>"
        Add-Line '<tr><th>Path</th><th>Reason</th></tr>'
        foreach ($scanError in ($Result.ScanErrors | Select-Object -First 20)) {
            Add-Line "<tr><td class=""path"">$(Esc $scanError.Path)</td><td>$(Esc $scanError.Reason)</td></tr>"
        }
        Add-Line '</table></div>'
        if ($Result.ScanErrors.Count -gt 20) {
            Add-Line "<p class=""muted"">... and $($Result.ScanErrors.Count - 20) more.</p>"
        }
    }
    Add-Line '</div>'
    #endregion

    Add-Line "<footer>Generated by DiskSpaceAnalyzer $(Esc $script:DsaModuleVersion) on $(Esc $Result.ComputerName). Review every action before running it.</footer>"
    Add-Line '</div></body></html>'

    $sb.ToString()
}
