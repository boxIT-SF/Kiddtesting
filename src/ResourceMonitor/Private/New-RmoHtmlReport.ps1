function New-RmoHtmlReport {
    <#
        .SYNOPSIS
            Renders the analysis as a single self-contained HTML file.

        .DESCRIPTION
            No external stylesheet, no script, no fonts to fetch - the file opens on a machine
            with no internet access, survives being attached to a ticket, and prints. Impact and
            risk are colour-coded, and every row carries the description and the manufacturer
            rather than only a name and a number.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [psobject] $Result)

    $system = $Result.System
    $pressure = $Result.Pressure
    $plan = $Result.Plan
    $html = [System.Collections.Generic.List[string]]::new()

    function Add-Html { param([string] $Text) $html.Add($Text) }
    function Encode { param([AllowNull()] [string] $Text) ConvertTo-RmoHtmlText $Text }

    function New-Meter {
        <#
            A pressure score as a bar, so the four resources can be compared at a glance instead
            of by reading four numbers.
        #>
        param([string] $Label, [double] $Score, [string] $Level, [string] $Detail)

        $class = switch ($Level) {
            'Critical' { 'critical' }
            'Elevated' { 'elevated' }
            'Normal'   { 'normal' }
            default    { 'unknown' }
        }
        $width = [int] (Limit-RmoValue $Score 0 100)
        @"
    <div class="meter">
      <div class="meter-head"><span class="meter-label">$(Encode $Label)</span><span class="badge $class">$(Encode $Level) &middot; $width/100</span></div>
      <div class="track"><div class="fill $class" style="width:$width%"></div></div>
      <div class="meter-detail">$(Encode $Detail)</div>
    </div>
"@
    }

    $generated = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $bottleneck = if ($plan.Bottleneck -eq 'None') { 'No single constraint' } else { "$($plan.Bottleneck)-bound" }

    Add-Html @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Resource report - $(Encode $system.ComputerName)</title>
