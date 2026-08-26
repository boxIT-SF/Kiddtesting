<#
    A stand-in for the Windows data sources, so that the collection functions can be tested.

    Everything in Get-RmoProcessSample, Get-RmoSystemSnapshot and Get-RmoServiceLoad is a
    transformation of what WMI returned - counter differencing, unit conversion, process-id reuse
    detection, service attribution. That is exactly the code most worth testing and the code
    hardest to test against a real machine, because a real machine will not reliably reuse a
    process id or hand out a 4:1 ratio of processor time on demand.

    So the CIM cmdlets are shadowed inside the module's own session state with functions that
    return data the test chose. The module's code is not modified or aware of it; it makes the
    same calls it always makes.
#>

function New-FakeProcess {
    <#
        One Win32_Process instance. Times are in 100-nanosecond units and PeakWorkingSetSize is
        in kilobytes, exactly as WMI reports them - the point is to catch a unit mistake in the
        code under test, so the fixture has to use the real units.
    #>
    param(
        [Parameter(Mandatory)] [int] $ProcessId,
        [Parameter(Mandatory)] [string] $Name,
        [int] $ParentProcessId = 0,
        [string] $ExecutablePath = '',
        [string] $CommandLine = '',
        [int] $SessionId = 1,
        [datetime] $CreationDate = ([datetime]'2026-01-01T09:00:00'),
        [double] $CpuTicks = 0,
        [double] $WorkingSetBytes = 100MB,
        [double] $PrivateBytes = 90MB,
        [double] $ReadTransferCount = 0,
        [double] $WriteTransferCount = 0,
        [double] $ReadOperationCount = 0,
        [double] $WriteOperationCount = 0,
        [double] $PageFaults = 0,
        [int] $HandleCount = 200,
        [int] $ThreadCount = 8
    )

    [pscustomobject]@{
        Handle              = "$ProcessId"
        ProcessId           = $ProcessId
        ParentProcessId     = $ParentProcessId
        Name                = "$Name.exe"
        ExecutablePath      = $ExecutablePath
        CommandLine         = $CommandLine
        SessionId           = $SessionId
        CreationDate        = $CreationDate
        # Split across kernel and user time the way a real process is, so the code has to add
        # both to arrive at the right answer.
        KernelModeTime      = [uint64] ($CpuTicks * 0.4)
        UserModeTime        = [uint64] ($CpuTicks * 0.6)
        WorkingSetSize      = [uint64] $WorkingSetBytes
        PeakWorkingSetSize  = [uint64] ($WorkingSetBytes / 1024)
        PrivatePageCount    = [uint64] $PrivateBytes
        PageFaults          = [uint32] $PageFaults
        HandleCount         = [uint32] $HandleCount
        ThreadCount         = [uint32] $ThreadCount
        ReadTransferCount   = [uint64] $ReadTransferCount
        WriteTransferCount  = [uint64] $WriteTransferCount
        ReadOperationCount  = [uint64] $ReadOperationCount
        WriteOperationCount = [uint64] $WriteOperationCount
    }
}

