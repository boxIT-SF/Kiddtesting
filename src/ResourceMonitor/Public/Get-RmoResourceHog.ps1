function Get-RmoResourceHog {
    <#
        .SYNOPSIS
            Ranks what is consuming the machine, per process and per product.

        .DESCRIPTION
            Two views of the same data, because a process list alone misleads:

              Per process   the individual heaviest processes, which is what a person watching
                            Task Manager sees.
              Per product   the same processes grouped by what they belong to. Thirty browser
                            processes at 300 MB are not thirty problems, they are one 9 GB
                            problem, and only the grouped view says so.

            Memory is reported from the private working set where the performance counters could
            supply it, because that is memory this process alone is holding. Where they could
            not, the whole working set is used, and the metric is named in the output - the
            distinction matters when adding up a family, since the whole working set counts pages
            shared between its members more than once.

            Also picks out three things worth seeing regardless of rank: processes with a window
            that has stopped responding, processes holding an unusual number of handles (a leak
            in progress), and unidentified unsigned executables consuming resources from
            locations any user can write to.

        .PARAMETER Process
            Samples from Get-RmoProcessSample.

        .PARAMETER TopCount
            Rows to keep in each table.

        .PARAMETER SystemMemoryBytes
            Total physical memory, used to express each consumer as a share of the machine.

        .EXAMPLE
            $hogs = Get-RmoResourceHog -Process $processes -SystemMemoryBytes $system.Memory.TotalBytes
            $hogs.Families | Select-Object -First 5 Family, MemoryText, CpuText
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory, Position = 0)] [AllowEmptyCollection()] [object[]] $Process,
        [ValidateRange(1, 500)] [int] $TopCount = 15,
        [double] $SystemMemoryBytes = 0
    )

    #region Decorate each process with the figures the tables display
    $rows = foreach ($item in $Process) {
        $usePrivate = $null -ne $item.PrivateWorkingSetBytes -and $item.PrivateWorkingSetBytes -gt 0
        $memoryBytes = if ($usePrivate) { [double] $item.PrivateWorkingSetBytes } else { [double] $item.WorkingSetBytes }
        $sharePercent = if ($SystemMemoryBytes -gt 0) { [math]::Round(($memoryBytes / $SystemMemoryBytes) * 100, 1) } else { $null }

        $serviceText = ''
        if (@($item.Services).Count -gt 0) {
            $names = @($item.Services | ForEach-Object { $_.DisplayName })
            $serviceText = $names -join ', '
        } elseif ($item.ServiceGroup) {
            $serviceText = "service group '$($item.ServiceGroup)'"
        }

        $metric = if ($usePrivate) { 'Private working set' } else { 'Working set' }
        $decorations = @{
            MemoryBytes        = $memoryBytes
            MemoryMetric       = $metric
            MemorySharePercent = $sharePercent
            CpuText            = Format-RmoPercent $item.CpuPercent
            MemoryText         = Format-RmoBytes $memoryBytes
            DiskText           = Format-RmoRate $item.IoBytesPerSecond
            ServiceText        = $serviceText
            AgeText            = Format-RmoDuration $item.AgeSeconds
        }
        foreach ($property in $decorations.Keys) {
            $item | Add-Member -NotePropertyName $property -NotePropertyValue $decorations[$property] -Force
        }
        $item
    }
    $rows = @($rows)
    #endregion

    #region Group by product
    $groups = @{}
    foreach ($item in $rows) {
        $key = $item.Identity.Family
        if ([string]::IsNullOrWhiteSpace($key)) { $key = $item.Name }
        if (-not $groups.ContainsKey($key)) {
            $groups[$key] = [pscustomobject]@{
                PSTypeName             = 'Rmo.ResourceFamily'
                Family                 = $key
                Vendor                 = $item.Identity.Vendor
                Class                  = $item.Identity.Class
                Essential              = $item.Identity.Essential
                Description            = $item.Identity.Description
                Expected               = $item.Identity.Expected
                Guidance               = $item.Identity.Guidance
                Command                = $item.Identity.Command
                Confidence             = $item.Identity.Confidence
                ProcessCount           = 0
                CpuPercent             = [double] 0
                CpuMeasured            = $false
                MemoryBytes            = [double] 0
                MemoryMetric           = $item.MemoryMetric
                MemorySharePercent     = $null
                DiskBytesPerSecond     = [double] 0
                HandleCount            = 0
                ThreadCount            = 0
                Members                = ([System.Collections.Generic.List[object]]::new())
                ProcessNames           = ([System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase))
            }
        }
        $group = $groups[$key]
        $group.ProcessCount++
        if ($null -ne $item.CpuPercent) {
            $group.CpuPercent += $item.CpuPercent
            $group.CpuMeasured = $true
        }
        $group.MemoryBytes += $item.MemoryBytes
        if ($null -ne $item.IoBytesPerSecond) { $group.DiskBytesPerSecond += $item.IoBytesPerSecond }
        $group.HandleCount += $item.HandleCount
        $group.ThreadCount += $item.ThreadCount
        $group.Members.Add($item)
        $null = $group.ProcessNames.Add($item.Name)
        # A group mixing both memory metrics cannot honestly claim either, so say so.
        if ($group.MemoryMetric -ne $item.MemoryMetric) { $group.MemoryMetric = 'Mixed' }
    }

    $families = foreach ($group in $groups.Values) {
        $group.MemorySharePercent = $(if ($SystemMemoryBytes -gt 0) { [math]::Round(($group.MemoryBytes / $SystemMemoryBytes) * 100, 1) } else { $null })
        $top = @($group.Members | Sort-Object MemoryBytes -Descending | Select-Object -First 5)
        $group | Add-Member -NotePropertyName TopMembers -NotePropertyValue $top -Force
        $group | Add-Member -NotePropertyName CpuText -NotePropertyValue $(if ($group.CpuMeasured) { Format-RmoPercent $group.CpuPercent } else { 'n/a' }) -Force
        $group | Add-Member -NotePropertyName MemoryText -NotePropertyValue (Format-RmoBytes $group.MemoryBytes) -Force
        $group | Add-Member -NotePropertyName DiskText -NotePropertyValue (Format-RmoRate $group.DiskBytesPerSecond) -Force
        $group | Add-Member -NotePropertyName ProcessNameText -NotePropertyValue (@($group.ProcessNames) -join ', ') -Force
        $group
    }
    $families = @($families)
    #endregion

    #region The things worth seeing regardless of rank
    $unresponsive = @($rows | Where-Object { -not $_.Responding -and $_.MainWindowTitle } |
        Sort-Object MemoryBytes -Descending)

    # A process holding more than ten thousand handles is either a server or leaking. Either way
    # it is worth naming, because a handle leak ends in a process that has to be restarted.
    $handleLeaks = @($rows | Where-Object { $_.HandleCount -gt 10000 } |
        Sort-Object HandleCount -Descending | Select-Object -First $TopCount)

    $suspicious = @($rows | Where-Object {
        $_.Identity.Confidence -in 'Unknown', 'File metadata', 'Generic' -and
        $_.Identity.Vendor -eq 'Unknown' -and
        (Test-RmoUserWritablePath $_.ExecutablePath) -and
        (($null -ne $_.CpuPercent -and $_.CpuPercent -ge 1) -or $_.MemoryBytes -ge 100MB)
    } | Sort-Object MemoryBytes -Descending)
    #endregion

    [pscustomobject]@{
        PSTypeName       = 'Rmo.ResourceHogs'
        Processes        = $rows
        TopCpu           = @($rows | Where-Object { $null -ne $_.CpuPercent -and $_.CpuPercent -gt 0 } |
                              Sort-Object CpuPercent -Descending | Select-Object -First $TopCount)
        TopMemory        = @($rows | Sort-Object MemoryBytes -Descending | Select-Object -First $TopCount)
        TopDisk          = @($rows | Where-Object { $null -ne $_.IoBytesPerSecond -and $_.IoBytesPerSecond -gt 0 } |
                              Sort-Object IoBytesPerSecond -Descending | Select-Object -First $TopCount)
        TopHandles       = $handleLeaks
        Families         = @($families | Sort-Object MemoryBytes -Descending)
        TopFamilyCpu     = @($families | Where-Object CpuMeasured | Sort-Object CpuPercent -Descending | Select-Object -First $TopCount)
        TopFamilyMemory  = @($families | Sort-Object MemoryBytes -Descending | Select-Object -First $TopCount)
        Unresponsive     = $unresponsive
        Suspicious       = $suspicious
    }
}
