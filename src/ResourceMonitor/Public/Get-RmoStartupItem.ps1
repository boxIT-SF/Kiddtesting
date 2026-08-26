function Get-RmoStartupItem {
    <#
        .SYNOPSIS
            Lists everything that launches itself when the machine starts or the user signs in.

        .DESCRIPTION
            Startup is where "the computer is slow" usually begins. Each entry costs time before
            the desktop is usable, and most of them then stay resident for the rest of the day.

            Four places are covered:

              Run keys and startup folders   read through Win32_StartupCommand, which
                                             consolidates the machine and per-user locations,
                                             then cross-referenced with the Explorer
                                             StartupApproved keys so that entries a user has
                                             already turned off in Task Manager are not counted
                                             against them.
              Scheduled tasks                tasks with a logon or boot trigger. Software
                                             increasingly starts this way instead of through a
                                             Run key, which is why Task Manager's Startup tab
                                             can look clean on a machine that takes four minutes
                                             to settle.
              Automatic services             the count that decides how long the machine takes
                                             to become usable, split by whether they are delayed.

            Each entry is then matched against what is running now, so the report can say what
            that entry is actually costing rather than only that it exists.

        .PARAMETER Process
            Samples from Get-RmoProcessSample, used to attribute live consumption to an entry.

        .PARAMETER Identifier
            A compiled identifier from New-RmoIdentifier, so entries get a name and a publisher.

        .PARAMETER IncludeScheduledTasks
            Also enumerate logon and boot triggered scheduled tasks. Needs the ScheduledTasks
            module, which is present on Windows 8 / Server 2012 and later.

        .PARAMETER VerifySignature
            Verify Authenticode signatures on the executables behind each entry.

        .PARAMETER ErrorSink
            Optional list for locations that could not be read.

        .EXAMPLE
            Get-RmoStartupItem -Process $processes | Where-Object Enabled | Sort-Object MemoryBytes -Descending
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [AllowEmptyCollection()] [object[]] $Process = @(),
        [psobject] $Identifier,
        [switch] $IncludeScheduledTasks,
        [switch] $VerifySignature,
        [System.Collections.IList] $ErrorSink
    )

    if (-not (Test-RmoWindows)) { throw 'Get-RmoStartupItem requires Windows.' }
    if ($null -eq $Identifier) {
        $Identifier = New-RmoIdentifier -Entry (Get-RmoProcessCatalogEntry)
    }

    #region What is running now, indexed by executable name
    $runningByName = @{}
    foreach ($item in $Process) {
        $key = $item.Name.ToLowerInvariant()
        if (-not $runningByName.ContainsKey($key)) { $runningByName[$key] = [System.Collections.Generic.List[object]]::new() }
        $runningByName[$key].Add($item)
    }
    #endregion

    #region Entries a user has already switched off in Task Manager
    # The state lives in a binary value under StartupApproved. The first byte is even when the
    # entry is enabled and odd when it has been disabled.
    $disabled = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $approvalKeys = @(
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32'
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32'
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder')

    foreach ($keyPath in $approvalKeys) {
        if (-not (Test-Path -LiteralPath $keyPath -ErrorAction SilentlyContinue)) { continue }
        try {
            $key = Get-Item -LiteralPath $keyPath -ErrorAction Stop
            foreach ($valueName in $key.GetValueNames()) {
                if (-not $valueName) { continue }
                $bytes = @($key.GetValue($valueName))
                if ($bytes.Count -eq 0) { continue }
                if ((([int] $bytes[0]) % 2) -eq 1) { $null = $disabled.Add($valueName) }
            }
        } catch {
            $message = "Could not read startup approval state from ${keyPath}: $($_.Exception.Message)"
            Write-Verbose $message
            if ($null -ne $ErrorSink) { $null = $ErrorSink.Add($message) }
        }
    }
    #endregion

    $results = [System.Collections.Generic.List[object]]::new()

    function Resolve-RmoStartupTarget {
        <#
            Pulls the executable out of a startup command line, which may be quoted, may carry
            arguments, may be a rundll32 or msiexec invocation, and may point at a path with
            spaces and no quotes at all.
        #>
        param([string] $Command)

        if ([string]::IsNullOrWhiteSpace($Command)) { return '' }
        $text = $Command.Trim()

        if ($text.StartsWith('"')) {
            $end = $text.IndexOf('"', 1)
            if ($end -gt 1) { return $text.Substring(1, $end - 1) }
        }

        # Unquoted, with arguments and quite possibly spaces in the path. Cut at the first
        # executable extension: 'C:\Program Files\Thing\thing.exe /silent' resolves correctly
        # without touching the disk, which matters because a Run key often outlives the software
        # it points at - and those are exactly the entries worth reporting.
        $match = [regex]::Match($text, '^(?<exe>.*?\.(exe|com|bat|cmd|scr|ps1|vbs|js))(?=\s|$)',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($match.Success) {
            return [Environment]::ExpandEnvironmentVariables($match.Groups['exe'].Value)
        }

        # No recognisable extension. Take the longest leading substring that is a file on disk,
        # which covers an extensionless target.
        $candidate = $text
        while ($candidate) {
            $expanded = [Environment]::ExpandEnvironmentVariables($candidate)
            if (Test-Path -LiteralPath $expanded -PathType Leaf -ErrorAction SilentlyContinue) { return $expanded }
            $lastSpace = $candidate.LastIndexOf(' ')
            if ($lastSpace -le 0) { break }
            $candidate = $candidate.Substring(0, $lastSpace)
        }
        # Nothing matched, so fall back to the first token for identification purposes.
        ($text -split '\s+')[0]
    }

    function Add-RmoStartupEntry {
        param(
            [string] $Name,
            [string] $Command,
            [string] $Location,
            [string] $Source,
            [string] $User,
            [bool] $Enabled,
            [string] $Note = ''
        )

        $target = Resolve-RmoStartupTarget $Command
        $processName = Get-RmoLeafName $target

        $identity = Resolve-RmoProcessIdentity -Name $processName -Path $target -Identifier $Identifier `
            -VerifySignature:$VerifySignature.IsPresent -ErrorSink $ErrorSink

        $running = @()
        if ($processName -and $runningByName.ContainsKey($processName.ToLowerInvariant())) {
            $running = @($runningByName[$processName.ToLowerInvariant()])
        }

        $cpu = $null
        $memory = [double] 0
        foreach ($item in $running) {
            if ($null -ne $item.CpuPercent) {
                if ($null -eq $cpu) { $cpu = [double] 0 }
                $cpu += $item.CpuPercent
            }
            $value = if ($item.PSObject.Properties['MemoryBytes']) { [double] $item.MemoryBytes } else { [double] $item.WorkingSetBytes }
            $memory += $value
        }

        # What this entry is costing right now, which is the only honest basis for an impact
        # rating. An entry that is disabled or not running costs nothing at the moment, whatever
        # it might cost later.
        $impact = 'Low'
        if (-not $Enabled) {
            $impact = 'Info'
        } elseif ($identity.Class -eq 'Unwanted') {
            $impact = 'High'
        } elseif ($memory -ge 500MB -or ($null -ne $cpu -and $cpu -ge 5)) {
            $impact = 'High'
        } elseif ($memory -ge 150MB -or ($null -ne $cpu -and $cpu -ge 1)) {
            $impact = 'Medium'
        } elseif ($running.Count -eq 0) {
            $impact = 'Info'
        }

        $results.Add([pscustomobject]@{
            PSTypeName     = 'Rmo.StartupItem'
            Name           = $Name
            Command        = $Command
            TargetPath     = $target
            ProcessName    = $processName
            Location       = $Location
            Source         = $Source
            User           = $User
            Enabled        = $Enabled
            Running        = ($running.Count -gt 0)
            InstanceCount  = $running.Count
            CpuPercent     = $cpu
            MemoryBytes    = $memory
            MemoryText     = Format-RmoBytes $memory
            CpuText        = Format-RmoPercent $cpu
            Impact         = $impact
            Note           = $Note
            Identity       = $identity
        })
    }

    #region Run keys and startup folders
    foreach ($command in Invoke-RmoCim -ClassName 'Win32_StartupCommand' -ErrorSink $ErrorSink) {
        $name = [string] (Get-RmoObjectValue $command 'Name' '')
        Add-RmoStartupEntry -Name $name `
            -Command ([string] (Get-RmoObjectValue $command 'Command' '')) `
            -Location ([string] (Get-RmoObjectValue $command 'Location' '')) `
            -Source 'Run key or startup folder' `
            -User ([string] (Get-RmoObjectValue $command 'User' '')) `
            -Enabled (-not ($disabled.Contains($name) -or $disabled.Contains("$name.lnk")))
    }
    #endregion

    #region Scheduled tasks that run at logon or boot
    if ($IncludeScheduledTasks) {
        try {
            $tasks = @(Get-ScheduledTask -ErrorAction Stop)
            foreach ($task in $tasks) {
                if ($task.State -eq 'Disabled') { continue }
                # Windows ships hundreds of its own maintenance tasks. They are not what makes a
                # machine slow to sign in, and listing them would bury what is.
                if ($task.TaskPath -like '\Microsoft\*') { continue }

                $triggerTypes = @($task.Triggers | ForEach-Object { $_.CimClass.CimClassName })
                $atStartup = @($triggerTypes | Where-Object { $_ -in 'MSFT_TaskLogonTrigger', 'MSFT_TaskBootTrigger' })
                if ($atStartup.Count -eq 0) { continue }

                $action = Get-RmoFirstOrDefault $task.Actions
                $execute = [string] (Get-RmoObjectValue $action 'Execute' '')
                $arguments = [string] (Get-RmoObjectValue $action 'Arguments' '')
                if (-not $execute) { continue }

                $trigger = if ($atStartup -contains 'MSFT_TaskBootTrigger') { 'at boot' } else { 'at sign-in' }
                Add-RmoStartupEntry -Name ([string] $task.TaskName) `
                    -Command ("$execute $arguments").Trim() `
                    -Location ([string] $task.TaskPath) `
                    -Source 'Scheduled task' `
                    -User ([string] (Get-RmoObjectValue $task.Principal 'UserId' '')) `
                    -Enabled $true `
                    -Note "Runs $trigger. Scheduled tasks do not appear in Task Manager's Startup tab."
            }
        } catch {
            $message = "Could not enumerate scheduled tasks: $($_.Exception.Message)"
            Write-Verbose $message
            if ($null -ne $ErrorSink) { $null = $ErrorSink.Add($message) }
        }
    }
    #endregion

    @($results)
}