function New-FakeCimData {
    <#
        A complete, plausible machine: 8 GB of RAM with one slot free, a mechanical system disk,
        a nearly full system volume, Defender plus a third-party scanner both real-time, and a
        power-saving plan. Chosen so that several health checks have something to find.
    #>
    param(
        [hashtable] $Override = @{},
        [string] $PathRoot = 'C:\Program Files'
    )

    $chromePath = Join-Path $PathRoot 'chrome.exe'
    $cleanerPath = Join-Path $PathRoot 'CCleaner.exe'

    $data = @{
        'Win32_OperatingSystem' = @([pscustomobject]@{
            Caption = 'Microsoft Windows 11 Pro'; Version = '10.0.26100'; BuildNumber = '26100'
            OSArchitecture = '64-bit'; InstallDate = [datetime]'2024-03-01'
            LastBootUpTime = [datetime]::Now.AddDays(-21)
            TotalVisibleMemorySize = [uint64] (8 * 1024 * 1024)   # kilobytes
            FreePhysicalMemory = [uint64] (400 * 1024)
        })
        'Win32_ComputerSystem' = @([pscustomobject]@{
            Manufacturer = 'Contoso'; Model = 'Latitude 9'; TotalPhysicalMemory = [uint64] 8GB
            AutomaticManagedPagefile = $true
        })
        'Win32_SystemEnclosure' = @([pscustomobject]@{ ChassisTypes = @(10) })   # 10 = notebook
        'Win32_Battery' = @([pscustomobject]@{ BatteryStatus = [uint16] 2; EstimatedChargeRemaining = [uint16] 88 })
        'Win32_Processor' = @([pscustomobject]@{
            Name = 'Contoso Core   i5-8250U  CPU @ 1.60GHz'; Manufacturer = 'ContosoTek'
            NumberOfCores = [uint32] 4; NumberOfLogicalProcessors = [uint32] 8
            MaxClockSpeed = [uint32] 3400; CurrentClockSpeed = [uint32] 1100
        })
        'Win32_PhysicalMemory' = @([pscustomobject]@{
            DeviceLocator = 'DIMM A'; BankLabel = 'BANK 0'; Capacity = [uint64] 8GB
            ConfiguredClockSpeed = [uint32] 2400; Speed = [uint32] 2400
            Manufacturer = 'Contoso'; PartNumber = 'CT8G4SFS824A '
        })
        'Win32_PhysicalMemoryArray' = @([pscustomobject]@{ MemoryDevices = [uint16] 2 })
        'Win32_PerfFormattedData_PerfOS_Memory' = @([pscustomobject]@{
            CommittedBytes = [uint64] (11GB); CommitLimit = [uint64] (12GB)
            AvailableBytes = [uint64] (380MB); PageReadsPersec = [uint32] 320
            PagesPersec = [uint32] 900; PoolPagedBytes = [uint64] 400MB; PoolNonpagedBytes = [uint64] 200MB
        })
        'MSFT_PhysicalDisk' = @([pscustomobject]@{
            FriendlyName = 'Contoso HM500JI'; MediaType = [uint16] 3; SpindleSpeed = [uint32] 5400; BusType = [uint16] 8
        })
        'Win32_DiskDrive' = @([pscustomobject]@{
            DeviceID = '\\.\PHYSICALDRIVE0'; Model = 'Contoso HM500JI'; Size = [uint64] 500GB
            InterfaceType = 'IDE'; Partitions = [uint32] 3
        })
        'Win32_LogicalDisk' = @([pscustomobject]@{
            DeviceID = 'C:'; VolumeName = 'Windows'; FileSystem = 'NTFS'; DriveType = [uint32] 3
            Size = [uint64] 500GB; FreeSpace = [uint64] 20GB
        })
        'Win32_VideoController' = @([pscustomobject]@{
            Name = 'Contoso UHD Graphics 620'; AdapterCompatibility = 'ContosoTek'
            DriverVersion = '27.20.100.8681'; DriverDate = [datetime]::Now.AddDays(-1500)
            AdapterRAM = [uint32] 1GB; Status = 'OK'
        })
        'Win32_PageFileUsage' = @([pscustomobject]@{
            Name = 'C:\pagefile.sys'; AllocatedBaseSize = [uint32] 4096
            CurrentUsage = [uint32] 3000; PeakUsage = [uint32] 3800
        })
        'Win32_PowerPlan' = @([pscustomobject]@{ ElementName = 'Power saver'; InstanceID = 'guid:{a1841308}'; IsActive = $true })
        'AntiVirusProduct' = @(
            [pscustomobject]@{ displayName = 'Windows Defender'; productState = 397568; pathToSignedProductExe = 'windowsdefender://' }
            [pscustomobject]@{ displayName = 'Contoso AntiVirus'; productState = 266240; pathToSignedProductExe = 'C:\Program Files\Contoso\av.exe' }
        )
        'Win32_Service' = @(
            [pscustomobject]@{ Name = 'wuauserv'; DisplayName = 'Windows Update'; State = 'Running'
                               StartMode = 'Manual'; ProcessId = [uint32] 900; PathName = 'svchost.exe -k netsvcs'
                               Description = 'Enables updates.'; DelayedAutoStart = $false }
            [pscustomobject]@{ Name = 'BITS'; DisplayName = 'Background Intelligent Transfer Service'
                               State = 'Running'; StartMode = 'Auto'; ProcessId = [uint32] 900
                               PathName = 'svchost.exe -k netsvcs'; Description = 'Transfers files.'; DelayedAutoStart = $true }
            [pscustomobject]@{ Name = 'Stopped1'; DisplayName = 'A stopped service'; State = 'Stopped'
                               StartMode = 'Auto'; ProcessId = [uint32] 0; PathName = 'x.exe'
                               Description = ''; DelayedAutoStart = $false }
        )
        'Win32_StartupCommand' = @(
            [pscustomobject]@{ Name = 'Spotify'; Command = '"C:\Users\jo\AppData\Roaming\Spotify\Spotify.exe" --autostart'
                               Location = 'HKU\...\Run'; User = 'CONTOSO\jo'; Description = '' }
            [pscustomobject]@{ Name = 'CCleaner Monitoring'; Command = 'C:\Program Files\CCleaner\CCleaner.exe /MONITOR'
                               Location = 'HKLM\...\Run'; User = 'Public'; Description = '' }
        )
        'Win32_PerfFormattedData_PerfOS_Processor' = @([pscustomobject]@{
            Name = '_Total'; PercentProcessorTime = [uint64] 78; PercentInterruptTime = [uint64] 9
            PercentPrivilegedTime = [uint64] 30; PercentUserTime = [uint64] 48
        })
        'Win32_PerfFormattedData_PerfOS_System' = @([pscustomobject]@{
            ProcessorQueueLength = [uint32] 24; ContextSwitchesPersec = [uint32] 40000
        })
        'Win32_PerfFormattedData_PerfDisk_PhysicalDisk' = @(
            [pscustomobject]@{ Name = '_Total'; PercentDiskTime = [uint64] 98; CurrentDiskQueueLength = [uint32] 6
                               DiskBytesPersec = [uint64] 12MB; DiskTransfersPersec = [uint32] 300
                               AvgDisksecPerTransfer = [double] 0.042 }
            [pscustomobject]@{ Name = '0 C:'; PercentDiskTime = [uint64] 98; CurrentDiskQueueLength = [uint32] 6
                               DiskBytesPersec = [uint64] 12MB; DiskTransfersPersec = [uint32] 300
                               AvgDisksecPerTransfer = [double] 0.042 }
        )
        'Win32_PerfFormattedData_Tcpip_NetworkInterface' = @(
            [pscustomobject]@{ Name = 'Contoso Wireless AX'; BytesTotalPersec = [uint64] 2MB; CurrentBandwidth = [uint64] 866000000 }
            [pscustomobject]@{ Name = 'Loopback Pseudo-Interface 1'; BytesTotalPersec = [uint64] 900MB; CurrentBandwidth = [uint64] 1000000000 }
        )
        'Win32_PerfFormattedData_PerfProc_Process' = @(
            [pscustomobject]@{ IDProcess = [uint32] 100; WorkingSetPrivate = [uint64] 700MB }
            [pscustomobject]@{ IDProcess = [uint32] 101; WorkingSetPrivate = [uint64] 500MB }
            [pscustomobject]@{ IDProcess = [uint32] 900; WorkingSetPrivate = [uint64] 40MB }
        )
    }

    # Two snapshots of Win32_Process, returned in order, so the sampler has real deltas to work
    # with: chrome 100 uses four times the processor time of chrome 101 over the same interval,
    # process 700 is created between the snapshots, and 800's id is reused by a different program.
    $snapshots = @(
        @(
            (New-FakeProcess -ProcessId 100 -Name 'chrome' -ParentProcessId 500 -CpuTicks 0 `
                -WorkingSetBytes 900MB -ExecutablePath $chromePath)
            (New-FakeProcess -ProcessId 101 -Name 'chrome' -ParentProcessId 100 -CpuTicks 0 -WorkingSetBytes 600MB)
            (New-FakeProcess -ProcessId 900 -Name 'svchost' -CpuTicks 0 -WorkingSetBytes 50MB `
                -CommandLine 'C:\Windows\system32\svchost.exe -k netsvcs -p')
            (New-FakeProcess -ProcessId 500 -Name 'explorer' -CpuTicks 0 -WorkingSetBytes 150MB `
                -CreationDate ([datetime]'2026-01-01T08:00:00'))
            (New-FakeProcess -ProcessId 800 -Name 'notepad' -CpuTicks 0 -WorkingSetBytes 20MB `
                -CreationDate ([datetime]'2026-01-01T09:00:00'))
        ),
        @(
            # 8 logical processors, so 4,000,000 ticks (0.4 s) over a 1 s interval is 5% of the
            # machine. The ratio between 100 and 101 is what the test asserts, since the real
            # elapsed time is whatever the host managed.
            (New-FakeProcess -ProcessId 100 -Name 'chrome' -ParentProcessId 500 -CpuTicks 4000000 `
                -WorkingSetBytes 900MB -ExecutablePath $chromePath `
                -ReadTransferCount 8MB -WriteTransferCount 2MB -ReadOperationCount 400 -PageFaults 900)
            (New-FakeProcess -ProcessId 101 -Name 'chrome' -ParentProcessId 100 -CpuTicks 1000000 -WorkingSetBytes 600MB)
            (New-FakeProcess -ProcessId 900 -Name 'svchost' -CpuTicks 2000000 -WorkingSetBytes 50MB `
                -CommandLine 'C:\Windows\system32\svchost.exe -k netsvcs -p')
            (New-FakeProcess -ProcessId 500 -Name 'explorer' -CpuTicks 500000 -WorkingSetBytes 150MB `
                -CreationDate ([datetime]'2026-01-01T08:00:00'))
            # Same id, different creation time: a different program wearing 800's number.
            (New-FakeProcess -ProcessId 800 -Name 'calc' -CpuTicks 9000000000 -WorkingSetBytes 30MB `
                -CreationDate ([datetime]'2026-01-01T09:30:00'))
            # Created after the first snapshot, so no rate can be measured for it.
            (New-FakeProcess -ProcessId 700 -Name 'CCleaner' -CpuTicks 500000 -WorkingSetBytes 120MB `
                -ExecutablePath $cleanerPath `
                -CreationDate ([datetime]'2026-01-01T09:20:00'))
        )
    )

    $data['Win32_Process'] = {
        param([int] $Call)
        if ($Call -ge $snapshots.Count) { $snapshots[$snapshots.Count - 1] } else { $snapshots[$Call] }
    }.GetNewClosure()

    foreach ($key in $Override.Keys) { $data[$key] = $Override[$key] }
    $data
}

function Install-FakeCim {
    <#
        Shadows the Windows-only cmdlets with functions that return the fixture.

        Two details make this work. A function shadows a cmdlet of the same name in PowerShell's
        command resolution order, and a module's code falls back to the global session state for
        commands it cannot find in its own - so global functions are visible to the module under
        test without it being modified or aware of them.

        Test-RmoWindows is the module's own function and cannot be shadowed that way, so instead
        the variable it reads is set. That is also the more honest test: the real function runs.
    #>
    param(
        [Parameter(Mandatory)] $Module,
        [Parameter(Mandatory)] [hashtable] $Data
    )

    $global:RmoFakeCim = $Data
    $global:RmoFakeCimCalls = @{}

    # Capture the real value once, on the first install, so repeated installs do not record the
    # value a previous install put there.
    $captured = Get-Variable -Name RmoFakeOriginalIsWindows -Scope Global -ErrorAction SilentlyContinue
    if ($null -eq $captured) {
        $existing = Get-Variable -Name IsWindows -Scope Global -ErrorAction SilentlyContinue
        $global:RmoFakeOriginalIsWindows = $(if ($null -eq $existing) { '<absent>' } else { $existing.Value })
    }
    Set-Variable -Name IsWindows -Value $true -Scope Global -Force

    # The publisher cache is keyed by path and would otherwise carry answers between fixtures.
    & $Module { $script:RmoPublisherCache = @{} }

    # No [Parameter()] attributes and no ErrorAction: any [Parameter()] attribute would make
    # these advanced functions, and the common parameters they gain then collide with the
    # -ErrorAction the module passes. Undeclared arguments land harmlessly in $args instead.
    function global:Get-CimInstance {
        param(
            [string] $ClassName,
            [string] $Namespace,
            [string] $Filter,
            [string[]] $Property
        )

        if (-not $global:RmoFakeCim.ContainsKey($ClassName)) {
            throw "Invalid class $ClassName"
        }

        $value = $global:RmoFakeCim[$ClassName]
        if ($value -is [scriptblock]) {
            $count = 0
            if ($global:RmoFakeCimCalls.ContainsKey($ClassName)) { $count = $global:RmoFakeCimCalls[$ClassName] }
            $global:RmoFakeCimCalls[$ClassName] = $count + 1
            $value = & $value $count
        }

        $results = @($value)
        if ($Filter -and $Filter -match "^\s*(?<name>\w+)\s*=\s*'?(?<value>[^']*?)'?\s*$") {
            $name = $Matches['name']
            $wanted = $Matches['value']
            $results = @($results | Where-Object {
                $found = $_.PSObject.Properties[$name]
                $null -ne $found -and "$($found.Value)" -eq $wanted
            })
        }
        $results
    }

    function global:Invoke-CimMethod {
        param($InputObject, [string] $MethodName)
        [pscustomobject]@{ ReturnValue = 0; Domain = 'CONTOSO'; User = 'jo' }
    }

    function global:Get-Process {
        param()
        @(
            [pscustomobject]@{ Id = 100; Responding = $true;  MainWindowTitle = 'Inbox - Chrome' }
            [pscustomobject]@{ Id = 500; Responding = $false; MainWindowTitle = 'File Explorer' }
        )
    }

    function global:Get-AuthenticodeSignature {
        param([string] $LiteralPath)
        [pscustomobject]@{
            Status = 'Valid'
            SignerCertificate = [pscustomobject]@{ Subject = 'CN=Contoso Signing, O=Contoso, C=GB' }
        }
    }

    function global:Get-ScheduledTask {
        param()
        @(
            [pscustomobject]@{
                TaskName = 'ContosoLedgerLauncher'; TaskPath = '\Contoso\'; State = 'Ready'
                Triggers = @([pscustomobject]@{ CimClass = [pscustomobject]@{ CimClassName = 'MSFT_TaskLogonTrigger' } })
                Actions = @([pscustomobject]@{ Execute = 'C:\Program Files\Contoso\ledger.exe'; Arguments = '/tray' })
                Principal = [pscustomobject]@{ UserId = 'CONTOSO\jo' }
            }
            [pscustomobject]@{
                TaskName = 'MicrosoftEdgeUpdateTaskMachineCore'; TaskPath = '\Microsoft\'; State = 'Ready'
                Triggers = @([pscustomobject]@{ CimClass = [pscustomobject]@{ CimClassName = 'MSFT_TaskLogonTrigger' } })
                Actions = @([pscustomobject]@{ Execute = 'C:\edgeupdate.exe'; Arguments = '' })
                Principal = [pscustomobject]@{ UserId = 'SYSTEM' }
            }
            [pscustomobject]@{
                TaskName = 'ADailyThing'; TaskPath = '\Contoso\'; State = 'Ready'
                Triggers = @([pscustomobject]@{ CimClass = [pscustomobject]@{ CimClassName = 'MSFT_TaskDailyTrigger' } })
                Actions = @([pscustomobject]@{ Execute = 'C:\daily.exe'; Arguments = '' })
                Principal = [pscustomobject]@{ UserId = 'SYSTEM' }
            }
        )
    }

    function global:Get-WinEvent {
        param($FilterHashtable, [int] $MaxEvents)
        if ($FilterHashtable['LogName'] -ne 'System') {
            throw 'No events were found that match the specified selection criteria.'
        }
        1..4 | ForEach-Object {
            [pscustomobject]@{
                ProviderName = 'Microsoft-Windows-Kernel-Power'
                TimeCreated = [datetime]::Now.AddDays(-$_)
                Properties = @([pscustomobject]@{ Value = '0x00000133' })
            }
        }
    }
}

function Uninstall-FakeCim {
    param([Parameter(Mandatory)] $Module)

    foreach ($name in 'Get-CimInstance', 'Invoke-CimMethod', 'Get-Process',
                      'Get-AuthenticodeSignature', 'Get-ScheduledTask', 'Get-WinEvent') {
        if (Test-Path -LiteralPath "Function:\$name") {
            Remove-Item -LiteralPath "Function:\$name" -Force
        }
    }

    $captured = Get-Variable -Name RmoFakeOriginalIsWindows -Scope Global -ErrorAction SilentlyContinue
    if ($null -ne $captured) {
        if ($global:RmoFakeOriginalIsWindows -eq '<absent>') {
            Remove-Variable -Name IsWindows -Scope Global -Force -ErrorAction SilentlyContinue
        } else {
            Set-Variable -Name IsWindows -Value $global:RmoFakeOriginalIsWindows -Scope Global -Force
        }
        Remove-Variable -Name RmoFakeOriginalIsWindows -Scope Global -Force
    }

    Remove-Variable -Name RmoFakeCim -Scope Global -Force -ErrorAction SilentlyContinue
    Remove-Variable -Name RmoFakeCimCalls -Scope Global -Force -ErrorAction SilentlyContinue
    & $Module { $script:RmoPublisherCache = @{} }
}
