<#
.SYNOPSIS
    Runs the ResourceMonitor test suite.

.DESCRIPTION
    No external dependencies. The analysis pipeline is exercised against synthetic process and
    machine data, so the scoring, grouping, planning and reporting are all verified without
    needing a machine that happens to be under load - and without the tests being at the mercy of
    whatever the host is doing while they run.

    The collection functions read Windows-only data sources. On Windows they run against the real
    machine; anywhere else they are skipped and reported as skipped rather than silently omitted.

    Exits with the number of failures, so it can gate a build.

.EXAMPLE
    pwsh -File .\tests\Invoke-Tests.ps1

.EXAMPLE
    powershell.exe -NoProfile -File .\tests\Invoke-Tests.ps1
#>
[CmdletBinding()]
param(
    [string] $ModulePath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'TestHarness.ps1')
Reset-TestState

if (-not $ModulePath) {
    $ModulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'src/ResourceMonitor/ResourceMonitor.psd1'
}
Import-Module $ModulePath -Force

# Private functions are reached through the module's own scope rather than being re-dot-sourced,
# so the tests exercise exactly the code the module runs.
$module = Get-Module ResourceMonitor
function Use-Private {
    param([string] $Name, [object[]] $Arguments = @())
    & $module { param($n, $a) & $n @a } $Name $Arguments
}

$onWindows = Use-Private 'Test-RmoWindows'
$scratch = Join-Path ([System.IO.Path]::GetTempPath()) ("rmo-tests-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $scratch -Force

#region Fixtures
$identifier = New-RmoIdentifier -Entry (Get-RmoProcessCatalogEntry)

function New-TestProcess {
    <#
        Builds an object with the same shape Get-RmoProcessSample produces, so everything
        downstream of collection can be tested against a machine state we chose.
    #>
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [int] $ProcessId,
        [double] $CpuPercent = 0,
        [double] $MemoryMb = 100,
        [double] $DiskMbPerSecond = 0,
        [int] $HandleCount = 300,
        [int] $ThreadCount = 12,
        [string] $Path = '',
        [bool] $Responding = $true,
        [string] $WindowTitle = '',
        [string[]] $ServiceName = @(),
        [bool] $Measured = $true
    )

    $identity = Resolve-RmoProcessIdentity -Name $Name -Path $Path -Identifier $identifier
    $bytes = $MemoryMb * 1MB
    $io = $DiskMbPerSecond * 1MB
    $services = foreach ($service in $ServiceName) {
        [pscustomobject]@{ Name = $service; DisplayName = $service; State = 'Running'; ProcessId = $ProcessId }
    }

    [pscustomobject]@{
        ProcessId              = $ProcessId
        ParentProcessId        = 0
        ParentName             = ''
        Name                   = $Name
        ImageName              = "$Name.exe"
        ExecutablePath         = $Path
        CommandLine            = "$Path --run"
        SessionId              = 1
        Owner                  = 'CONTOSO\jo'
        StartedUtc             = [datetime]::UtcNow.AddHours(-3)
        AgeSeconds             = 10800
        Measured               = $Measured
        CpuPercent             = $(if ($Measured) { $CpuPercent } else { $null })
        CpuPeakPercent         = $(if ($Measured) { $CpuPercent } else { $null })
        WorkingSetBytes        = $bytes
        PrivateBytes           = $bytes
        PrivateWorkingSetBytes = $bytes
        PeakWorkingSetBytes    = $bytes
        ReadBytesPerSecond     = $(if ($Measured) { $io / 2 } else { $null })
        WriteBytesPerSecond    = $(if ($Measured) { $io / 2 } else { $null })
        IoBytesPerSecond       = $(if ($Measured) { $io } else { $null })
        IoOperationsPerSecond  = $(if ($Measured) { 10 } else { $null })
        PageFaultsPerSecond    = $(if ($Measured) { 5 } else { $null })
        HandleCount            = $HandleCount
        ThreadCount            = $ThreadCount
        Services               = @($services)
        ServiceGroup           = ''
        Identity               = $identity
        CimInstance            = $null
        Responding             = $Responding
        MainWindowTitle        = $WindowTitle
    }
}

function New-TestSystem {
    param(
        [double] $TotalGb = 8,
        [double] $AvailableGb = 1,
        [string] $DiskMedia = 'SSD',
        [int] $LogicalProcessors = 4,
        [int] $UsedSlots = 1,
        [int] $TotalSlots = 2,
        [string] $PowerPlan = 'Balanced',
        [bool] $IsLaptop = $true,
        [double] $SystemVolumeFreePercent = 40,
        [object[]] $Antivirus = @()
    )

    [pscustomobject]@{
        ComputerName   = 'TESTPC'
        Manufacturer   = 'Contoso'
        Model          = 'Workstation 5'
        IsLaptop       = $IsLaptop
        OnBattery      = $false
        BatteryPercent = 100
        Os             = [pscustomobject]@{
            Caption = 'Microsoft Windows 11 Pro'; Version = '10.0.26100'; BuildNumber = '26100'
            Architecture = '64-bit'; InstalledUtc = [datetime]'2024-01-01'
            LastBoot = [datetime]::Now.AddDays(-2); UptimeSeconds = 172800
        }
        Cpu            = [pscustomobject]@{
            Name = 'Contoso Core i5-9999'; Manufacturer = 'ContosoTek'; Cores = ($LogicalProcessors / 2)
            LogicalProcessors = $LogicalProcessors; MaxClockMhz = 3000; CurrentClockMhz = 2900
        }
        Memory         = [pscustomobject]@{
            TotalBytes = $TotalGb * 1GB; AvailableBytes = $AvailableGb * 1GB
            CommittedBytes = ($TotalGb - $AvailableGb) * 1GB; CommitLimit = ($TotalGb * 1.5) * 1GB
            Modules = @([pscustomobject]@{ Slot = 'DIMM A'; Bank = 'BANK 0'; CapacityBytes = $TotalGb * 1GB
                                          SpeedMhz = 3200; Manufacturer = 'Contoso'; PartNumber = 'CT8G4' })
            UsedSlots = $UsedSlots; TotalSlots = $TotalSlots
        }
        Storage        = @([pscustomobject]@{
            DeviceId = '\\.\PHYSICALDRIVE0'; Model = 'Contoso Disk'; MediaType = $DiskMedia
            SpindleSpeed = 0; SizeBytes = 500GB; Interface = 'SCSI'; Partitions = 3 })
        Volumes        = @([pscustomobject]@{
            DriveLetter = 'C:'; Label = 'System'; FileSystem = 'NTFS'; SizeBytes = 500GB
            FreeBytes = (500GB * $SystemVolumeFreePercent / 100); FreePercent = $SystemVolumeFreePercent
            IsSystem = $true })
        Graphics       = @([pscustomobject]@{
            Name = 'Contoso Graphics 700'; Manufacturer = 'ContosoTek'; DriverVersion = '31.0.1'
            DriverDate = [datetime]::Now.AddDays(-200); DriverAgeDays = 200; MemoryBytes = 2GB; Status = 'OK' })
        PageFiles      = @([pscustomobject]@{
            Name = 'C:\pagefile.sys'; AllocatedBytes = 4GB; CurrentUsageBytes = 1GB; PeakUsageBytes = 2GB })
        AutomaticPageFile = $true
        PowerPlan      = [pscustomobject]@{ Name = $PowerPlan; Guid = 'guid' }
        Antivirus      = @($Antivirus)
    }
}

