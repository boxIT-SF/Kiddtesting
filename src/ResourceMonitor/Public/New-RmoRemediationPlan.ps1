function New-RmoRemediationPlan {
    <#
        .SYNOPSIS
            Turns the measurements into an ordered plan for making the machine usable.

        .DESCRIPTION
            Everything measured is scored against the constraint the machine is actually under.
            That matters, because the same reading means different things on different machines:
            a browser holding 3 GB is the headline on a 8 GB laptop that is paging, and a
            footnote on a 64 GB workstation that is waiting on its disk.

            Actions come from three places and are ranked on one scale:

              Processes      products consuming a significant share of the constrained resource.
              Startup        what launches itself, weighted by what it is costing right now.
              The system     restarts, storage, power policy, antivirus overlap, memory capacity
                             and reliability history from Get-RmoSystemHealthCheck.

            The order is impact, then how safe the change is, then how much work it is - so
            equally useful actions are offered from the safe, quick end first. Nothing is ever
            proposed against a process the catalogue marks essential: for those, the action is
            the supported way to reduce what is driving it, never stopping it.

        .PARAMETER System
            A snapshot from Get-RmoSystemSnapshot.

        .PARAMETER Pressure
            Readings from Measure-RmoResourcePressure.

        .PARAMETER Hogs
            Rankings from Get-RmoResourceHog.

        .PARAMETER StartupItem
            Entries from Get-RmoStartupItem.

        .PARAMETER Finding
            System findings from Get-RmoSystemHealthCheck.

        .PARAMETER ScanMode
            'Quick' or 'Complete'. Recorded on the plan and used in the caveats.

        .EXAMPLE
            New-RmoRemediationPlan -System $system -Pressure $pressure -Hogs $hogs -ScanMode Complete
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory)] [psobject] $System,
        [Parameter(Mandatory)] [psobject] $Pressure,
        [Parameter(Mandatory)] [psobject] $Hogs,
        [AllowEmptyCollection()] [object[]] $StartupItem = @(),
        [AllowEmptyCollection()] [object[]] $Finding = @(),
        [ValidateSet('Quick', 'Complete')] [string] $ScanMode = 'Quick'
    )

    $actions = [System.Collections.Generic.List[object]]::new()
    $totalMemory = [double] $System.Memory.TotalBytes
    $primary = $Pressure.Bottleneck.Primary

    # What counts as "worth naming" scales with the machine. Four percent of memory is a
    # meaningful share on any machine; a fixed number of megabytes is not.
    # Both operands are cast to double: [math]::Max would otherwise resolve to its Int32
    # overload against the integer literal and overflow on any machine with real memory in it.
    $memorySignificant = [math]::Max([double] 300MB, [double] ($totalMemory * 0.04))
    $memoryLarge = [math]::Max([double] 1GB, [double] ($totalMemory * 0.12))

    function Add-RmoAction {
        param(
            [string] $Id, [string] $Title,
            [ValidateSet('High', 'Medium', 'Low', 'Info')] [string] $Impact,
            [string] $Category, [string] $Source,
            [string] $Evidence, [string] $Detail, [string] $Recommendation,
            [string] $Command = '',
            [ValidateSet('Instant', 'Quick', 'Planned', 'Hardware')] [string] $Effort = 'Quick',
            [ValidateSet('Safe', 'Review', 'Caution')] [string] $Safety = 'Review',
            [string] $Gain = '',
            [string] $Family = '', [string] $Vendor = '', [string] $Class = '',
            [double] $MemoryBytes = 0, [AllowNull()] [System.Nullable[double]] $CpuPercent = $null,
            [double] $DiskBytesPerSecond = 0,
            [bool] $Recoverable = $false
        )

        $weight = ($MemoryBytes / 1MB) +
                  ($(if ($null -ne $CpuPercent) { [double] $CpuPercent } else { 0 }) * 50) +
                  ($DiskBytesPerSecond / 1MB * 10)

        $actions.Add([pscustomobject]@{
            PSTypeName         = 'Rmo.PlanAction'
            Id                 = $Id
            Title              = $Title
            Impact             = $Impact
            Category           = $Category
            Source             = $Source
            Evidence           = $Evidence
            Detail             = $Detail
            Recommendation     = $Recommendation
            Command            = $Command
            Effort             = $Effort
            Safety             = $Safety
            Gain               = $Gain
            Family             = $Family
            Vendor             = $Vendor
            Class              = $Class
            MemoryBytes        = $MemoryBytes
            MemoryText         = $(if ($MemoryBytes -gt 0) { Format-RmoBytes $MemoryBytes } else { '' })
            CpuPercent         = $CpuPercent
            DiskBytesPerSecond = $DiskBytesPerSecond
            Recoverable        = $Recoverable
            Weight             = $weight
        })
    }

    #region Products consuming the constrained resource
    foreach ($family in $Hogs.Families) {
        $memory = [double] $family.MemoryBytes
        $cpu = $(if ($family.CpuMeasured) { [double] $family.CpuPercent } else { $null })
        $disk = [double] $family.DiskBytesPerSecond

        $memoryNotable = $memory -ge $memorySignificant
        $cpuNotable = ($null -ne $cpu -and $cpu -ge 4)
        $diskNotable = $disk -ge 3MB
        $unwanted = ($family.Class -eq 'Unwanted')

        if (-not ($memoryNotable -or $cpuNotable -or $diskNotable -or $unwanted)) { continue }

        # Rate on the resource the machine is actually short of. A product holding memory on a
        # machine that has plenty of it is information, not a problem.
        $impact = 'Low'
        $onCriticalPath = switch ($primary) {
            'CPU'     { $cpuNotable }
            'Memory'  { $memoryNotable }
            'Disk'    { $diskNotable }
            'Network' { $false }
            default   { $false }
        }
        if ($memory -ge $memoryLarge -or ($null -ne $cpu -and $cpu -ge 15) -or $disk -ge 20MB) {
            $impact = if ($onCriticalPath) { 'High' } else { 'Medium' }
        } elseif ($memoryNotable -or $cpuNotable -or $diskNotable) {
            $impact = if ($onCriticalPath) { 'Medium' } else { 'Low' }
        }
        # Software whose whole purpose is to slow machines down is always worth removing, but
        # calling a 40 MB tray icon high-impact devalues the word. It earns High once it is
        # actually consuming something, or where the machine is already constrained.
        if ($unwanted) {
            $impact = if ($memoryNotable -or $cpuNotable -or $diskNotable -or $primary -ne 'None') { 'High' } else { 'Medium' }
        }

        $evidenceParts = [System.Collections.Generic.List[string]]::new()
        $evidenceParts.Add("$($family.MemoryText) memory ($($family.MemoryMetric))")
        if ($null -ne $cpu) { $evidenceParts.Add("$($family.CpuText) of total CPU") }
        if ($disk -gt 0) { $evidenceParts.Add("$($family.DiskText) disk") }
        if ($family.ProcessCount -gt 1) { $evidenceParts.Add("$($family.ProcessCount) processes") }
        if ($null -ne $family.MemorySharePercent) { $evidenceParts.Add("$($family.MemorySharePercent)% of fitted memory") }
        # An entry covering a family of products - browsers, optimisers, game launchers - is
        # named for the family, so the reader needs to be told which member of it is running.
        if ($family.ProcessNameText -and $family.ProcessNameText -ne $family.Family) {
            $evidenceParts.Add("running as $($family.ProcessNameText)")
        }
        $evidence = $evidenceParts -join ', '

        $detailParts = [System.Collections.Generic.List[string]]::new()
        if ($family.Description) { $detailParts.Add($family.Description) }
        if ($family.Expected) { $detailParts.Add("What normal looks like: $($family.Expected)") }
        if ($family.Confidence -in 'Generic', 'File metadata', 'Unknown') {
            $detailParts.Add('This product is not in the catalogue, so the description above comes from the executable itself rather than from a curated entry.')
        }

        if ($family.Essential) {
            # Essential software gets an explanation and the supported way to reduce what drives
            # it. It never gets a proposal to stop it, and never a command that would.
            if ($impact -eq 'High') { $impact = 'Medium' }
            $recommendation = if ($family.Guidance) {
                $family.Guidance
            } else {
                'Part of Windows. Reduce what is driving it rather than the component itself.'
            }
            Add-RmoAction -Id "process-$(ConvertTo-RmoSlug $family.Family)" -Title "$($family.Family) is a top consumer, and is part of Windows" `
                -Impact $impact -Category 'Windows component' -Source 'Process' `
                -Evidence $evidence -Detail ($detailParts -join ' ') -Recommendation $recommendation `
                -Effort 'Quick' -Safety 'Caution' -Family $family.Family -Vendor $family.Vendor -Class $family.Class `
                -MemoryBytes $memory -CpuPercent $cpu -DiskBytesPerSecond $disk `
                -Gain 'Reduces the work reaching a component that cannot be removed'
            continue
        }

        # Quote the resource this product is actually consuming most of. Falling through to a
        # figure it does not have produces sentences like 'removes up to - of disk activity'.
        $gain = if ($memory -ge $memorySignificant) {
            "Frees up to $($family.MemoryText) of memory"
        } elseif ($null -ne $cpu -and $cpu -ge 4) {
            "Returns up to $($family.CpuText) of the processor"
        } elseif ($disk -ge 3MB) {
            "Removes up to $($family.DiskText) of disk activity"
        } elseif ($unwanted) {
            "Frees $($family.MemoryText) now, and removes its scheduled scans and background checks"
        } else {
            "Frees $($family.MemoryText)"
        }

        $safety = if ($unwanted) { 'Safe' } else { 'Review' }
        $effort = if ($unwanted) { 'Planned' } else { 'Quick' }

        Add-RmoAction -Id "process-$(ConvertTo-RmoSlug $family.Family)" -Title "$($family.Family) - $($family.Vendor)" `
            -Impact $impact -Category $(if ($unwanted) { 'Unwanted software' } else { $family.Class }) -Source 'Process' `
            -Evidence $evidence -Detail ($detailParts -join ' ') `
            -Recommendation $(if ($family.Guidance) { $family.Guidance } else { 'Decide whether this needs to be running all the time on this machine.' }) `
            -Command $family.Command -Effort $effort -Safety $safety -Gain $gain `
            -Family $family.Family -Vendor $family.Vendor -Class $family.Class `
            -MemoryBytes $memory -CpuPercent $cpu -DiskBytesPerSecond $disk -Recoverable $true
    }
    #endregion

    #region Startup entries
    foreach ($item in @($StartupItem | Where-Object { $_.Enabled -and $_.Impact -in 'High', 'Medium' } |
                        Sort-Object MemoryBytes -Descending)) {
        if ($item.Identity.Essential) { continue }
        $detail = $item.Identity.Description
        if ($item.Note) { $detail = "$detail $($item.Note)" }

        Add-RmoAction -Id "startup-$(ConvertTo-RmoSlug $item.Name)" `
            -Title "'$($item.Name)' starts itself and is running now" `
            -Impact $item.Impact -Category 'Startup' -Source 'Startup' `
            -Evidence "$($item.Source), $($item.Location). Currently $($item.MemoryText) memory, $($item.CpuText) CPU across $($item.InstanceCount) process(es)." `
            -Detail $detail `
            -Recommendation "Stop it starting automatically if the person using this machine does not need it every day. It can still be launched when it is wanted. $($item.Identity.Guidance)" `
            -Effort 'Quick' -Safety 'Review' `
            -Gain "Frees $($item.MemoryText) and shortens sign-in" `
            -Family $item.Identity.Family -Vendor $item.Identity.Vendor -Class $item.Identity.Class `
            -MemoryBytes $item.MemoryBytes -CpuPercent $item.CpuPercent -Recoverable $true
    }
    #endregion

    #region Things worth acting on regardless of rank
    if ($Pressure.Cpu.UnattributedPercent -ge 15) {
        Add-RmoAction -Id 'cpu-unattributed' -Title 'A large share of processor time belongs to a driver, not to any program' `
            -Impact 'High' -Category 'Drivers' -Source 'System' `
            -Evidence "$(Format-RmoPercent $Pressure.Cpu.UnattributedPercent) of processor time is unattributed$(if ($null -ne $Pressure.Cpu.InterruptPercent) { ", of which $(Format-RmoPercent $Pressure.Cpu.InterruptPercent) is interrupt handling" })." `
            -Detail 'Interrupt and deferred-procedure-call time is charged to no process, because it is driver code running on behalf of hardware. Storage, network and audio drivers are the usual sources, and a failing disk produces it as retries. This is the one category of CPU use that closing applications cannot touch.' `
            -Recommendation 'Update the storage, network, chipset and audio drivers from the machine vendor, and check the system event log for disk warnings. On a laptop, an old Wi-Fi driver is the most common single cause.' `
            -Effort 'Planned' -Safety 'Review' `
            -Gain "Recovers up to $(Format-RmoPercent $Pressure.Cpu.UnattributedPercent) of the processor"
    }

    foreach ($item in @($Hogs.Unresponsive | Select-Object -First 5)) {
        Add-RmoAction -Id "unresponsive-$($item.ProcessId)" `
            -Title "$($item.Identity.Name) has a window that has stopped responding" `
            -Impact 'High' -Category 'Reliability' -Source 'Process' `
            -Evidence "Process $($item.ProcessId), window '$($item.MainWindowTitle)', $($item.MemoryText) memory, running for $($item.AgeText)." `
            -Detail "This is the thing the person using the machine is complaining about, whatever the resource figures say. A window stops responding because its main thread is blocked - commonly on a network share, a printer, a database or a stuck add-in - not usually because the machine is out of capacity. Published by $($item.Identity.Vendor)." `
            -Recommendation 'Find what it is waiting on before ending it: a disconnected mapped drive, an unreachable printer or a slow server explains most hangs, and ending the process only postpones it.' `
            -Effort 'Instant' -Safety 'Caution' `
            -Family $item.Identity.Family -Vendor $item.Identity.Vendor -Class $item.Identity.Class `
            -MemoryBytes $item.MemoryBytes -CpuPercent $item.CpuPercent
    }

    foreach ($item in @($Hogs.TopHandles | Select-Object -First 3)) {
        if ($item.HandleCount -lt 20000) { continue }
        Add-RmoAction -Id "handles-$($item.ProcessId)" `
            -Title "$($item.Identity.Name) is holding $('{0:N0}' -f $item.HandleCount) handles" `
            -Impact 'Medium' -Category 'Reliability' -Source 'Process' `
            -Evidence "$('{0:N0}' -f $item.HandleCount) handles, $('{0:N0}' -f $item.ThreadCount) threads, $($item.MemoryText) memory, running for $($item.AgeText)." `
            -Detail 'A handle count this high on a desktop process is a leak in progress. It ends in a process that stops working and has to be restarted, and on the way there it consumes kernel pool, which is a resource the whole machine shares.' `
            -Recommendation "Restart this process, and note whether the count climbs again from a low base - that confirms the leak. If it does, the fix is a newer version of $($item.Identity.Vendor)'s software, not a scheduled restart." `
            -Effort 'Instant' -Safety 'Caution' `
            -Family $item.Identity.Family -Vendor $item.Identity.Vendor -Class $item.Identity.Class `
            -MemoryBytes $item.MemoryBytes -CpuPercent $item.CpuPercent
    }

    foreach ($item in @($Hogs.Suspicious | Select-Object -First 5)) {
        Add-RmoAction -Id "unidentified-$($item.ProcessId)" `
            -Title "Unidentified program consuming resources from a user-writable location" `
            -Impact 'High' -Category 'Security' -Source 'Process' `
            -Evidence "$($item.Name) (process $($item.ProcessId)) at $($item.ExecutablePath). $($item.MemoryText) memory, $($item.CpuText) CPU. Signature: $($item.Identity.SignatureStatus). No publisher could be determined." `
            -Detail 'Not in the catalogue, carrying no usable publisher information, unsigned, and running from a folder any user can write to. Plenty of legitimate software installs per-user into AppData, so this is not a verdict - but of the things that look like this, the ones that matter are miners, adware and remote access tools, and all three present exactly this way.' `
            -Recommendation 'Identify it before changing anything: check the full path and command line, and submit the file hash to the endpoint security console. If the organisation has an incident process, this belongs there rather than in a performance fix.' `
            -Effort 'Quick' -Safety 'Caution' `
            -Family $item.Identity.Family -Vendor $item.Identity.Vendor -Class 'Unknown' `
            -MemoryBytes $item.MemoryBytes -CpuPercent $item.CpuPercent
    }
    #endregion

    #region System findings
    foreach ($item in $Finding) {
        Add-RmoAction -Id $item.Id -Title $item.Title -Impact $item.Impact -Category $item.Category `
            -Source 'System' -Evidence $item.Evidence -Detail $item.Detail `
            -Recommendation $item.Recommendation -Command $item.Command -Effort $item.Effort `
            -Safety $item.Safety -Gain $item.Gain
    }
    #endregion

    #region Order, and total up what is recoverable
    $ordered = @($actions | Sort-Object `
        @{ Expression = { Get-RmoImpactRank $_.Impact } }, `
        @{ Expression = { Get-RmoSafetyRank $_.Safety } }, `
        @{ Expression = { Get-RmoEffortRank $_.Effort } }, `
        @{ Expression = { $_.Weight }; Descending = $true })

    $recoverableMemory = 0
    $recoverableCpu = 0
    foreach ($action in $ordered) {
        if (-not $action.Recoverable) { continue }
        if ($action.Safety -eq 'Caution') { continue }
        # Startup and process actions can describe the same software. Counting both would
        # promise the memory twice.
        if ($action.Source -eq 'Startup') { continue }
        $recoverableMemory += $action.MemoryBytes
        if ($null -ne $action.CpuPercent) { $recoverableCpu += $action.CpuPercent }
    }

    $counts = @{}
    foreach ($level in 'High', 'Medium', 'Low', 'Info') {
        $counts[$level] = @($ordered | Where-Object { $_.Impact -eq $level }).Count
    }
    #endregion

    $narrative = New-RmoPlanNarrative -System $System -Pressure $Pressure -Hogs $Hogs -Action $ordered -ScanMode $ScanMode

    [pscustomobject]@{
        PSTypeName             = 'Rmo.RemediationPlan'
        ScanMode               = $ScanMode
        Bottleneck             = $Pressure.Bottleneck.Primary
        SecondaryConstraint    = $Pressure.Bottleneck.Secondary
        Narrative              = $narrative
        NarrativeText          = ($narrative -join [Environment]::NewLine)
        Actions                = $ordered
        HighImpactCount        = $counts['High']
        MediumImpactCount      = $counts['Medium']
        LowImpactCount         = $counts['Low']
        InfoCount              = $counts['Info']
        RecoverableMemoryBytes = $recoverableMemory
        RecoverableMemoryText  = Format-RmoBytes $recoverableMemory
        RecoverableCpuPercent  = [math]::Round((Limit-RmoValue $recoverableCpu 0 100), 1)
    }
}