<style>
  :root { color-scheme: light; }
  * { box-sizing: border-box; }
  body { margin: 0; padding: 28px; background: #f4f5f7; color: #1d2125;
         font: 14px/1.55 "Segoe UI", system-ui, -apple-system, sans-serif; }
  .wrap { max-width: 1180px; margin: 0 auto; }
  header { background: #1d2125; color: #fff; padding: 22px 26px; border-radius: 8px 8px 0 0; }
  header h1 { margin: 0 0 4px; font-size: 21px; font-weight: 600; }
  header .sub { color: #b6bcc4; font-size: 13px; }
  .verdict { background: #fff; border-left: 5px solid #0b5cad; padding: 18px 24px;
             font-size: 16px; font-weight: 600; }
  section { background: #fff; padding: 20px 26px 26px; }
  section:last-of-type { border-radius: 0 0 8px 8px; }
  h2 { font-size: 15px; text-transform: uppercase; letter-spacing: .06em; color: #5a6069;
       margin: 4px 0 14px; border-bottom: 1px solid #e3e5e8; padding-bottom: 8px; }
  table { width: 100%; border-collapse: collapse; margin-bottom: 6px; }
  th { text-align: left; font-size: 11px; text-transform: uppercase; letter-spacing: .05em;
       color: #5a6069; border-bottom: 2px solid #e3e5e8; padding: 7px 9px; white-space: nowrap; }
  td { padding: 7px 9px; border-bottom: 1px solid #f0f1f3; vertical-align: top; }
  tbody tr:hover { background: #f8f9fb; }
  .num { text-align: right; font-variant-numeric: tabular-nums; white-space: nowrap; }
  .mono { font-family: Consolas, "Cascadia Mono", monospace; font-size: 12px; }
  .muted { color: #6b7280; }
  .scroll { overflow-x: auto; }
  .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); gap: 16px; }
  .facts { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 4px 24px; }
  .facts div { padding: 3px 0; border-bottom: 1px solid #f0f1f3; }
  .facts span { display: inline-block; width: 140px; color: #6b7280; }
  .meter-head { display: flex; justify-content: space-between; align-items: center; margin-bottom: 6px; }
  .meter-label { font-weight: 600; }
  .track { height: 9px; background: #e8eaed; border-radius: 5px; overflow: hidden; }
  .fill { height: 100%; }
  .fill.critical { background: #b3261e; } .fill.elevated { background: #b26b00; }
  .fill.normal { background: #1a7f47; }   .fill.unknown { background: #9aa0a6; }
  .meter-detail { font-size: 12px; color: #6b7280; margin-top: 6px; }
  .badge { display: inline-block; padding: 1px 8px; border-radius: 10px; font-size: 11px;
           font-weight: 600; white-space: nowrap; }
  .badge.critical, .badge.high { background: #fdecea; color: #a3211a; }
  .badge.elevated, .badge.medium { background: #fdf3e2; color: #8a5200; }
  .badge.normal, .badge.low { background: #e8f5ed; color: #14683a; }
  .badge.unknown, .badge.info { background: #eef0f2; color: #4a5058; }
  .action { border: 1px solid #e3e5e8; border-left-width: 5px; border-radius: 6px;
            padding: 14px 18px; margin-bottom: 12px; }
  .action.high { border-left-color: #b3261e; } .action.medium { border-left-color: #b26b00; }
  .action.low { border-left-color: #1a7f47; }  .action.info { border-left-color: #9aa0a6; }
  .action h3 { margin: 0 0 6px; font-size: 15px; }
  .action .meta { font-size: 12px; color: #6b7280; margin-bottom: 10px; }
  .action dl { margin: 0; }
  .action dt { font-size: 11px; text-transform: uppercase; letter-spacing: .05em;
               color: #6b7280; margin-top: 9px; }
  .action dd { margin: 2px 0 0; }
  .action .cmd { background: #1d2125; color: #e6e8ea; padding: 8px 11px; border-radius: 4px;
                 font-family: Consolas, monospace; font-size: 12px; overflow-x: auto;
                 white-space: pre-wrap; word-break: break-all; }
  footer { color: #6b7280; font-size: 12px; padding: 16px 4px; }
  @media print { body { background: #fff; padding: 0; } .action, section { break-inside: avoid; } }
</style>
</head>
<body>
<div class="wrap">
<header>
  <h1>Resource report &mdash; $(Encode $system.ComputerName)</h1>
  <div class="sub">$(Encode $system.Manufacturer) $(Encode $system.Model) &middot;
    $(Encode $system.Os.Caption) build $(Encode $system.Os.BuildNumber) &middot;
    $(Encode $Result.ScanMode) scan, $($Result.DurationSeconds)s &middot; $generated</div>
</header>
<div class="verdict">$(Encode $bottleneck) &mdash; $($plan.HighImpactCount) high-impact
  action$(if ($plan.HighImpactCount -ne 1) { 's' }),
  up to $(Encode $plan.RecoverableMemoryText) of memory recoverable</div>
"@

    #region Pressure
    Add-Html '<section><h2>Where the machine is under strain</h2><div class="grid">'
    Add-Html (New-Meter 'Processor' $pressure.Cpu.Score $pressure.Cpu.Level `
        "$(Format-RmoPercent $pressure.Cpu.TotalPercent) busy across $($system.Cpu.LogicalProcessors) logical processors; $(Format-RmoPercent $pressure.Cpu.UnattributedPercent) not attributable to any process.")
    Add-Html (New-Meter 'Memory' $pressure.Memory.Score $pressure.Memory.Level `
        "$(Format-RmoBytes $pressure.Memory.AvailableBytes) available of $(Format-RmoBytes $pressure.Memory.TotalBytes); $(Format-RmoBytes $pressure.Memory.CompressedBytes) compressed.")
    $diskDetail = if ($null -ne $pressure.Disk.LatencyMs) { "$($pressure.Disk.LatencyMs) ms per transfer" } else { 'latency unavailable' }
    Add-Html (New-Meter 'Disk' $pressure.Disk.Score $pressure.Disk.Level `
        "$(Format-RmoPercent $pressure.Disk.BusyPercent) busy, $diskDetail; system disk is $($pressure.Disk.SystemDiskMedia).")
    Add-Html (New-Meter 'Network' $pressure.Network.Score $pressure.Network.Level `
        "$(Format-RmoRate $pressure.Network.BytesPerSecond) across $(@($pressure.Network.Adapters).Count) active adapter(s).")
    Add-Html '</div></section>'
    #endregion

    #region Verdict narrative
    Add-Html '<section><h2>What is going on</h2><pre class="mono" style="white-space:pre-wrap;margin:0">'
    Add-Html (Encode $plan.NarrativeText)
    Add-Html '</pre></section>'
    #endregion

    #region The machine
    Add-Html '<section><h2>The machine</h2><div class="facts">'
    $facts = [ordered]@{
        'Processor'    = "$($system.Cpu.Name) - $($system.Cpu.Cores) cores / $($system.Cpu.LogicalProcessors) logical, $($system.Cpu.MaxClockMhz) MHz"
        'Memory'       = "$(Format-RmoBytes $system.Memory.TotalBytes) in $($system.Memory.UsedSlots) of $($system.Memory.TotalSlots) slots"
        'System disk'  = $pressure.Disk.SystemDiskMedia
        'Graphics'     = (@($system.Graphics | ForEach-Object { "$($_.Name) (driver $($_.DriverVersion))" }) -join '; ')
        'Uptime'       = Format-RmoDuration $system.Os.UptimeSeconds
        'Power plan'   = "$($system.PowerPlan.Name)$(if ($system.OnBattery) { ' - on battery' })"
        'Antivirus'    = (@($system.Antivirus | ForEach-Object { $_.DisplayName }) -join '; ')
        'Processes'    = "$($pressure.Counts.Processes) processes, $($pressure.Counts.Threads) threads, $($pressure.Counts.Handles) handles"
        'Scan'         = "$($Result.ScanMode), $($Result.SampleCount) samples over $($Result.DurationSeconds)s, $(if ($Result.Elevated) { 'elevated' } else { 'standard user' })"
    }
    foreach ($key in $facts.Keys) {
        Add-Html "  <div><span>$(Encode $key)</span>$(Encode ([string] $facts[$key]))</div>"
    }
    Add-Html '</div></section>'
    #endregion

    #region Volumes
    Add-Html '<section><h2>Volumes</h2><div class="scroll"><table><thead><tr><th>Volume</th><th>Label</th><th class="num">Size</th><th class="num">Free</th><th class="num">Free %</th></tr></thead><tbody>'
    foreach ($volume in $system.Volumes) {
        $freeClass = if ($null -ne $volume.FreePercent -and $volume.FreePercent -lt 10) { ' class="badge high"' } else { '' }
        Add-Html ("  <tr><td class=""mono"">$(Encode $volume.DriveLetter)</td><td>$(Encode $volume.Label)</td>" +
            "<td class=""num"">$(Format-RmoBytes $volume.SizeBytes)</td><td class=""num"">$(Format-RmoBytes $volume.FreeBytes)</td>" +
            "<td class=""num""><span$freeClass>$(Format-RmoPercent $volume.FreePercent)</span></td></tr>")
    }
    Add-Html '</tbody></table></div></section>'
    #endregion

    #region Consumers by product
    Add-Html '<section><h2>Top consumers, grouped by product</h2><div class="scroll"><table><thead><tr>'
    Add-Html '<th>Product</th><th>Manufacturer</th><th>What it is</th><th class="num">Memory</th><th class="num">CPU</th><th class="num">Disk</th><th class="num">Processes</th></tr></thead><tbody>'
    foreach ($family in @($Result.Hogs.TopFamilyMemory | Select-Object -First 20)) {
        Add-Html ("  <tr><td><strong>$(Encode $family.Family)</strong><div class=""muted mono"">$(Encode $family.ProcessNameText)</div></td>" +
            "<td>$(Encode $family.Vendor)</td><td class=""muted"">$(Encode $family.Description)</td>" +
            "<td class=""num"">$(Encode $family.MemoryText)</td><td class=""num"">$(Encode $family.CpuText)</td>" +
            "<td class=""num"">$(Encode $family.DiskText)</td><td class=""num"">$($family.ProcessCount)</td></tr>")
    }
    Add-Html '</tbody></table></div></section>'
    #endregion

    #region Individual processes
    Add-Html '<section><h2>Heaviest individual processes</h2><div class="scroll"><table><thead><tr>'
    Add-Html '<th>Process</th><th class="num">PID</th><th>What it is</th><th>Manufacturer</th><th class="num">Memory</th><th class="num">CPU</th><th class="num">Disk</th><th class="num">Handles</th></tr></thead><tbody>'
    foreach ($item in @($Result.Hogs.TopMemory | Select-Object -First 25)) {
        $what = Encode $item.Identity.Name
        if ($item.ServiceText) { $what += "<div class=""muted"">Hosting: $(Encode $item.ServiceText)</div>" }
        Add-Html ("  <tr><td class=""mono"">$(Encode $item.Name)</td><td class=""num"">$($item.ProcessId)</td>" +
            "<td>$what</td><td>$(Encode $item.Identity.Vendor)</td>" +
            "<td class=""num"">$(Encode $item.MemoryText)</td><td class=""num"">$(Encode $item.CpuText)</td>" +
            "<td class=""num"">$(Encode $item.DiskText)</td><td class=""num"">$('{0:N0}' -f $item.HandleCount)</td></tr>")
    }
    Add-Html '</tbody></table></div></section>'
    #endregion

    #region The plan
    Add-Html "<section><h2>Plan &mdash; $($plan.HighImpactCount) high, $($plan.MediumImpactCount) medium, $($plan.LowImpactCount) low</h2>"
    if (@($plan.Actions).Count -eq 0) {
        Add-Html '<p class="muted">Nothing found that is worth changing on the strength of these measurements.</p>'
    }
    $number = 1
    foreach ($action in $plan.Actions) {
        $class = $action.Impact.ToLowerInvariant()
        Add-Html "<div class=""action $class"">"
        Add-Html "  <h3>$number. $(Encode $action.Title) <span class=""badge $class"">$(Encode $action.Impact)</span></h3>"
        Add-Html ("  <div class=""meta"">$(Encode $action.Category) &middot; effort: $(Encode $action.Effort) &middot; " +
            "risk: $(Encode $action.Safety)$(if ($action.Vendor) { " &middot; $(Encode $action.Vendor)" })</div>")
        Add-Html '  <dl>'
        Add-Html "    <dt>Measured</dt><dd>$(Encode $action.Evidence)</dd>"
        if ($action.Detail) { Add-Html "    <dt>What it is</dt><dd>$(Encode $action.Detail)</dd>" }
        Add-Html "    <dt>Do this</dt><dd>$(Encode $action.Recommendation)</dd>"
        if ($action.Gain) { Add-Html "    <dt>Expected gain</dt><dd>$(Encode $action.Gain)</dd>" }
        if ($action.Command) { Add-Html "    <dt>Command</dt><dd class=""cmd"">$(Encode $action.Command)</dd>" }
        Add-Html '  </dl></div>'
        $number++
    }
    Add-Html '</section>'
    #endregion

    #region Startup
    $enabled = @($Result.StartupItems | Where-Object { $_.Enabled } | Sort-Object MemoryBytes -Descending)
    if ($enabled.Count -gt 0) {
        Add-Html "<section><h2>Starts automatically ($($enabled.Count) entries)</h2><div class=""scroll""><table><thead><tr>"
        Add-Html '<th>Entry</th><th>What it is</th><th>Manufacturer</th><th>Where from</th><th>Impact</th><th class="num">Memory now</th></tr></thead><tbody>'
        foreach ($item in $enabled) {
            $class = $item.Impact.ToLowerInvariant()
            Add-Html ("  <tr><td><strong>$(Encode $item.Name)</strong><div class=""muted mono"">$(Encode $item.TargetPath)</div></td>" +
                "<td class=""muted"">$(Encode $item.Identity.Name)</td><td>$(Encode $item.Identity.Vendor)</td>" +
                "<td class=""muted"">$(Encode $item.Source)</td><td><span class=""badge $class"">$(Encode $item.Impact)</span></td>" +
                "<td class=""num"">$(Encode $item.MemoryText)</td></tr>")
        }
        Add-Html '</tbody></table></div></section>'
    }
    #endregion

    #region Scan limitations
    if (@($Result.ScanErrors).Count -gt 0) {
        Add-Html '<section><h2>Readings that could not be taken</h2><ul class="muted">'
        foreach ($item in @($Result.ScanErrors | Select-Object -Unique -First 25)) {
            Add-Html "  <li>$(Encode $item)</li>"
        }
        Add-Html '</ul></section>'
    }
    #endregion

    Add-Html @"
<footer>
  Memory is reported as the private working set where the performance counters could supply it,
  and as the whole working set otherwise; the whole working set counts pages shared between
  processes in a group more than once, so grouped totals are an upper bound.
  CPU percentages are of the whole machine, not of one core.
  Generated by ResourceMonitor $($script:RmoModuleVersion) on $generated.
</footer>
</div>
</body>
</html>
"@

    $html -join [Environment]::NewLine
}