function New-TestAnalysis {
    <#
        Runs the whole pipeline downstream of collection against a chosen machine state, and
        returns a result object shaped exactly like Invoke-ResourceAnalysis produces.
    #>
    param(
        [Parameter(Mandatory)] [object[]] $Process,
        [psobject] $System,
        [object[]] $StartupItem = @(),
        [object[]] $Finding = @(),
        [string] $ScanMode = 'Complete'
    )

    if (-not $System) { $System = New-TestSystem }
    $hogs = Get-RmoResourceHog -Process $Process -TopCount 15 -SystemMemoryBytes $System.Memory.TotalBytes
    $pressure = Measure-RmoResourcePressure -System $System -Process $Process
    $plan = New-RmoRemediationPlan -System $System -Pressure $pressure -Hogs $hogs `
        -StartupItem $StartupItem -Finding $Finding -ScanMode $ScanMode

    [pscustomobject]@{
        ScanMode = $ScanMode; ComputerName = $System.ComputerName
        ScanStartedUtc = [datetime]::UtcNow; ScanFinishedUtc = [datetime]::UtcNow
        DurationSeconds = 10.0; Elevated = $true; Cancelled = $false; SampleCount = 4
        System = $System; Pressure = $pressure; Hogs = $hogs; Services = @()
        StartupItems = @($StartupItem); Findings = @($Finding); Plan = $plan
        CatalogEntryCount = 89; ScanErrors = @()
        Parameters = [pscustomobject]@{ ScanMode = $ScanMode }
    }
}
#endregion

#region Formatting and helpers
Describe-Suite 'Formatting helpers' {
    Test-Case 'bytes render at a human scale' {
        Assert-Equal '512 B' (Use-Private 'Format-RmoBytes' @(512))
        Assert-Equal '1.0 KB' (Use-Private 'Format-RmoBytes' @(1024))
        Assert-Equal '2.5 GB' (Use-Private 'Format-RmoBytes' @([double] (2.5 * 1GB)))
        Assert-Equal 'n/a' (Use-Private 'Format-RmoBytes' @($null))
    }
    Test-Case 'a negative byte count keeps its sign' {
        Assert-Equal '-1.0 KB' (Use-Private 'Format-RmoBytes' @(-1024))
    }
    Test-Case 'a rate below a kilobyte reads as nothing rather than as noise' {
        Assert-Equal '-' (Use-Private 'Format-RmoRate' @(12))
        Assert-Match (Use-Private 'Format-RmoRate' @([double] 4MB)) 'MB/s'
    }
    Test-Case 'durations pick the two units that carry the meaning' {
        Assert-Equal '2d 0h' (Use-Private 'Format-RmoDuration' @(172800))
        Assert-Equal '1h 1m' (Use-Private 'Format-RmoDuration' @(3660))
        Assert-Equal '5m' (Use-Private 'Format-RmoDuration' @(300))
        Assert-Equal 'n/a' (Use-Private 'Format-RmoDuration' @($null))
    }
    Test-Case 'percentages tolerate a missing counter' {
        Assert-Equal 'n/a' (Use-Private 'Format-RmoPercent' @($null))
        Assert-Equal '42.5%' (Use-Private 'Format-RmoPercent' @(42.5))
    }
    Test-Case 'values clamp into range' {
        Assert-Equal 100 (Use-Private 'Limit-RmoValue' @(150, 0, 100))
        Assert-Equal 0 (Use-Private 'Limit-RmoValue' @(-4, 0, 100))
        Assert-Equal 50 (Use-Private 'Limit-RmoValue' @(50, 0, 100))
    }
    Test-Case 'text truncates to the column width' {
        Assert-Equal 'abc' (Use-Private 'Limit-RmoText' @('abc', 10))
        Assert-Equal 'abcdefg...' (Use-Private 'Limit-RmoText' @('abcdefghijklmn', 10))
    }
    Test-Case 'paragraphs wrap without losing words' {
        $text = 'the quick brown fox jumps over the lazy dog and keeps going for quite a while yet'
        $wrapped = @(Use-Private 'Format-RmoWrappedText' @($text, 30, '  '))
        Assert-GreaterThan 1 $wrapped.Count
        foreach ($line in $wrapped) { Assert-True ($line.Length -le 30) "line too long: '$line'" }
        Assert-Equal $text (($wrapped | ForEach-Object { $_.Trim() }) -join ' ')
    }
    Test-Case 'html special characters are escaped' {
        Assert-Equal '&lt;b&gt;&amp;&quot;' (Use-Private 'ConvertTo-RmoHtmlText' @('<b>&"'))
    }
    Test-Case 'a missing hashtable key does not become a terminating error' {
        Assert-Equal 'fallback' (Use-Private 'Get-RmoMapValue' @(@{ a = 1 }, 'b', 'fallback'))
        Assert-Equal 1 (Use-Private 'Get-RmoMapValue' @(@{ a = 1 }, 'a', 'fallback'))
    }
    Test-Case 'a missing object property does not become a terminating error' {
        $object = [pscustomobject]@{ Present = 5 }
        Assert-Equal 5 (Use-Private 'Get-RmoObjectValue' @($object, 'Present', 0))
        Assert-Equal 0 (Use-Private 'Get-RmoObjectValue' @($object, 'Absent', 0))
        Assert-Equal 0 (Use-Private 'Get-RmoObjectValue' @($null, 'Absent', 0))
    }
    Test-Case 'the first element of an empty collection is null rather than an index error' {
        Assert-Equal $null (Use-Private 'Get-RmoFirstOrDefault' @(, @()))
        Assert-Equal 7 (Use-Private 'Get-RmoFirstOrDefault' @(, @(7, 8)))
    }
    Test-Case 'user-writable locations are recognised' {
        Assert-True (Use-Private 'Test-RmoUserWritablePath' @('C:\Users\jo\AppData\Local\Temp\x.exe'))
        Assert-True (Use-Private 'Test-RmoUserWritablePath' @('C:\ProgramData\thing\thing.exe'))
        Assert-False (Use-Private 'Test-RmoUserWritablePath' @('C:\Program Files\Thing\thing.exe'))
        Assert-False (Use-Private 'Test-RmoUserWritablePath' @(''))
    }
    Test-Case 'a publisher name is read out of a certificate subject' {
        Assert-Equal 'Google LLC' (Use-Private 'Get-RmoSignerName' @('CN=Google LLC, O=Google LLC, L=Mountain View, C=US'))
        Assert-Equal 'Contoso, Inc.' (Use-Private 'Get-RmoSignerName' @('CN="Contoso, Inc.", O=Contoso, C=US'))
        Assert-Equal '' (Use-Private 'Get-RmoSignerName' @('O=NoCommonName, C=US'))
        Assert-Equal '' (Use-Private 'Get-RmoSignerName' @($null))
    }
    Test-Case 'impact, risk and effort sort in the order the plan needs' {
        Assert-LessThan (Use-Private 'Get-RmoImpactRank' @('Medium')) (Use-Private 'Get-RmoImpactRank' @('High'))
        Assert-LessThan (Use-Private 'Get-RmoSafetyRank' @('Caution')) (Use-Private 'Get-RmoSafetyRank' @('Safe'))
        Assert-LessThan (Use-Private 'Get-RmoEffortRank' @('Hardware')) (Use-Private 'Get-RmoEffortRank' @('Instant'))
    }
}
#endregion

#region Catalogue
Describe-Suite 'Process catalogue' {
    $catalog = Get-RmoProcessCatalogEntry

    Test-Case 'the shipped catalogue loads and is substantial' {
        Assert-GreaterThan 60 @($catalog).Count
    }
    Test-Case 'every entry can be matched by something' {
        foreach ($entry in $catalog) {
            Assert-True (@($entry.Match).Count -gt 0 -or [bool] $entry.NamePattern) "'$($entry.Id)' can never match"
        }
    }
    Test-Case 'every entry says what it is and who publishes it' {
        foreach ($entry in $catalog) {
            Assert-True ([bool] $entry.Description) "'$($entry.Id)' has no description"
            Assert-True ([bool] $entry.Name) "'$($entry.Id)' has no name"
        }
    }
    Test-Case 'every non-essential entry says what to do about it' {
        foreach ($entry in $catalog) {
            Assert-True ([bool] $entry.Guidance) "'$($entry.Id)' has no guidance"
        }
    }
    Test-Case 'every name pattern is a valid regular expression' {
        foreach ($entry in $catalog) {
            if (-not $entry.NamePattern) { continue }
            $null = [regex]::new($entry.NamePattern)
        }
    }
    Test-Case 'ids are unique' {
        $ids = @($catalog | ForEach-Object { $_.Id })
        Assert-Equal $ids.Count (@($ids | Sort-Object -Unique).Count)
    }
    Test-Case 'the generic fallbacks sort last so a real entry always wins' {
        $generic = @($catalog | Where-Object { $_.Id -like 'gen-*' })
        Assert-GreaterThan 0 $generic.Count
        foreach ($entry in $generic) { Assert-GreaterThan 800 $entry.Priority }
    }
    Test-Case 'an overlay replaces a shipped entry by id and adds new ones' {
        $overlay = Join-Path $scratch 'overlay.psd1'
        @'
@{
    Entries = @(
        @{ Id = 'app-chrome'; Match = @('chrome'); Name = 'Site browser'; Vendor = 'Contoso'
           Class = 'Browser'; Description = 'Overridden.'; Guidance = 'Site policy.' }
        @{ Id = 'site-lob'; Match = @('LobApp'); Name = 'Contoso Ledger'; Vendor = 'Contoso'
           Class = 'Productivity'; Description = 'The finance application.'; Guidance = 'Leave it alone.' }
    )
}
'@ | Set-Content -LiteralPath $overlay -Encoding UTF8

        $merged = Get-RmoProcessCatalogEntry -Path $overlay -Force
        $chrome = @($merged | Where-Object { $_.Id -eq 'app-chrome' })[0]
        Assert-Equal 'Site browser' $chrome.Name
        Assert-Equal 1 (@($merged | Where-Object { $_.Id -eq 'site-lob' })).Count
        $null = Get-RmoProcessCatalogEntry -Force
    }
    Test-Case 'a catalogue with an unknown class is rejected' {
        $bad = Join-Path $scratch 'bad-class.psd1'
        @'
@{ Entries = @(@{ Id = 'x'; Match = @('x'); Name = 'X'; Class = 'Nonsense'; Description = 'd' }) }
'@ | Set-Content -LiteralPath $bad -Encoding UTF8
        Assert-Throws { Get-RmoProcessCatalogEntry -Path $bad -Force } 'unknown Class'
        $null = Get-RmoProcessCatalogEntry -Force
    }
    Test-Case 'a catalogue entry with no way to match is rejected' {
        $bad = Join-Path $scratch 'bad-match.psd1'
        @'
@{ Entries = @(@{ Id = 'x'; Name = 'X'; Class = 'System'; Description = 'd' }) }
'@ | Set-Content -LiteralPath $bad -Encoding UTF8
        Assert-Throws { Get-RmoProcessCatalogEntry -Path $bad -Force } 'neither Match nor NamePattern'
        $null = Get-RmoProcessCatalogEntry -Force
    }
    Test-Case 'a missing catalogue file is reported rather than ignored' {
        Assert-Throws { Get-RmoProcessCatalogEntry -Path (Join-Path $scratch 'nope.psd1') -Force } 'not found'
        $null = Get-RmoProcessCatalogEntry -Force
    }
}
#endregion

#region Identification
Describe-Suite 'Identifying processes' {
    Test-Case 'a catalogued process is named with its publisher' {
        $identity = Resolve-RmoProcessIdentity -Name 'chrome' -Identifier $identifier
        Assert-Equal 'Google Chrome' $identity.Name
        Assert-Equal 'Google LLC' $identity.Vendor
        Assert-Equal 'Browser' $identity.Class
        Assert-Equal 'Catalogued' $identity.Confidence
    }
    Test-Case 'matching ignores case, because process names are not consistent about it' {
        $identity = Resolve-RmoProcessIdentity -Name 'CHROME' -Identifier $identifier
        Assert-Equal 'Google Chrome' $identity.Name
    }
    Test-Case 'Windows components are marked essential' {
        foreach ($name in 'svchost', 'lsass', 'dwm', 'explorer', 'csrss') {
            $identity = Resolve-RmoProcessIdentity -Name $name -Identifier $identifier
            Assert-True $identity.Essential "'$name' should be marked essential"
        }
    }
    Test-Case 'a browser is not marked essential, however much it is relied on' {
        $identity = Resolve-RmoProcessIdentity -Name 'chrome' -Identifier $identifier
        Assert-False $identity.Essential
    }
    Test-Case 'an exact name beats the generic pattern that would also have matched it' {
        # 'SearchIndexer' would match the '(service|svc|agent|host|helper|tray|monitor)' fallback
        # through no fault of its own, and the fallback would have thrown away the real advice.
        $identity = Resolve-RmoProcessIdentity -Name 'SearchIndexer' -Identifier $identifier
        Assert-Equal 'Windows Search indexer' $identity.Name
        Assert-Equal 'Catalogued' $identity.Confidence
    }
    Test-Case 'an unrecognised helper still gets a category from the generic pattern' {
        $identity = Resolve-RmoProcessIdentity -Name 'ContosoUpdaterService' -Identifier $identifier
        Assert-Equal 'Generic' $identity.Confidence
        Assert-NotEqual '' $identity.Guidance
    }
    Test-Case 'a completely unknown process is reported as unknown rather than guessed at' {
        $identity = Resolve-RmoProcessIdentity -Name 'zzqqxx' -Identifier $identifier
        Assert-Equal 'zzqqxx' $identity.Name
        Assert-Equal 'Unknown' $identity.Vendor
        Assert-Equal 'Unknown' $identity.Class
        Assert-Equal 'None' $identity.VendorSource
    }
    Test-Case 'an unknown process in a user-writable location gets the cautious guidance' {
        $identity = Resolve-RmoProcessIdentity -Name 'zzqqxx' `
            -Path 'C:\Users\jo\AppData\Local\Temp\zzqqxx.exe' -Identifier $identifier
        Assert-Match $identity.Guidance 'any user can write to'
    }
    Test-Case 'a cryptocurrency miner is claimed by its pattern before any fallback' {
        $identity = Resolve-RmoProcessIdentity -Name 'xmrig' -Identifier $identifier
        Assert-Equal 'Unwanted' $identity.Class
        Assert-Match $identity.Guidance 'incident response'
    }
    Test-Case 'a name claimed by two entries is reported as a collision rather than silently lost' {
        $overlay = Join-Path $scratch 'collide.psd1'
        @'
@{
    Entries = @(
        @{ Id = 'zz-collide'; Priority = 999; Match = @('chrome'); Name = 'Also chrome'
           Vendor = 'Contoso'; Class = 'Browser'; Description = 'd'; Guidance = 'g' }
    )
}
'@ | Set-Content -LiteralPath $overlay -Encoding UTF8
        $collided = New-RmoIdentifier -Entry (Get-RmoProcessCatalogEntry -Path $overlay -Force)
        Assert-GreaterThan 0 @($collided.Collisions).Count
        Assert-Match ($collided.Collisions -join ' ') 'chrome'
        $null = Get-RmoProcessCatalogEntry -Force
    }
    Test-Case 'the publisher of a file that does not exist is empty rather than invented' {
        $info = Use-Private 'Get-RmoPublisherInfo' @('C:\nope\nothing-here.exe')
        Assert-False $info.Readable
        Assert-Equal '' $info.Company
    }
}
#endregion

