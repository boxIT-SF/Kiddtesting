function Get-RmoSystemHealthCheck {
    <#
        .SYNOPSIS
            Checks the things that make a machine slow without appearing in any process list.

        .DESCRIPTION
            Not every cause of an unusable machine is a process using something. A pending
            restart, a spinning system disk, a full system volume, a power plan capping the
            processor, two antivirus products fighting each other, 4 GB of RAM under an operating
            system that wants 8 - none of these show up as a resource hog, and several of them
            outweigh anything that does.

            Each check produces a finding with what was measured, what it means, and what to do,
            so the plan can order them against the process-level findings on the same scale.

        .PARAMETER System
            A snapshot from Get-RmoSystemSnapshot.

        .PARAMETER Pressure
            Pressure readings from Measure-RmoResourcePressure, so a finding can be raised or
            lowered by whether the resource it concerns is actually under strain.

        .PARAMETER StartupItem
            Entries from Get-RmoStartupItem, for the startup-cost checks.

        .PARAMETER Service
            Services from Get-RmoServiceLoad, for the automatic-start count.

        .PARAMETER Deep
            Also read the event log for crash, hang and unexpected-shutdown history. This is the
            slowest part of a complete scan and the most likely to find the real answer on a
            machine that is not merely slow but unreliable.

        .PARAMETER HistoryDays
            How far back the event log checks look.

        .PARAMETER ErrorSink
            Optional list for checks that could not be run.

        .EXAMPLE
            Get-RmoSystemHealthCheck -System $system -Pressure $pressure -Deep
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [psobject] $System,
        [Parameter(Mandatory)] [psobject] $Pressure,
        [AllowEmptyCollection()] [object[]] $StartupItem = @(),
        [AllowEmptyCollection()] [object[]] $Service = @(),
        [switch] $Deep,
        [ValidateRange(1, 90)] [int] $HistoryDays = 14,
        [System.Collections.IList] $ErrorSink
    )

    $findings = [System.Collections.Generic.List[object]]::new()

    function Add-RmoFinding {
        param(
            [string] $Id,
            [string] $Title,
            [ValidateSet('High', 'Medium', 'Low', 'Info')] [string] $Impact,
            [string] $Category,
            [string] $Evidence,
            [string] $Detail,
            [string] $Recommendation,
            [string] $Command = '',
            [ValidateSet('Instant', 'Quick', 'Planned', 'Hardware')] [string] $Effort = 'Quick',
            [ValidateSet('Safe', 'Review', 'Caution')] [string] $Safety = 'Safe',
            [string] $Gain = ''
        )

        $findings.Add([pscustomobject]@{
            PSTypeName     = 'Rmo.Finding'
            Id             = $Id
            Title          = $Title
            Impact         = $Impact
            Category       = $Category
            Evidence       = $Evidence
            Detail         = $Detail
            Recommendation = $Recommendation
            Command        = $Command
            Effort         = $Effort
            Safety         = $Safety
            Gain           = $Gain
            Source         = 'System'
        })
    }

    #region Pending restart
    $rebootReasons = [System.Collections.Generic.List[string]]::new()
    $rebootKeys = @{
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending' = 'Windows servicing has staged changes'
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired' = 'Windows Update is waiting to finish'
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootInProgress' = 'a servicing operation is part-way through'
    }
    foreach ($key in $rebootKeys.Keys) {
        if (Test-Path -LiteralPath $key -ErrorAction SilentlyContinue) { $rebootReasons.Add($rebootKeys[$key]) }
    }
    try {
        $sessionManager = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction Stop
        if ($sessionManager.PSObject.Properties['PendingFileRenameOperations']) {
            $rebootReasons.Add('files are queued to be replaced on the next restart')
        }
    } catch {
        Write-Verbose "Could not read Session Manager: $($_.Exception.Message)"
    }

    $uptimeSeconds = $System.Os.UptimeSeconds
    $uptimeText = Format-RmoDuration $uptimeSeconds

    if ($rebootReasons.Count -gt 0) {
        Add-RmoFinding -Id 'reboot-pending' -Title 'The machine is waiting for a restart' -Impact 'High' `
            -Category 'Maintenance' `
            -Evidence "Pending because $($rebootReasons -join ', '). Current uptime $uptimeText." `
            -Detail 'Until the restart happens, servicing keeps re-staging the same work, updates keep re-applying, and files that are queued for replacement stay locked. This is the single most common cause of a machine that is busy for no visible reason, and it makes every other measurement on this report less trustworthy.' `
            -Recommendation 'Restart the machine, then re-run the scan. Nothing else on this list is worth doing first.' `
            -Command 'Restart-Computer -Force' -Effort 'Instant' -Safety 'Review' `
            -Gain 'Removes the repeating servicing work and releases locked files'
    } elseif ($null -ne $uptimeSeconds -and $uptimeSeconds -gt (14 * 86400)) {
        Add-RmoFinding -Id 'uptime-long' -Title "The machine has been running for $uptimeText without a restart" -Impact 'Medium' `
            -Category 'Maintenance' `
            -Evidence "Uptime $uptimeText." `
            -Detail 'Long uptime is not a fault in itself, but leaks accumulate: handles, GDI objects, fragmented pool and drivers that never release memory. A machine that feels progressively slower through the week and is fine every Monday is describing exactly this.' `
            -Recommendation 'Restart, and if the improvement is obvious, note which process was largest before the restart - that is where the leak is.' `
            -Command 'Restart-Computer' -Effort 'Instant' -Safety 'Review' `
            -Gain 'Returns leaked memory and handles'
    }
    #endregion

    #region Storage
    $systemMedia = $Pressure.Disk.SystemDiskMedia
    if ($systemMedia -match '(?i)HDD') {
        $impact = if ($Pressure.Disk.Score -ge 60) { 'High' } else { 'Medium' }
        Add-RmoFinding -Id 'disk-mechanical' -Title 'Windows is installed on a mechanical hard disk' -Impact $impact `
            -Category 'Hardware' `
            -Evidence "System disk media type: $systemMedia. Measured latency $(if ($null -ne $Pressure.Disk.LatencyMs) { "$($Pressure.Disk.LatencyMs) ms per transfer" } else { 'not available' })." `
            -Detail 'A spinning disk serves a few hundred random operations per second; an SSD serves tens of thousands. Windows 10 and 11 both assume the latter - servicing, search indexing, antivirus scanning and paging all issue small random reads. No amount of software tuning closes that gap, and every other recommendation on this report will be limited by it.' `
            -Recommendation 'Replace the system disk with an SSD. On a machine that is otherwise adequate this is the single largest improvement available, and it is usually cheaper than the time spent working around it.' `
            -Effort 'Hardware' -Safety 'Review' `
            -Gain 'Typically transforms responsiveness: boot, sign-in and application launch all become several times faster'
    }

    foreach ($volume in $System.Volumes) {
        if ($null -eq $volume.FreePercent) { continue }
        if (-not $volume.IsSystem -and $volume.FreePercent -ge 5) { continue }
        if ($volume.FreePercent -lt 10) {
            $impact = if ($volume.FreePercent -lt 5) { 'High' } else { 'Medium' }
            Add-RmoFinding -Id "volume-full-$(ConvertTo-RmoSlug $volume.DriveLetter)" `
                -Title "Volume $($volume.DriveLetter) is $(100 - $volume.FreePercent)% full" -Impact $impact `
                -Category 'Storage' `
                -Evidence "$(Format-RmoBytes $volume.FreeBytes) free of $(Format-RmoBytes $volume.SizeBytes) ($($volume.FreePercent)%)." `
                -Detail 'Below roughly 10% free, Windows starts to struggle for reasons that have nothing to do with running out of room: the page file cannot expand, servicing has nowhere to stage updates, temporary files fail, and on a spinning disk writes fragment badly. On the system volume this alone can make a machine feel broken.' `
                -Recommendation 'Free space on this volume before doing anything else. Windows Update cleanup, the component store and old user profiles are usually where it has gone. Disk Cleanup (cleanmgr) run as administrator covers the first two.' `
                -Effort 'Quick' -Safety 'Review' `
                -Gain 'Restores headroom for paging, servicing and temporary files'
        }
    }
    #endregion

    #region Memory capacity
    $totalGb = if ($System.Memory.TotalBytes -gt 0) { [math]::Round($System.Memory.TotalBytes / 1GB, 1) } else { 0 }
    $isWindows11 = $System.Os.Caption -match '(?i)Windows 11'
    $threshold = if ($isWindows11) { 8 } else { 4 }

    if ($totalGb -gt 0 -and $totalGb -lt ($threshold + 0.5)) {
        Add-RmoFinding -Id 'memory-undersized' -Title "$totalGb GB of RAM is below what this build of Windows needs" -Impact 'High' `
            -Category 'Hardware' `
            -Evidence "$totalGb GB fitted. $(Format-RmoBytes $System.Memory.AvailableBytes) available at the time of the scan. Memory pressure score $($Pressure.Memory.Score)/100." `
            -Detail "Windows itself, the security agent and a browser will consume most of $totalGb GB before the person using the machine has opened anything of their own. Once memory runs out, Windows pages to disk, and a memory shortage becomes a disk problem - which is why these machines feel slow at everything rather than slow at one thing." `
            -Recommendation 'Add memory. This is the fix; everything else on this list is mitigation.' `
            -Effort 'Hardware' -Safety 'Review' `
            -Gain 'Stops the machine paging under normal use'
    }

    if ($System.Memory.TotalSlots -gt $System.Memory.UsedSlots -and $Pressure.Memory.Score -ge 70) {
        $moduleText = 'unknown'
        $firstModule = Get-RmoFirstOrDefault $System.Memory.Modules
        if ($null -ne $firstModule) {
            $moduleText = "$(Format-RmoBytes $firstModule.CapacityBytes) at $($firstModule.SpeedMhz) MHz"
            if ($firstModule.PartNumber) { $moduleText += " (part $($firstModule.PartNumber))" }
        }
        Add-RmoFinding -Id 'memory-slots-free' -Title 'There is a free memory slot and the machine is short of memory' -Impact 'Medium' `
            -Category 'Hardware' `
            -Evidence "$($System.Memory.UsedSlots) of $($System.Memory.TotalSlots) slots populated. Fitted module: $moduleText." `
            -Detail 'The machine can take more memory without replacing what is already in it, which makes this the cheapest hardware fix available. Match the speed and, where the board runs dual channel, the capacity of the existing module.' `
            -Recommendation "Fit a matching module in the free slot." `
            -Effort 'Hardware' -Safety 'Review' `
            -Gain 'Directly removes the measured memory pressure'
    }

    if ($System.Memory.TotalSlots -eq 0 -and $Pressure.Memory.Score -ge 80 -and $System.IsLaptop) {
        Add-RmoFinding -Id 'memory-soldered' -Title 'Memory may be soldered to the board' -Impact 'Info' `
            -Category 'Hardware' `
            -Evidence 'No memory slots were reported by firmware.' `
            -Detail 'Many current laptops have memory soldered on, which means the fitted amount is final. If that is the case here, the memory pressure on this machine can only be managed, not fixed.' `
            -Recommendation 'Confirm against the model specification. If memory is not expandable, prioritise the software reductions in this plan and plan a replacement rather than an upgrade.' `
            -Effort 'Planned' -Safety 'Safe'
    }
    #endregion

    #region Page file
    $pageFileTotal = 0
    foreach ($file in $System.PageFiles) { $pageFileTotal += $file.AllocatedBytes }
    if ($pageFileTotal -le 0 -and -not $System.AutomaticPageFile) {
        Add-RmoFinding -Id 'pagefile-disabled' -Title 'The page file is disabled' -Impact 'High' `
            -Category 'Configuration' `
            -Evidence 'No page file is allocated and the automatic setting is off.' `
            -Detail 'Turning the page file off does not make Windows faster. It removes the commit headroom the system needs, so allocations start failing outright: applications close with out-of-memory errors instead of slowing down, and crash dumps cannot be written. This is a change somebody made deliberately, following advice that has been wrong for twenty years.' `
            -Recommendation 'Return the page file to system managed.' `
            -Command 'Get-CimInstance Win32_ComputerSystem | Set-CimInstance -Property @{ AutomaticManagedPagefile = $true }' `
            -Effort 'Quick' -Safety 'Review' `
            -Gain 'Removes hard allocation failures under memory pressure'
    } elseif ($null -ne $Pressure.Memory.CommitPercent -and $Pressure.Memory.CommitPercent -ge 90) {
        Add-RmoFinding -Id 'commit-near-limit' -Title 'Commit charge is close to the limit' -Impact 'High' `
            -Category 'Configuration' `
            -Evidence "Committed $(Format-RmoBytes $Pressure.Memory.CommittedBytes) of a $(Format-RmoBytes $Pressure.Memory.CommitLimitBytes) limit ($($Pressure.Memory.CommitPercent)%)." `
            -Detail 'The commit limit is physical memory plus the page file. Reaching it does not slow the machine down, it stops allocations succeeding - applications fail or close rather than getting slower. A machine this close to the limit is minutes away from that.' `
            -Recommendation 'Reduce what is holding memory (see the plan), and let Windows manage the page file so the limit can grow.' `
            -Effort 'Quick' -Safety 'Safe' `
            -Gain 'Prevents allocation failures'
    }
    #endregion

    #region Power and clocks
    if ($System.PowerPlan.Name -match '(?i)power saver|energy saver|power efficiency') {
        Add-RmoFinding -Id 'power-plan-saver' -Title "The active power plan is '$($System.PowerPlan.Name)'" -Impact 'Medium' `
            -Category 'Configuration' `
            -Evidence "Active plan: $($System.PowerPlan.Name). Processor at $($System.Cpu.CurrentClockMhz) MHz of a $($System.Cpu.MaxClockMhz) MHz maximum." `
            -Detail 'A power-saving plan caps the maximum processor state, so the machine is deliberately running slower than the hardware allows. On a desktop there is nothing to save; on a laptop on mains power there is very little.' `
            -Recommendation 'Switch to Balanced, or to High performance on a desktop that is doing sustained work.' `
            -Command 'powercfg /setactive SCHEME_BALANCED' -Effort 'Instant' -Safety 'Safe' `
            -Gain 'Releases the processor speed the hardware already has'
    }

    if ($System.OnBattery -and $Pressure.Cpu.Score -ge 60) {
        Add-RmoFinding -Id 'on-battery' -Title 'The machine is running on battery while under load' -Impact 'Info' `
            -Category 'Configuration' `
            -Evidence "On battery$(if ($null -ne $System.BatteryPercent) { " at $($System.BatteryPercent)%" }). CPU pressure score $($Pressure.Cpu.Score)/100." `
            -Detail 'On battery, Windows and the firmware both cap the processor and the graphics adapter. Measurements taken now are not comparable with the same machine on mains power.' `
            -Recommendation 'Plug the machine in and re-measure before drawing conclusions about its speed.' `
            -Effort 'Instant' -Safety 'Safe'
    }

    if ($null -ne $Pressure.Cpu.ClockRatioPercent -and $Pressure.Cpu.ClockRatioPercent -lt 60 -and
        $Pressure.Cpu.Score -ge 60 -and -not $System.OnBattery) {
        Add-RmoFinding -Id 'cpu-throttled' -Title 'The processor is running well below its rated speed under load' -Impact 'High' `
            -Category 'Hardware' `
            -Evidence "Reported $($System.Cpu.CurrentClockMhz) MHz against a $($System.Cpu.MaxClockMhz) MHz maximum ($($Pressure.Cpu.ClockRatioPercent)%), with CPU pressure at $($Pressure.Cpu.Score)/100." `
            -Detail 'A processor that stays far below its rated clock while there is work waiting is being held back - by heat, by a firmware power limit, or by a power policy. Thermal throttling on an older laptop is usually dust in the heatsink and dried thermal paste, and it gets worse over years until the machine is unusable under any load.' `
            -Recommendation 'Check the power plan first, then have the cooling cleaned and the thermal paste replaced. Confirm against the vendor diagnostics before spending on anything else.' `
            -Effort 'Planned' -Safety 'Review' `
            -Gain 'Recovers the processor speed the machine is specified to deliver'
    }
    #endregion

    #region Antivirus overlap
    $realTime = @($System.Antivirus | Where-Object { $_.RealTimeEnabled })
    $thirdParty = @($realTime | Where-Object { $_.DisplayName -notmatch '(?i)windows defender|microsoft defender' })
    if ($realTime.Count -gt 1 -and $thirdParty.Count -ge 1) {
        $names = @($realTime | ForEach-Object { $_.DisplayName })
        Add-RmoFinding -Id 'av-overlap' -Title 'More than one antivirus product has real-time scanning switched on' -Impact 'High' `
            -Category 'Security' `
            -Evidence "Registered with real-time protection active: $($names -join '; ')." `
            -Detail 'Two real-time scanners inspect every file operation twice and then inspect each other. The result is a machine that is slow at everything involving the file system - opening documents, launching applications, building code - and protection that is no better than one product alone. Windows normally stands Defender down when a third-party product registers; where it has not, or where two third-party products are installed, this needs resolving.' `
            -Recommendation 'Decide which product the organisation manages and remove the other with its vendor removal tool. Removing an antivirus product is not the same as disabling it - a disabled one still has its filter driver loaded.' `
            -Effort 'Planned' -Safety 'Review' `
            -Gain 'Removes a duplicated scan from every file operation on the machine'
    }
    #endregion

    #region Graphics driver
    foreach ($adapter in $System.Graphics) {
        if ($adapter.Name -match '(?i)Microsoft Basic Display Adapter') {
            Add-RmoFinding -Id 'gpu-basic-driver' -Title 'The display is running on the Microsoft Basic Display Adapter' -Impact 'High' `
                -Category 'Configuration' `
                -Evidence "Adapter: $($adapter.Name)." `
                -Detail 'This is the fallback driver Windows uses when the real one is missing or has failed. Without it, all compositing falls back to the processor, which shows up as Desktop Window Manager and Explorer using CPU for work the graphics adapter should be doing, and makes even scrolling feel heavy.' `
                -Recommendation 'Install the graphics driver for this adapter from the machine vendor or the GPU vendor.' `
                -Effort 'Quick' -Safety 'Review' `
                -Gain 'Moves window compositing off the processor'
            continue
        }
        if ($null -ne $adapter.DriverAgeDays -and $adapter.DriverAgeDays -gt 1095 -and $adapter.Name) {
            Add-RmoFinding -Id "gpu-driver-old-$(ConvertTo-RmoSlug $adapter.Name)" -Title 'The graphics driver is over three years old' -Impact 'Low' `
                -Category 'Maintenance' `
                -Evidence "$($adapter.Name), driver $($adapter.DriverVersion) dated $([int] $adapter.DriverAgeDays) days ago." `
                -Detail 'Old display drivers are a common cause of high Desktop Window Manager CPU, of browsers falling back to software rendering, and of intermittent freezes. This is worth ruling out cheaply.' `
                -Recommendation 'Update the display driver from the machine or GPU vendor.' `
                -Effort 'Quick' -Safety 'Review'
        }
    }
    #endregion

    #region How much starts itself
    $enabledStartup = @($StartupItem | Where-Object { $_.Enabled })
    $runningStartup = @($enabledStartup | Where-Object { $_.Running })
    $startupMemory = 0
    foreach ($item in $runningStartup) { $startupMemory += $item.MemoryBytes }

    if ($enabledStartup.Count -ge 12) {
        Add-RmoFinding -Id 'startup-crowded' -Title "$($enabledStartup.Count) programs start themselves on this machine" -Impact 'Medium' `
            -Category 'Startup' `
            -Evidence "$($enabledStartup.Count) enabled startup entries, $($runningStartup.Count) of them running now and holding $(Format-RmoBytes $startupMemory)." `
            -Detail 'Everything in this list competes for the disk and the processor during the first minutes after sign-in, which is exactly when the person using the machine is trying to start work. Most of it then stays resident all day for the sake of a tray icon and an update check.' `
            -Recommendation 'Work through the startup list in this report. Anything that is not a security agent, a management agent, or something the person uses every day can be started on demand instead.' `
            -Effort 'Quick' -Safety 'Review' `
            -Gain "Up to $(Format-RmoBytes $startupMemory) of memory and a faster sign-in"
    }

    $autoServices = @($Service | Where-Object { $_.StartMode -eq 'Auto' -and -not $_.DelayedAutoStart })
    if ($autoServices.Count -ge 90) {
        Add-RmoFinding -Id 'services-many-auto' -Title "$($autoServices.Count) services start automatically without delay" -Impact 'Low' `
            -Category 'Startup' `
            -Evidence "$($autoServices.Count) services set to Automatic (not delayed), out of $(@($Service).Count) installed." `
            -Detail 'Every non-delayed automatic service has to start before the machine settles. A high count is usually accumulated software rather than a deliberate configuration.' `
            -Recommendation 'Look for services belonging to software that is no longer used, and uninstall the software rather than disabling the service.' `
            -Effort 'Planned' -Safety 'Review'
    }
    #endregion

    #region Windows 10 support
    if ($System.Os.Caption -match '(?i)Windows 10' -and $System.Os.Caption -notmatch '(?i)Server|LTSC|Enterprise LTS') {
        Add-RmoFinding -Id 'os-windows10-eol' -Title 'This machine is running Windows 10' -Impact 'Info' `
            -Category 'Maintenance' `
            -Evidence "$($System.Os.Caption), build $($System.Os.BuildNumber)." `
            -Detail 'Mainstream support for Windows 10 ended on 14 October 2025. Outside an extended security update arrangement or an LTSC edition, the machine is no longer receiving normal updates. This is not a performance finding, but it belongs in any assessment of whether to spend money on the machine.' `
            -Recommendation 'Check the upgrade path to Windows 11, or the extended security update position, before investing in hardware for this machine.' `
            -Effort 'Planned' -Safety 'Safe'
    }
    #endregion

    #region Crash, hang and shutdown history
    if ($Deep) {
        $since = [datetime]::Now.AddDays(-$HistoryDays)
        $eventChecks = @(
            [pscustomobject]@{
                Id = 'history-bugcheck'; LogName = 'System'; EventId = @(1001, 41)
                Provider = @('Microsoft-Windows-WER-SystemErrorReporting', 'Microsoft-Windows-Kernel-Power')
                Title = 'The machine has been crashing or losing power unexpectedly'
                Impact = 'High'; Threshold = 1
                Detail = 'A bug check (blue screen) or an unexpected power loss is a driver, firmware or hardware fault. A machine doing this is not slow, it is failing, and performance tuning is the wrong response.'
                Recommendation = 'Read the bug check codes from the event log or a memory dump, then update the storage, network and chipset drivers and the firmware. Test the memory if the code points that way.'
            }
            [pscustomobject]@{
                Id = 'history-apphang'; LogName = 'Application'; EventId = @(1002)
                Provider = @('Application Hang')
                Title = 'Applications are hanging repeatedly'
                Impact = 'Medium'; Threshold = 5
                Detail = 'A hang is a program that stopped responding rather than one that crashed. Repeated hangs in the same program point at that program or at something it waits on - a network share, a printer, a database, an add-in.'
                Recommendation = 'Identify the program from the event detail. If they cluster on one application, treat it as that application''s problem rather than the machine''s.'
            }
            [pscustomobject]@{
                Id = 'history-appcrash'; LogName = 'Application'; EventId = @(1000)
                Provider = @('Application Error')
                Title = 'Applications are crashing repeatedly'
                Impact = 'Medium'; Threshold = 10
                Detail = 'Repeated crashes cost real time: the work is lost, error reporting captures a dump each time, and the same program is started again. A crash loop can account for a surprising share of a machine''s disk and CPU activity.'
                Recommendation = 'Identify the faulting module from the event detail. A crash in a third-party DLL loaded into several programs - a shell extension, an add-in, an old runtime - explains a machine that seems to crash at everything.'
            }
        )

        foreach ($check in $eventChecks) {
            try {
                $filter = @{ LogName = $check.LogName; StartTime = $since; Id = $check.EventId }
                $events = @(Get-WinEvent -FilterHashtable $filter -MaxEvents 400 -ErrorAction Stop)
                $events = @($events | Where-Object { $_.ProviderName -in $check.Provider })
                if ($events.Count -lt $check.Threshold) { continue }

                $grouped = @($events | Group-Object -Property {
                    if ($_.Properties.Count -gt 0) { [string] $_.Properties[0].Value } else { 'unknown' }
                } | Sort-Object Count -Descending | Select-Object -First 4)
                $breakdown = @($grouped | ForEach-Object { "$($_.Name) x$($_.Count)" }) -join '; '
                $latest = $events[0].TimeCreated

                Add-RmoFinding -Id $check.Id -Title $check.Title -Impact $check.Impact -Category 'Reliability' `
                    -Evidence "$($events.Count) events in the last $HistoryDays days, most recent $latest. Most frequent: $breakdown." `
                    -Detail $check.Detail -Recommendation $check.Recommendation `
                    -Effort 'Planned' -Safety 'Safe'
            } catch [System.Exception] {
                # No matching events is reported as an error by Get-WinEvent, which is not a
                # failure - it is the answer we wanted.
                if ($_.Exception.Message -notmatch 'No events were found') {
                    $message = "Could not read the $($check.LogName) log for $($check.Id): $($_.Exception.Message)"
                    Write-Verbose $message
                    if ($null -ne $ErrorSink) { $null = $ErrorSink.Add($message) }
                }
            }
        }
    }
    #endregion

    @($findings)
}