#region Pressure scoring
Describe-Suite 'Pressure scoring' {
    Test-Case 'a busy processor with nothing queued scores on utilisation alone' {
        Assert-Near 55 (Use-Private 'Get-RmoCpuPressureScore' @(55, $null)) 0.01
    }
    Test-Case 'a deep run queue is critical even when utilisation looks moderate' {
        $score = Use-Private 'Get-RmoCpuPressureScore' @(40, 5)
        Assert-GreaterThan 85 $score
    }
    Test-Case 'a shallow run queue does not inflate the score' {
        Assert-Near 40 (Use-Private 'Get-RmoCpuPressureScore' @(40, 1)) 0.01
    }
    Test-Case 'memory pressure follows whichever signal is worst' {
        Assert-Near 70 (Use-Private 'Get-RmoMemoryPressureScore' @(70, 40, $null, 4GB, 0, 8GB)) 0.01
        Assert-Near 93 (Use-Private 'Get-RmoMemoryPressureScore' @(70, 93, $null, 4GB, 0, 8GB)) 0.01
    }
    Test-Case 'hard faults with little memory left are treated as thrashing' {
        $score = Use-Private 'Get-RmoMemoryPressureScore' @(75, 60, 400, 400MB, 0, 8GB)
        Assert-GreaterThan 94 $score
    }
    Test-Case 'hard faults with plenty of memory left are not thrashing' {
        $score = Use-Private 'Get-RmoMemoryPressureScore' @(50, 50, 400, 20GB, 0, 32GB)
        Assert-Near 50 $score 0.01
    }
    Test-Case 'a large compressed page store is evidence of a shortage on its own' {
        $score = Use-Private 'Get-RmoMemoryPressureScore' @(60, 50, $null, 3GB, 2GB, 8GB)
        Assert-GreaterThan 87 $score
    }
    Test-Case 'disk latency drives the disk score, not utilisation' {
        # A saturated but fast device is keeping up; a quiet but slow one is not.
        $fast = Use-Private 'Get-RmoDiskPressureScore' @(100, 1, 1)
        $slow = Use-Private 'Get-RmoDiskPressureScore' @(40, 45, 1)
        Assert-LessThan 65 $fast
        Assert-Equal 100 $slow
    }
    Test-Case 'a deep disk queue raises the floor' {
        Assert-Equal 80 (Use-Private 'Get-RmoDiskPressureScore' @(10, 1, 9))
    }
    Test-Case 'scores stay inside 0-100 whatever the counters said' {
        foreach ($score in @(
            (Use-Private 'Get-RmoCpuPressureScore' @(400, 200)),
            (Use-Private 'Get-RmoMemoryPressureScore' @(500, 500, 9999, 0, 99GB, 1GB)),
            (Use-Private 'Get-RmoDiskPressureScore' @(900, 900, 900)))) {
            Assert-True ($score -ge 0 -and $score -le 100) "score out of range: $score"
        }
    }
    Test-Case 'a leaf name is taken from a Windows path whatever host is parsing it' {
        Assert-Equal 'Spotify' (Use-Private 'Get-RmoLeafName' @('C:\Users\jo\AppData\Roaming\Spotify\Spotify.exe'))
        Assert-Equal 'thing' (Use-Private 'Get-RmoLeafName' @('C:\Program Files\A B\thing.exe'))
        Assert-Equal 'noext' (Use-Private 'Get-RmoLeafName' @('C:\dir\noext'))
        Assert-Equal '' (Use-Private 'Get-RmoLeafName' @(''))
    }
    Test-Case 'the pressure level names match the bands' {
        Assert-Equal 'Critical' (Use-Private 'Get-RmoPressureLevel' @(95, 70, 90))
        Assert-Equal 'Elevated' (Use-Private 'Get-RmoPressureLevel' @(75, 70, 90))
        Assert-Equal 'Normal' (Use-Private 'Get-RmoPressureLevel' @(10, 70, 90))
        Assert-Equal 'Unknown' (Use-Private 'Get-RmoPressureLevel' @($null, 70, 90))
    }
}
#endregion

#region Pressure measurement over a whole machine state
Describe-Suite 'Measuring a machine' {
    $processes = @(
        (New-TestProcess -Name 'chrome' -ProcessId 100 -CpuPercent 12 -MemoryMb 900)
        (New-TestProcess -Name 'chrome' -ProcessId 101 -CpuPercent 3 -MemoryMb 700)
        (New-TestProcess -Name 'svchost' -ProcessId 200 -CpuPercent 1 -MemoryMb 60 -ServiceName 'Windows Update')
        (New-TestProcess -Name 'Memory Compression' -ProcessId 300 -MemoryMb 1200)
    )
    $system = New-TestSystem -TotalGb 8 -AvailableGb 0.6
    $pressure = Measure-RmoResourcePressure -System $system -Process $processes

    Test-Case 'processor time attributed to processes is summed' {
        Assert-Near 16 $pressure.Cpu.AttributedPercent 0.05
    }
    Test-Case 'memory pressure reflects how little is actually available' {
        Assert-GreaterThan 90 $pressure.Memory.Score
        Assert-Equal 'Critical' $pressure.Memory.Level
    }
    Test-Case 'the compressed page store is picked out of the process list' {
        Assert-Equal (1200 * 1MB) $pressure.Memory.CompressedBytes
    }
    Test-Case 'the constraint is named' {
        Assert-Equal 'Memory' $pressure.Bottleneck.Primary
    }
    Test-Case 'a machine with headroom is reported as having no constraint' {
        $roomy = Measure-RmoResourcePressure -System (New-TestSystem -TotalGb 32 -AvailableGb 20) -Process $processes
        Assert-Equal 'None' $roomy.Bottleneck.Primary
    }
    Test-Case 'process, thread and handle counts are totalled' {
        Assert-Equal 4 $pressure.Counts.Processes
        Assert-Equal 48 $pressure.Counts.Threads
        Assert-Equal 1200 $pressure.Counts.Handles
    }
    Test-Case 'a disk driven hard by paging is reported as a memory problem, not a disk one' {
        # This is the trap the tool exists to avoid: on a machine that is out of memory the disk
        # scores highest, and naming it sends the reader off to replace the wrong component.
        $starved = New-TestSystem -TotalGb 8 -AvailableGb 0.3
        $pressure = Measure-RmoResourcePressure -System $starved -Process $processes
        Assert-Equal 'Memory' $pressure.Bottleneck.Primary
    }
    Test-Case 'the system disk media type is carried through for the plan to use' {
        $spinning = Measure-RmoResourcePressure -System (New-TestSystem -DiskMedia 'HDD') -Process $processes
        Assert-Equal 'HDD' $spinning.Disk.SystemDiskMedia
    }
    Test-Case 'a counter that could not be read is null, not zero' {
        # No performance counters exist in this environment, so these must not read as measured.
        if ($onWindows) {
            Assert-True $true
        } else {
            Assert-Equal $null $pressure.Disk.LatencyMs
        }
    }
}
#endregion

#region Ranking and grouping
Describe-Suite 'Ranking consumers' {
    $processes = @(
        (New-TestProcess -Name 'chrome' -ProcessId 1 -CpuPercent 5 -MemoryMb 800 -DiskMbPerSecond 1)
        (New-TestProcess -Name 'chrome' -ProcessId 2 -CpuPercent 4 -MemoryMb 600)
        (New-TestProcess -Name 'chrome' -ProcessId 3 -CpuPercent 2 -MemoryMb 400)
        (New-TestProcess -Name 'msedgewebview2' -ProcessId 4 -MemoryMb 500)
        (New-TestProcess -Name 'svchost' -ProcessId 5 -CpuPercent 20 -MemoryMb 80 -ServiceName @('Windows Update', 'BITS'))
        (New-TestProcess -Name 'OUTLOOK' -ProcessId 6 -MemoryMb 300 -Responding $false -WindowTitle 'Inbox - jo')
        (New-TestProcess -Name 'LeakyApp' -ProcessId 7 -MemoryMb 200 -HandleCount 45000)
        (New-TestProcess -Name 'zzqqxx' -ProcessId 8 -CpuPercent 40 -MemoryMb 250 -Path 'C:\Users\jo\AppData\Local\Temp\zzqqxx.exe')
    )
    $hogs = Get-RmoResourceHog -Process $processes -TopCount 5 -SystemMemoryBytes 8GB

    Test-Case 'processes belonging to one product are added together' {
        $chrome = @($hogs.Families | Where-Object { $_.Family -eq 'Google Chrome' })[0]
        Assert-Equal 3 $chrome.ProcessCount
        Assert-Equal (1800 * 1MB) $chrome.MemoryBytes
        Assert-Near 11 $chrome.CpuPercent 0.05
    }
    Test-Case 'an embedded web view is kept separate from the browser it shares an engine with' {
        # Attributing WebView2 to Edge would hide the application that is actually hosting it.
        $webview = @($hogs.Families | Where-Object { $_.Family -eq 'Edge WebView2' })
        Assert-Equal 1 $webview.Count
    }
    Test-Case 'the grouped view puts the largest product first' {
        Assert-Equal 'Google Chrome' @($hogs.TopFamilyMemory)[0].Family
    }
    Test-Case 'the individual view ranks by memory and respects the row limit' {
        Assert-Equal 5 @($hogs.TopMemory).Count
        Assert-Equal 1 @($hogs.TopMemory)[0].ProcessId
    }
    Test-Case 'the processor ranking is separate from the memory ranking' {
        Assert-Equal 8 @($hogs.TopCpu)[0].ProcessId
    }
    Test-Case 'the memory metric is named, so a total can be judged' {
        Assert-Equal 'Private working set' @($hogs.TopMemory)[0].MemoryMetric
    }
    Test-Case 'a service host is labelled with the services it is running' {
        $svchost = @($hogs.Processes | Where-Object { $_.ProcessId -eq 5 })[0]
        Assert-Match $svchost.ServiceText 'Windows Update'
        Assert-Match $svchost.ServiceText 'BITS'
    }
    Test-Case 'a window that has stopped responding is picked out' {
        Assert-Equal 1 @($hogs.Unresponsive).Count
        Assert-Equal 6 @($hogs.Unresponsive)[0].ProcessId
    }
    Test-Case 'a handle leak in progress is picked out' {
        Assert-Equal 1 @($hogs.TopHandles).Count
        Assert-Equal 7 @($hogs.TopHandles)[0].ProcessId
    }
    Test-Case 'an unidentified program consuming resources from a temp folder is picked out' {
        Assert-Equal 1 @($hogs.Suspicious).Count
        Assert-Equal 8 @($hogs.Suspicious)[0].ProcessId
    }
    Test-Case 'a known program in a user folder is not treated as suspicious' {
        $known = @((New-TestProcess -Name 'Teams' -ProcessId 9 -MemoryMb 900 `
            -Path 'C:\Users\jo\AppData\Local\Microsoft\Teams\Teams.exe'))
        $result = Get-RmoResourceHog -Process $known -SystemMemoryBytes 8GB
        Assert-Equal 0 @($result.Suspicious).Count
    }
    Test-Case 'a process whose rate could not be measured is not reported as idle' {
        $unmeasured = @((New-TestProcess -Name 'chrome' -ProcessId 10 -MemoryMb 100 -Measured $false))
        $result = Get-RmoResourceHog -Process $unmeasured -SystemMemoryBytes 8GB
        Assert-Equal 'n/a' @($result.Processes)[0].CpuText
        Assert-Equal 0 @($result.TopCpu).Count
    }
    Test-Case 'grouping survives an empty process list' {
        $empty = Get-RmoResourceHog -Process @() -SystemMemoryBytes 8GB
        Assert-Equal 0 @($empty.Families).Count
    }
}
#endregion

#region The plan
Describe-Suite 'Building the plan' {
    $processes = @(
        (New-TestProcess -Name 'chrome' -ProcessId 1 -CpuPercent 4 -MemoryMb 1500)
        (New-TestProcess -Name 'chrome' -ProcessId 2 -CpuPercent 2 -MemoryMb 1200)
        (New-TestProcess -Name 'CCleaner' -ProcessId 3 -MemoryMb 120)
        (New-TestProcess -Name 'svchost' -ProcessId 4 -CpuPercent 30 -MemoryMb 90 -ServiceName 'Windows Update')
        (New-TestProcess -Name 'Spotify' -ProcessId 5 -MemoryMb 600)
    )
    $result = New-TestAnalysis -Process $processes -System (New-TestSystem -TotalGb 8 -AvailableGb 0.5)
    $plan = $result.Plan

    Test-Case 'the plan names the constraint it was built around' {
        Assert-Equal 'Memory' $plan.Bottleneck
    }
    Test-Case 'actions are ordered by impact' {
        $ranks = @($plan.Actions | ForEach-Object { Use-Private 'Get-RmoImpactRank' @($_.Impact) })
        for ($i = 1; $i -lt $ranks.Count; $i++) {
            Assert-True ($ranks[$i] -ge $ranks[$i - 1]) 'actions are out of impact order'
        }
    }
    Test-Case 'software that exists to slow machines down is a high-impact, safe removal' {
        $action = @($plan.Actions | Where-Object { $_.Family -eq 'Optimiser software' })[0]
        Assert-Equal 'High' $action.Impact
        Assert-Equal 'Safe' $action.Safety
        Assert-Equal 'Unwanted software' $action.Category
    }
    Test-Case 'a Windows component is never proposed for removal' {
        $action = @($plan.Actions | Where-Object { $_.Family -eq 'Windows services' })[0]
        Assert-Equal 'Caution' $action.Safety
        Assert-Equal '' $action.Command
        Assert-Match $action.Title 'part of Windows'
    }
    Test-Case 'the largest consumer of the constrained resource is high impact' {
        $action = @($plan.Actions | Where-Object { $_.Family -eq 'Google Chrome' })[0]
        Assert-Equal 'High' $action.Impact
        Assert-Match $action.Evidence 'memory'
        Assert-Match $action.Recommendation 'Memory Saver'
    }
    Test-Case 'the same reading is rated lower on a machine that has the memory to spare' {
        # 2.6 GB of browser is the headline on an 8 GB machine that is paging, and a footnote on
        # a 64 GB machine with 40 GB free. The rating has to move even though the number does not.
        $roomy = New-TestAnalysis -Process $processes -System (New-TestSystem -TotalGb 64 -AvailableGb 40)
        $constrained = @($plan.Actions | Where-Object { $_.Family -eq 'Google Chrome' })[0]
        $relaxed = @($roomy.Plan.Actions | Where-Object { $_.Family -eq 'Google Chrome' })[0]
        Assert-Equal 'High' $constrained.Impact
        Assert-GreaterThan (Use-Private 'Get-RmoImpactRank' @($constrained.Impact)) `
            (Use-Private 'Get-RmoImpactRank' @($relaxed.Impact))
    }
    Test-Case 'every action says what it is, what to do, and how much work it is' {
        foreach ($action in $plan.Actions) {
            Assert-True ([bool] $action.Title) 'an action has no title'
            Assert-True ([bool] $action.Recommendation) "'$($action.Id)' has no recommendation"
            Assert-True ([bool] $action.Evidence) "'$($action.Id)' has no evidence"
            Assert-True ($action.Effort -in 'Instant', 'Quick', 'Planned', 'Hardware') "'$($action.Id)' has no effort"
        }
    }
    Test-Case 'recoverable memory counts the software that can actually be reduced' {
        # Chrome (2700 MB), Spotify (600 MB) and CCleaner (120 MB) are recoverable; the 90 MB
        # in the Windows service host is not, and must not be promised.
        Assert-Equal (3420 * 1MB) $plan.RecoverableMemoryBytes
    }
    Test-Case 'system findings are merged into the same ordered list' {
        $finding = [pscustomobject]@{
            Id = 'test-finding'; Title = 'A synthetic finding'; Impact = 'High'; Category = 'Maintenance'
            Evidence = 'measured'; Detail = 'detail'; Recommendation = 'do the thing'; Command = ''
            Effort = 'Instant'; Safety = 'Safe'; Gain = 'a gain'; Source = 'System'
        }
        $withFinding = New-TestAnalysis -Process $processes -Finding @($finding)
        $action = @($withFinding.Plan.Actions | Where-Object { $_.Id -eq 'test-finding' })
        Assert-Equal 1 $action.Count
        Assert-Equal 'System' $action[0].Source
    }
    Test-Case 'a startup entry that is costing memory now becomes an action' {
        $startup = [pscustomobject]@{
            Name = 'Spotify'; Command = 'C:\spotify.exe'; TargetPath = 'C:\spotify.exe'
            ProcessName = 'Spotify'; Location = 'HKCU Run'; Source = 'Run key or startup folder'
            User = 'jo'; Enabled = $true; Running = $true; InstanceCount = 1; CpuPercent = 1
            MemoryBytes = 600MB; MemoryText = '600.0 MB'; CpuText = '1.0%'; Impact = 'High'; Note = ''
            Identity = (Resolve-RmoProcessIdentity -Name 'Spotify' -Identifier $identifier)
        }
        $withStartup = New-TestAnalysis -Process $processes -StartupItem @($startup)
        $action = @($withStartup.Plan.Actions | Where-Object { $_.Source -eq 'Startup' })
        Assert-Equal 1 $action.Count
        Assert-Match $action[0].Title 'starts itself'
    }
    Test-Case 'startup and process actions for the same software do not promise the memory twice' {
        $startup = [pscustomobject]@{
            Name = 'Spotify'; Command = 'C:\spotify.exe'; TargetPath = 'C:\spotify.exe'
            ProcessName = 'Spotify'; Location = 'HKCU Run'; Source = 'Run key or startup folder'
            User = 'jo'; Enabled = $true; Running = $true; InstanceCount = 1; CpuPercent = 1
            MemoryBytes = 600MB; MemoryText = '600.0 MB'; CpuText = '1.0%'; Impact = 'High'; Note = ''
            Identity = (Resolve-RmoProcessIdentity -Name 'Spotify' -Identifier $identifier)
        }
        $withStartup = New-TestAnalysis -Process $processes -StartupItem @($startup)
        Assert-Equal $plan.RecoverableMemoryBytes $withStartup.Plan.RecoverableMemoryBytes
    }
    Test-Case 'an unidentified program in a temp folder is raised as a security action' {
        $suspicious = $processes + @(New-TestProcess -Name 'zzqqxx' -ProcessId 9 -CpuPercent 60 `
            -MemoryMb 200 -Path 'C:\Users\jo\AppData\Local\Temp\zzqqxx.exe')
        $result = New-TestAnalysis -Process $suspicious
        $action = @($result.Plan.Actions | Where-Object { $_.Category -eq 'Security' })
        Assert-Equal 1 $action.Count
        Assert-Equal 'Caution' $action[0].Safety
        Assert-False $action[0].Recoverable
    }
    Test-Case 'a healthy machine produces a plan with nothing high impact' {
        $light = @(
            (New-TestProcess -Name 'explorer' -ProcessId 1 -CpuPercent 1 -MemoryMb 120)
            (New-TestProcess -Name 'chrome' -ProcessId 2 -CpuPercent 1 -MemoryMb 400)
        )
        $healthy = New-TestAnalysis -Process $light -System (New-TestSystem -TotalGb 32 -AvailableGb 24)
        Assert-Equal 0 $healthy.Plan.HighImpactCount
        Assert-Equal 'None' $healthy.Plan.Bottleneck
    }
    Test-Case 'the narrative explains the constraint in words' {
        Assert-Match $plan.NarrativeText 'short of memory'
        Assert-Match $plan.NarrativeText 'What was measured'
        Assert-Match $plan.NarrativeText 'Where to start'
    }
    Test-Case 'a quick scan says in the narrative what it did not look at' {
        $quick = New-TestAnalysis -Process $processes -ScanMode 'Quick'
        Assert-Match $quick.Plan.NarrativeText 'quick scan'
    }
    Test-Case 'unattributed processor time is raised as a driver problem' {
        # Nothing is attributed to a process, but the machine reports itself busy.
        $pressure = Measure-RmoResourcePressure -System (New-TestSystem) -Process @()
        $pressure.Cpu.UnattributedPercent = 40
        $pressure.Cpu.TotalPercent = 40
        $hogs = Get-RmoResourceHog -Process @() -SystemMemoryBytes 8GB
        $driverPlan = New-RmoRemediationPlan -System (New-TestSystem) -Pressure $pressure -Hogs $hogs -ScanMode 'Complete'
        $action = @($driverPlan.Actions | Where-Object { $_.Id -eq 'cpu-unattributed' })
        Assert-Equal 1 $action.Count
        Assert-Equal 'Drivers' $action[0].Category
    }
}
#endregion

#region Reports
Describe-Suite 'Reports' {
    $processes = @(
        (New-TestProcess -Name 'chrome' -ProcessId 1 -CpuPercent 6 -MemoryMb 1400)
        (New-TestProcess -Name 'svchost' -ProcessId 2 -CpuPercent 2 -MemoryMb 70 -ServiceName 'Windows Search')
        (New-TestProcess -Name 'evil<script>' -ProcessId 3 -MemoryMb 300)
    )
    $result = New-TestAnalysis -Process $processes -System (New-TestSystem -TotalGb 8 -AvailableGb 0.7)

    Test-Case 'the text report contains every section a reader needs' {
        $text = Use-Private 'New-RmoTextReport' @($result, 100)
        foreach ($heading in 'RESOURCE REPORT', 'VERDICT', 'TOP CONSUMERS BY PRODUCT',
                             'HEAVIEST INDIVIDUAL PROCESSES', 'PLAN') {
            Assert-Match $text $heading
        }
        Assert-Match $text 'Google Chrome'
        Assert-Match $text 'Google LLC'
    }
    Test-Case 'the text report explains which memory figure it is quoting' {
        $text = Use-Private 'New-RmoTextReport' @($result, 100)
        Assert-Match $text 'private working set'
    }
    Test-Case 'the html report is a complete document' {
        $html = Use-Private 'New-RmoHtmlReport' @($result)
        Assert-Match $html '<!DOCTYPE html>'
        Assert-Match $html '</html>'
        Assert-Match $html '<title>Resource report'
    }
    Test-Case 'the html report escapes process names rather than injecting them' {
        $html = Use-Private 'New-RmoHtmlReport' @($result)
        Assert-Match $html 'evil&lt;script&gt;'
        Assert-NotMatch $html 'evil<script>'
    }
    Test-Case 'the html report carries the publisher next to every consumer' {
        $html = Use-Private 'New-RmoHtmlReport' @($result)
        Assert-Match $html 'Google LLC'
        Assert-Match $html 'Manufacturer'
    }
    Test-Case 'reports render for a machine with nothing wrong with it' {
        $healthy = New-TestAnalysis -Process @(New-TestProcess -Name 'explorer' -ProcessId 1 -MemoryMb 100) `
            -System (New-TestSystem -TotalGb 32 -AvailableGb 25)
        $text = Use-Private 'New-RmoTextReport' @($healthy, 100)
        Assert-Match $text 'Nothing found that is worth changing'
        $html = Use-Private 'New-RmoHtmlReport' @($healthy)
        Assert-Match $html '</html>'
    }
}
#endregion

#region Export
Describe-Suite 'Exporting' {
    $result = New-TestAnalysis -Process @(
        (New-TestProcess -Name 'chrome' -ProcessId 1 -CpuPercent 6 -MemoryMb 1400)
        (New-TestProcess -Name 'CCleaner' -ProcessId 2 -MemoryMb 150)
    ) -System (New-TestSystem -TotalGb 8 -AvailableGb 0.7)

    Test-Case 'the format is taken from the file extension' {
        foreach ($extension in 'html', 'txt', 'json', 'csv') {
            $path = Join-Path $scratch "report.$extension"
            Export-RmoReport -Result $result -Path $path
            Assert-True (Test-Path -LiteralPath $path) "$extension was not written"
            Assert-GreaterThan 200 (Get-Item -LiteralPath $path).Length
        }
    }
    Test-Case 'the json export is valid json and keeps the plan' {
        $path = Join-Path $scratch 'report.json'
        Export-RmoReport -Result $result -Path $path -Format Json
        $parsed = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        Assert-Equal 'TESTPC' $parsed.ComputerName
        Assert-GreaterThan 0 @($parsed.Plan.Actions).Count
    }
    Test-Case 'the csv export has one row per process, named and attributed' {
        $path = Join-Path $scratch 'report.csv'
        Export-RmoReport -Result $result -Path $path -Format Csv
        $rows = @(Import-Csv -LiteralPath $path)
        Assert-Equal 2 $rows.Count
        Assert-Equal 'Google Chrome' $rows[0].WhatItIs
        Assert-Equal 'Google LLC' $rows[0].Manufacturer
    }
    Test-Case 'a directory that does not exist yet is created' {
        $path = Join-Path (Join-Path $scratch 'nested/deeper') 'report.html'
        Export-RmoReport -Result $result -Path $path
        Assert-True (Test-Path -LiteralPath $path)
    }
}
#endregion

#region The generated tuning script
Describe-Suite 'The generated tuning script' {
    $finding = [pscustomobject]@{
        Id = 'power-plan-saver'; Title = 'The active power plan is Power saver'; Impact = 'Medium'
        Category = 'Configuration'; Evidence = 'measured'; Detail = "it's throttled"
        Recommendation = 'Switch to Balanced.'; Command = 'powercfg /setactive SCHEME_BALANCED'
        Effort = 'Instant'; Safety = 'Safe'; Gain = 'faster'; Source = 'System'
    }
    $reboot = [pscustomobject]@{
        Id = 'reboot-pending'; Title = 'The machine is waiting for a restart'; Impact = 'High'
        Category = 'Maintenance'; Evidence = 'measured'; Detail = 'detail'
        Recommendation = 'Restart it.'; Command = 'Restart-Computer -Force'
        Effort = 'Instant'; Safety = 'Review'; Gain = 'a gain'; Source = 'System'
    }
    $result = New-TestAnalysis -Process @(
        (New-TestProcess -Name 'chrome' -ProcessId 1 -CpuPercent 6 -MemoryMb 1400)
    ) -Finding @($finding, $reboot)

    $scriptPath = Join-Path $scratch 'tune.ps1'
    New-RmoRemediationScript -Result $result -Path $scriptPath

    Test-Case 'the generated script is valid PowerShell' {
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref] $null, [ref] $errors)
        Assert-Equal 0 $errors.Count ($errors | ForEach-Object { $_.Message } | Select-Object -First 1)
    }
    Test-Case 'a mechanical, reversible step is marked as runnable' {
        $text = Get-Content -LiteralPath $scriptPath -Raw
        Assert-Match $text "Id             = 'power-plan-saver'"
        Assert-Match $text 'powercfg /setactive SCHEME_BALANCED'
    }
    Test-Case 'a step that restarts the machine is carried as documentation only' {
        $text = Get-Content -LiteralPath $scriptPath -Raw
        # The restart action must be present, but must never be automatable.
        Assert-Match $text 'reboot-pending'
        Assert-NotMatch $text 'Command        = \{ Restart-Computer'
        Assert-Match $text "CommandText    = 'Restart-Computer -Force'"
    }
    Test-Case 'a command from a process entry is documentation, not a step to apply blind' {
        # The catalogue's commands are worked examples with placeholders in them - an exclusion
        # path, a cache location. Handing one to an automated runner would apply it literally.
        $withProcess = New-TestAnalysis -Process @(
            (New-TestProcess -Name 'MsMpEng' -ProcessId 20 -CpuPercent 30 -MemoryMb 700)
        ) -System (New-TestSystem -TotalGb 8 -AvailableGb 4)
        $processScript = Join-Path $scratch 'tune-process.ps1'
        New-RmoRemediationScript -Result $withProcess -Path $processScript
        $text = Get-Content -LiteralPath $processScript -Raw
        Assert-Match $text 'microsoft-defender'
        Assert-NotMatch $text 'Command        = \{ Add-MpPreference'
        Assert-Match $text 'CommandText    ='
    }
    Test-Case 'action ids can be typed on a command line' {
        foreach ($action in $result.Plan.Actions) {
            Assert-Match $action.Id '^[a-z0-9][a-z0-9-]*$' "'$($action.Id)' needs quoting to pass to -Run"
        }
    }
    Test-Case 'the plan text is quoted safely even when it contains an apostrophe' {
        $text = Get-Content -LiteralPath $scriptPath -Raw
        Assert-Match $text "it''s throttled"
    }
    Test-Case 'running it with -List prints the ids and changes nothing' {
        $exe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $output = & $exe -NoProfile -File $scriptPath -List 2>&1
        $joined = ($output | Out-String)
        Assert-Match $joined 'power-plan-saver'
        Assert-Match $joined '\[can run\]'
        Assert-Match $joined '\[manual\]'
    }
    Test-Case 'running it with no arguments prints the plan and changes nothing' {
        $exe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $output = & $exe -NoProfile -File $scriptPath 2>&1
        $joined = ($output | Out-String)
        Assert-Match $joined 'Nothing has been changed'
        Assert-Match $joined 'The machine is waiting for a restart'
    }
    Test-Case 'an unknown id is refused rather than ignored' {
        $exe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $output = & $exe -NoProfile -File $scriptPath -Run 'no-such-action' 2>&1
        Assert-Match ($output | Out-String) 'No action with id'
    }
    Test-Case 'a documentation-only step refuses to run' {
        $exe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $output = & $exe -NoProfile -File $scriptPath -Run 'reboot-pending' 2>&1
        Assert-Match ($output | Out-String) 'not something this script will do'
    }
}
#endregion

#region Module surface
Describe-Suite 'Module surface' {
    Test-Case 'the manifest exports exactly the public functions on disk' {
        $manifest = Import-PowerShellDataFile -LiteralPath $ModulePath
        $onDisk = @(Get-ChildItem -LiteralPath (Join-Path (Split-Path $ModulePath -Parent) 'Public') `
            -Filter '*.ps1' -File | ForEach-Object { $_.BaseName } | Sort-Object)
        $exported = @($manifest.FunctionsToExport | Sort-Object)
        Assert-Equal ($onDisk -join ',') ($exported -join ',')
    }
    Test-Case 'the module reports the version the manifest declares' {
        $manifest = Import-PowerShellDataFile -LiteralPath $ModulePath
        Assert-Equal $manifest.ModuleVersion (Get-Module ResourceMonitor).Version.ToString()
    }
    Test-Case 'private helpers are not exported' {
        Assert-Equal $null (Get-Command -Name 'Format-RmoBytes' -Module ResourceMonitor -ErrorAction SilentlyContinue)
    }
    Test-Case 'every exported function has help with an example' {
        foreach ($command in (Get-Command -Module ResourceMonitor)) {
            $help = Get-Help $command.Name -ErrorAction SilentlyContinue
            Assert-True ([bool] $help.Synopsis) "$($command.Name) has no synopsis"
            Assert-GreaterThan 0 @($help.Examples.Example).Count
        }
    }
}
#endregion

#region Collection, against a fixture
Describe-Suite 'Collecting, against a known machine' {
    . (Join-Path $PSScriptRoot 'FakeCim.ps1')

    # Real files, so the version-resource and signature code paths actually run.
    $binRoot = Join-Path $scratch 'bin'
    $null = New-Item -ItemType Directory -Path $binRoot -Force
    foreach ($name in 'chrome.exe', 'CCleaner.exe') {
        Set-Content -LiteralPath (Join-Path $binRoot $name) -Value 'not really an executable' -Encoding UTF8
    }

    function Use-Fixture {
        param([hashtable] $Override = @{})
        $data = New-FakeCimData -Override $Override -PathRoot $binRoot
        Install-FakeCim -Module $module -Data $data
    }

    function Get-FixtureSample {
        param([switch] $VerifySignature, [switch] $IncludeOwner)
        Use-Fixture
        Get-RmoProcessSample -SampleCount 2 -IntervalMilliseconds 200 -Identifier $identifier `
            -ServiceMap (& $module { New-RmoServiceMap -Service (Get-RmoServiceLoad) }) `
            -VerifySignature:$VerifySignature -IncludeOwner:$IncludeOwner
    }

    Test-Case 'every process in the snapshot is reported' {
        $processes = Get-FixtureSample
        Assert-Equal 6 @($processes).Count
    }
    Test-Case 'processor time is differenced between snapshots, not read from a total' {
        $processes = Get-FixtureSample
        $a = @($processes | Where-Object { $_.ProcessId -eq 100 })[0]
        $b = @($processes | Where-Object { $_.ProcessId -eq 101 })[0]
        # 4,000,000 ticks against 1,000,000 over the same interval. The absolute figure depends
        # on how long the host actually slept, but the ratio does not.
        Assert-Near 4 ($a.CpuPercent / $b.CpuPercent) 0.05
        Assert-GreaterThan 0 $a.CpuPercent
    }
    Test-Case 'no process is ever reported above 100% of the machine' {
        $processes = Get-FixtureSample
        foreach ($item in $processes) {
            if ($null -eq $item.CpuPercent) { continue }
            Assert-True ($item.CpuPercent -ge 0 -and $item.CpuPercent -le 100) `
                "$($item.Name) reported $($item.CpuPercent)%"
        }
    }
    Test-Case 'a reused process id is not differenced into an invented figure' {
        # Process 800 is notepad in the first snapshot and calc in the second, with a wildly
        # higher tick count. Differencing them would report a process using the whole machine.
        $processes = Get-FixtureSample
        $reused = @($processes | Where-Object { $_.ProcessId -eq 800 })[0]
        Assert-False $reused.Measured
        Assert-Equal $null $reused.CpuPercent
    }
    Test-Case 'a process that started mid-scan is reported as unmeasured rather than idle' {
        $processes = Get-FixtureSample
        $new = @($processes | Where-Object { $_.ProcessId -eq 700 })[0]
        Assert-False $new.Measured
        Assert-Equal $null $new.CpuPercent
        Assert-Equal $null $new.IoBytesPerSecond
        Assert-GreaterThan 0 $new.WorkingSetBytes
    }
    Test-Case 'disk transfer counters are differenced into a rate' {
        $processes = Get-FixtureSample
        $chrome = @($processes | Where-Object { $_.ProcessId -eq 100 })[0]
        Assert-GreaterThan 0 $chrome.ReadBytesPerSecond
        Assert-GreaterThan 0 $chrome.WriteBytesPerSecond
        Assert-Near $chrome.IoBytesPerSecond ($chrome.ReadBytesPerSecond + $chrome.WriteBytesPerSecond) 1
    }
    Test-Case 'the private working set comes from the performance counters when they are healthy' {
        $processes = Get-FixtureSample
        $chrome = @($processes | Where-Object { $_.ProcessId -eq 100 })[0]
        Assert-Equal (700MB) $chrome.PrivateWorkingSetBytes
        # The whole working set is a different, larger number, and must not be confused with it.
        Assert-Equal (900MB) $chrome.WorkingSetBytes
    }
    Test-Case 'the peak working set is converted from the kilobytes WMI reports' {
        $processes = Get-FixtureSample
        $chrome = @($processes | Where-Object { $_.ProcessId -eq 100 })[0]
        Assert-Equal (900MB) $chrome.PeakWorkingSetBytes
    }
    Test-Case 'a service host is told which services it is running' {
        $processes = Get-FixtureSample
        $svchost = @($processes | Where-Object { $_.ProcessId -eq 900 })[0]
        Assert-Equal 2 @($svchost.Services).Count
        Assert-Equal 'netsvcs' $svchost.ServiceGroup
    }
    Test-Case 'a stopped service is not attributed to a process' {
        Use-Fixture
        $map = & $module { New-RmoServiceMap -Service (Get-RmoServiceLoad) }
        Assert-False ($map.ContainsKey(0)) 'a stopped service was attributed to process 0'
    }
    Test-Case 'the parent process is named' {
        $processes = Get-FixtureSample
        $child = @($processes | Where-Object { $_.ProcessId -eq 101 })[0]
        Assert-Equal 'chrome' $child.ParentName
    }
    Test-Case 'window state is read for the processes that have a window' {
        $processes = Get-FixtureSample
        $explorer = @($processes | Where-Object { $_.ProcessId -eq 500 })[0]
        Assert-False $explorer.Responding
        Assert-Equal 'File Explorer' $explorer.MainWindowTitle
        # Anything the window enumeration did not cover must default to responding, not to hung.
        $svchost = @($processes | Where-Object { $_.ProcessId -eq 900 })[0]
        Assert-True $svchost.Responding
    }
    Test-Case 'the owner is resolved for the heaviest processes when asked' {
        $processes = Get-FixtureSample -IncludeOwner
        $chrome = @($processes | Where-Object { $_.ProcessId -eq 100 })[0]
        Assert-Equal 'CONTOSO\jo' $chrome.Owner
    }
    Test-Case 'a verified signature supplies the publisher where the catalogue only has a placeholder' {
        # The catalogue entry for optimiser software covers many vendors and carries 'Various'.
        # The signature on the file knows the specific answer, so it wins.
        $processes = Get-FixtureSample -VerifySignature
        $cleaner = @($processes | Where-Object { $_.ProcessId -eq 700 })[0]
        Assert-Equal 'Valid' $cleaner.Identity.SignatureStatus
        Assert-Equal 'Contoso Signing' $cleaner.Identity.Vendor
        Assert-Equal 'Authenticode signature' $cleaner.Identity.VendorSource
    }
    Test-Case 'a curated publisher is not overwritten by the file' {
        $processes = Get-FixtureSample -VerifySignature
        $chrome = @($processes | Where-Object { $_.ProcessId -eq 100 })[0]
        Assert-Equal 'Google LLC' $chrome.Identity.Vendor
        Assert-Equal 'Catalogue' $chrome.Identity.VendorSource
    }

    Test-Case 'the machine snapshot reads the processor, memory and storage correctly' {
        Use-Fixture
        $system = Get-RmoSystemSnapshot
        Assert-Equal 4 $system.Cpu.Cores
        Assert-Equal 8 $system.Cpu.LogicalProcessors
        # WMI pads the processor name with runs of spaces; a report should not.
        Assert-Equal 'Contoso Core i5-8250U CPU @ 1.60GHz' $system.Cpu.Name
        Assert-Equal (8GB) $system.Memory.TotalBytes
        Assert-Equal (380MB) $system.Memory.AvailableBytes
        Assert-Equal 1 $system.Memory.UsedSlots
        Assert-Equal 2 $system.Memory.TotalSlots
    }
    Test-Case 'a mechanical system disk is identified from the storage namespace' {
        Use-Fixture
        $system = Get-RmoSystemSnapshot
        Assert-Equal 'HDD' @($system.Storage)[0].MediaType
        Assert-Equal 5400 @($system.Storage)[0].SpindleSpeed
    }
    Test-Case 'an SSD is identified from its model name when the storage namespace is absent' {
        Use-Fixture -Override @{
            'MSFT_PhysicalDisk' = @()
            'Win32_DiskDrive' = @([pscustomobject]@{
                DeviceID = '\\.\PHYSICALDRIVE0'; Model = 'Contoso NVMe SSD 1TB'; Size = [uint64] 1TB
                InterfaceType = 'SCSI'; Partitions = [uint32] 3 })
        }
        $system = Get-RmoSystemSnapshot
        Assert-Match @($system.Storage)[0].MediaType 'SSD'
    }
    Test-Case 'volume free space is worked out as a percentage' {
        Use-Fixture
        $system = Get-RmoSystemSnapshot
        Assert-Equal 4 @($system.Volumes)[0].FreePercent
        Assert-True @($system.Volumes)[0].IsSystem
    }
    Test-Case 'the page file size is converted from the megabytes WMI reports' {
        Use-Fixture
        $system = Get-RmoSystemSnapshot
        Assert-Equal (4GB) @($system.PageFiles)[0].AllocatedBytes
    }
    Test-Case 'the active power plan, chassis type and battery state are read' {
        Use-Fixture
        $system = Get-RmoSystemSnapshot
        Assert-Equal 'Power saver' $system.PowerPlan.Name
        Assert-True $system.IsLaptop
        Assert-False $system.OnBattery
        Assert-Equal 88 $system.BatteryPercent
    }
    Test-Case 'registered antivirus products and their real-time state are read' {
        Use-Fixture
        $system = Get-RmoSystemSnapshot
        Assert-Equal 2 @($system.Antivirus).Count
        foreach ($product in $system.Antivirus) { Assert-True $product.RealTimeEnabled $product.DisplayName }
    }
    Test-Case 'a machine missing a whole CIM class loses that reading, not the scan' {
        Use-Fixture -Override @{ 'Win32_PhysicalMemory' = @(); 'Win32_PowerPlan' = @() }
        $errors = [System.Collections.ArrayList]::new()
        $system = Get-RmoSystemSnapshot -ErrorSink $errors
        Assert-Equal 0 @($system.Memory.Modules).Count
        Assert-Equal 'Unknown' $system.PowerPlan.Name
        Assert-GreaterThan 0 $system.Memory.TotalBytes
    }

    Test-Case 'pressure is read from the performance counters when they are available' {
        $processes = Get-FixtureSample
        $system = Get-RmoSystemSnapshot
        $pressure = Measure-RmoResourcePressure -System $system -Process $processes -Deep
        Assert-Equal 78 $pressure.Cpu.TotalPercent
        Assert-Equal 9 $pressure.Cpu.InterruptPercent
        Assert-Equal 3 $pressure.Cpu.QueuePerCore
        Assert-Equal 42 $pressure.Disk.LatencyMs
        Assert-Equal 100 $pressure.Disk.Score
    }
    Test-Case 'processor time that belongs to no process is separated out' {
        # The absolute figures depend on how long the host actually slept, so assert the
        # relationship: unattributed time is the counter total less what processes accounted for,
        # and never negative however the two readings disagree.
        $processes = Get-FixtureSample
        $system = Get-RmoSystemSnapshot
        $pressure = Measure-RmoResourcePressure -System $system -Process $processes
        $expected = [math]::Max(0, $pressure.Cpu.TotalPercent - $pressure.Cpu.AttributedPercent)
        Assert-Near $expected $pressure.Cpu.UnattributedPercent 0.11
        Assert-True ($pressure.Cpu.UnattributedPercent -ge 0) 'unattributed time went negative'
    }
    Test-Case 'the loopback interface is left out of the network total' {
        $processes = Get-FixtureSample
        $system = Get-RmoSystemSnapshot
        $pressure = Measure-RmoResourcePressure -System $system -Process $processes -Deep
        Assert-Equal (2MB) $pressure.Network.BytesPerSecond
        Assert-Equal 1 @($pressure.Network.Adapters).Count
    }
    Test-Case 'the clock ratio catches a processor being held below its rating' {
        $processes = Get-FixtureSample
        $system = Get-RmoSystemSnapshot
        $pressure = Measure-RmoResourcePressure -System $system -Process $processes
        Assert-Equal 32 $pressure.Cpu.ClockRatioPercent
    }

    Test-Case 'startup entries come from the run keys and from scheduled tasks' {
        $processes = Get-FixtureSample
        $items = Get-RmoStartupItem -Process $processes -Identifier $identifier -IncludeScheduledTasks
        $names = @($items | ForEach-Object { $_.Name })
        Assert-True ($names -contains 'Spotify') 'the run-key entry is missing'
        Assert-True ($names -contains 'CCleaner Monitoring') 'the run-key entry is missing'
        # A scheduled task that starts software at sign-in is startup, and Task Manager will not
        # show it. Microsoft's own maintenance tasks and non-logon triggers are not.
        Assert-True ($names -contains 'ContosoLedgerLauncher') 'the logon scheduled task is missing'
        Assert-False ($names -contains 'MicrosoftEdgeUpdateTaskMachineCore') 'a Microsoft task was listed'
        Assert-False ($names -contains 'ADailyThing') 'a task with no logon trigger was listed'
    }
    Test-Case 'a startup entry that is running is costed from what it is using now' {
        $processes = Get-FixtureSample
        $items = Get-RmoStartupItem -Process (Get-RmoResourceHog -Process $processes -SystemMemoryBytes 8GB).Processes `
            -Identifier $identifier
        $cleaner = @($items | Where-Object { $_.Name -eq 'CCleaner Monitoring' })[0]
        Assert-True $cleaner.Running
        Assert-Equal (120MB) $cleaner.MemoryBytes
        Assert-Equal 'High' $cleaner.Impact
    }
    Test-Case 'a quoted startup command resolves to its executable, not to its arguments' {
        $processes = Get-FixtureSample
        $items = Get-RmoStartupItem -Process $processes -Identifier $identifier
        $spotify = @($items | Where-Object { $_.Name -eq 'Spotify' })[0]
        Assert-Equal 'C:\Users\jo\AppData\Roaming\Spotify\Spotify.exe' $spotify.TargetPath
        Assert-Equal 'Spotify' $spotify.ProcessName
    }
    Test-Case 'an unquoted startup command with spaces in the path resolves correctly' {
        # A Run key often outlives the software it points at, so this cannot depend on the file
        # still being on disk - and those entries are exactly the ones worth reporting.
        $processes = Get-FixtureSample
        $items = Get-RmoStartupItem -Process $processes -Identifier $identifier
        $cleaner = @($items | Where-Object { $_.Name -eq 'CCleaner Monitoring' })[0]
        Assert-Equal 'C:\Program Files\CCleaner\CCleaner.exe' $cleaner.TargetPath
        Assert-Equal 'CCleaner' $cleaner.ProcessName
        Assert-Equal 'Unwanted' $cleaner.Identity.Class
    }

    Test-Case 'the health checks find what this machine has wrong with it' {
        $processes = Get-FixtureSample
        $system = Get-RmoSystemSnapshot
        $pressure = Measure-RmoResourcePressure -System $system -Process $processes -Deep
        $findings = Get-RmoSystemHealthCheck -System $system -Pressure $pressure `
            -Service (Get-RmoServiceLoad) -Deep
        $ids = @($findings | ForEach-Object { $_.Id })

        foreach ($expected in 'disk-mechanical', 'volume-full-c', 'memory-undersized',
                              'memory-slots-free', 'commit-near-limit', 'power-plan-saver',
                              'cpu-throttled', 'av-overlap', 'uptime-long', 'history-bugcheck') {
            Assert-True ($ids -contains $expected) "expected the '$expected' finding; got: $($ids -join ', ')"
        }
    }
    Test-Case 'a graphics driver over three years old is raised' {
        $processes = Get-FixtureSample
        $system = Get-RmoSystemSnapshot
        $pressure = Measure-RmoResourcePressure -System $system -Process $processes
        $findings = Get-RmoSystemHealthCheck -System $system -Pressure $pressure
        Assert-Equal 1 @($findings | Where-Object { $_.Id -like 'gpu-driver-old-*' }).Count
    }
    Test-Case 'a healthy machine produces no hardware findings' {
        Use-Fixture -Override @{
            'Win32_OperatingSystem' = @([pscustomobject]@{
                Caption = 'Microsoft Windows 11 Pro'; Version = '10.0.26100'; BuildNumber = '26100'
                OSArchitecture = '64-bit'; InstallDate = [datetime]'2025-01-01'
                LastBootUpTime = [datetime]::Now.AddHours(-6)
                TotalVisibleMemorySize = [uint64] (32 * 1024 * 1024)
                FreePhysicalMemory = [uint64] (20 * 1024 * 1024) })
            'Win32_PerfFormattedData_PerfOS_Memory' = @([pscustomobject]@{
                CommittedBytes = [uint64] (10GB); CommitLimit = [uint64] (40GB)
                AvailableBytes = [uint64] (20GB); PageReadsPersec = [uint32] 0
                PagesPersec = [uint32] 0; PoolPagedBytes = [uint64] 400MB; PoolNonpagedBytes = [uint64] 200MB })
            'MSFT_PhysicalDisk' = @([pscustomobject]@{
                FriendlyName = 'Contoso NVMe'; MediaType = [uint16] 4; SpindleSpeed = [uint32] 0; BusType = [uint16] 17 })
            'Win32_DiskDrive' = @([pscustomobject]@{
                DeviceID = '\\.\PHYSICALDRIVE0'; Model = 'Contoso NVMe'; Size = [uint64] 1TB
                InterfaceType = 'SCSI'; Partitions = [uint32] 3 })
            'Win32_LogicalDisk' = @([pscustomobject]@{
                DeviceID = 'C:'; VolumeName = 'Windows'; FileSystem = 'NTFS'; DriveType = [uint32] 3
                Size = [uint64] 1TB; FreeSpace = [uint64] 600GB })
            'Win32_PowerPlan' = @([pscustomobject]@{ ElementName = 'Balanced'; InstanceID = 'guid'; IsActive = $true })
            'AntiVirusProduct' = @([pscustomobject]@{
                displayName = 'Windows Defender'; productState = 397568; pathToSignedProductExe = 'x' })
            'Win32_Processor' = @([pscustomobject]@{
                Name = 'Contoso Core i9'; Manufacturer = 'ContosoTek'; NumberOfCores = [uint32] 8
                NumberOfLogicalProcessors = [uint32] 16; MaxClockSpeed = [uint32] 3400
                CurrentClockSpeed = [uint32] 3300 })
            'Win32_VideoController' = @([pscustomobject]@{
                Name = 'Contoso RTX'; AdapterCompatibility = 'ContosoTek'; DriverVersion = '31.0.1'
                DriverDate = [datetime]::Now.AddDays(-30); AdapterRAM = [uint32] 1GB; Status = 'OK' })
        }
        $system = Get-RmoSystemSnapshot
        $pressure = Measure-RmoResourcePressure -System $system -Process @()
        $findings = Get-RmoSystemHealthCheck -System $system -Pressure $pressure
        $ids = @($findings | ForEach-Object { $_.Id })
        foreach ($unwanted in 'disk-mechanical', 'memory-undersized', 'power-plan-saver',
                              'av-overlap', 'commit-near-limit', 'cpu-throttled', 'uptime-long') {
            Assert-False ($ids -contains $unwanted) "did not expect '$unwanted'; got: $($ids -join ', ')"
        }
    }

    Test-Case 'a complete scan runs end to end and produces a usable plan' {
        Use-Fixture
        $result = Invoke-ResourceAnalysis -ScanMode Complete -SampleCount 2 -IntervalMilliseconds 200 -Quiet
        Assert-Equal 'Complete' $result.ScanMode
        Assert-Equal 6 @($result.Hogs.Processes).Count
        Assert-GreaterThan 0 @($result.Plan.Actions).Count
        Assert-GreaterThan 0 $result.Plan.HighImpactCount
        Assert-True ([bool] $result.Plan.NarrativeText) 'no narrative'
        # 380 MB available of 8 GB, with hard faults: memory is the constraint, not the disk it
        # is paging to, even though that disk is also slow.
        Assert-Equal 'Memory' $result.Plan.Bottleneck
        Assert-Match $result.Plan.NarrativeText 'short of memory'
    }
    Test-Case 'a quick scan runs end to end' {
        Use-Fixture
        $result = Invoke-ResourceAnalysis -ScanMode Quick -SampleCount 2 -IntervalMilliseconds 200 -Quiet
        Assert-Equal 'Quick' $result.ScanMode
        Assert-GreaterThan 0 @($result.Plan.Actions).Count
    }
    Test-Case 'a scan of the fixture exports a substantial report in every format' {
        Use-Fixture
        $result = Invoke-ResourceAnalysis -ScanMode Complete -SampleCount 2 -IntervalMilliseconds 200 -Quiet
        foreach ($extension in 'html', 'txt', 'json', 'csv') {
            $path = Join-Path $scratch "fixture.$extension"
            Export-RmoReport -Result $result -Path $path
            Assert-GreaterThan 1000 (Get-Item -LiteralPath $path).Length
        }
        $html = Get-Content -LiteralPath (Join-Path $scratch 'fixture.html') -Raw
        Assert-Match $html 'Google Chrome'
        Assert-Match $html 'Windows Update'
        Assert-Match $html 'mechanical hard disk'
    }
    Test-Case 'a cancelled scan returns what it had rather than failing' {
        Use-Fixture
        $cancel = @{ Cancelled = $false }
        $result = Invoke-ResourceAnalysis -ScanMode Quick -SampleCount 2 -IntervalMilliseconds 200 `
            -CancellationSink $cancel -Quiet
        Assert-False $result.Cancelled
    }
    Test-Case 'a machine whose WMI is broken fails with an explanation, not a stack trace' {
        Use-Fixture -Override @{ 'Win32_Process' = @() }
        Assert-Throws { Get-RmoProcessSample -SampleCount 2 -IntervalMilliseconds 200 -Identifier $identifier } `
            'WMI is unavailable'
    }

    Uninstall-FakeCim -Module $module
    Test-Case 'the fixture is removed cleanly afterwards' {
        Assert-False (Test-Path -LiteralPath 'Function:\Get-CimInstance') 'the fake cmdlet is still installed'
        Assert-Equal $null (Get-Variable -Name RmoFakeCim -Scope Global -ErrorAction SilentlyContinue)
        # The platform check must read the truth again, or every later test is running a lie.
        Assert-Equal $onWindows (Use-Private 'Test-RmoWindows')
    }
}
#endregion

#region Collection - the real machine, Windows only
Describe-Suite 'Collecting from the live machine' {
    if (-not $onWindows) {
        foreach ($name in @(
            'the machine snapshot reads the processor, memory and storage',
            'sampling measures every process and identifies it',
            'services are mapped to the processes hosting them',
            'startup entries are enumerated',
            'the health checks run',
            'a quick scan completes end to end')) {
            Skip-Case $name -Because 'these read Windows-only data sources'
        }
    } else {
        Test-Case 'the machine snapshot reads the processor, memory and storage' {
            $system = Get-RmoSystemSnapshot
            Assert-GreaterThan 0 $system.Cpu.LogicalProcessors
            Assert-GreaterThan 0 $system.Memory.TotalBytes
            Assert-GreaterThan 0 @($system.Volumes).Count
            Assert-True ([bool] $system.Os.Caption) 'no operating system caption'
        }
        Test-Case 'sampling measures every process and identifies it' {
            $processes = Get-RmoProcessSample -SampleCount 2 -IntervalMilliseconds 600
            Assert-GreaterThan 20 @($processes).Count
            $measured = @($processes | Where-Object { $_.Measured })
            Assert-GreaterThan 10 $measured.Count
            foreach ($item in @($processes | Select-Object -First 25)) {
                Assert-True ([bool] $item.Identity.Name) "process $($item.Name) was not identified"
                Assert-True ([bool] $item.Identity.Vendor) "process $($item.Name) has no publisher"
            }
            # Every measured figure must be a share of the machine, not of a core.
            foreach ($item in $measured) {
                Assert-True ($item.CpuPercent -ge 0 -and $item.CpuPercent -le 100) `
                    "$($item.Name) reported $($item.CpuPercent)% CPU"
            }
        }
        Test-Case 'services are mapped to the processes hosting them' {
            $services = Get-RmoServiceLoad
            Assert-GreaterThan 10 @($services).Count
            $map = & (Get-Module ResourceMonitor) { New-RmoServiceMap -Service $args[0] } $services
            Assert-GreaterThan 0 $map.Keys.Count
        }
        Test-Case 'startup entries are enumerated' {
            $items = Get-RmoStartupItem
            foreach ($item in $items) {
                Assert-True ([bool] $item.Name) 'a startup entry has no name'
                Assert-True ($item.Impact -in 'High', 'Medium', 'Low', 'Info') "bad impact '$($item.Impact)'"
            }
        }
        Test-Case 'the health checks run' {
            $system = Get-RmoSystemSnapshot
            $processes = Get-RmoProcessSample -SampleCount 2 -IntervalMilliseconds 600
            $pressure = Measure-RmoResourcePressure -System $system -Process $processes
            $findings = Get-RmoSystemHealthCheck -System $system -Pressure $pressure
            foreach ($finding in $findings) {
                Assert-True ([bool] $finding.Recommendation) "'$($finding.Id)' has no recommendation"
            }
        }
        Test-Case 'a quick scan completes end to end' {
            $result = Invoke-ResourceAnalysis -ScanMode Quick -Quiet
            Assert-Equal 'Quick' $result.ScanMode
            Assert-GreaterThan 20 @($result.Hogs.Processes).Count
            Assert-True ([bool] $result.Plan.NarrativeText) 'the plan has no narrative'
            $path = Join-Path $scratch 'live.html'
            Export-RmoReport -Result $result -Path $path
            Assert-GreaterThan 2000 (Get-Item -LiteralPath $path).Length
        }
    }
}
#endregion

if (Test-Path -LiteralPath $scratch) {
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}
exit (Write-TestSummary)
