function Get-RmoSystemSnapshot {
    <#
        .SYNOPSIS
            Describes the machine the scan is running on.

        .DESCRIPTION
            A resource reading only means something against the machine it came from. 90% memory
            use on a 64 GB workstation and 90% on an 8 GB laptop are different problems with
            different answers, and "the disk is at 100%" means one thing on an NVMe SSD and
            something else entirely on a 5400 rpm laptop drive.

            So this collects what the plan needs to know: the processor, how much memory is
            fitted and whether there is a free slot to add more, what the system disk actually
            is, the display adapter and its driver date, the active power plan, whether the
            machine is a laptop running on battery, and which antivirus products are registered.

            Every reading is taken independently. A machine missing the Storage namespace or the
            power namespace loses that one field, not the scan.

        .PARAMETER ErrorSink
            Optional list; readings that could not be taken are recorded here.

        .EXAMPLE
            $system = Get-RmoSystemSnapshot
            $system.Memory.TotalBytes
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param([System.Collections.IList] $ErrorSink)

    if (-not (Test-RmoWindows)) { throw 'Get-RmoSystemSnapshot requires Windows.' }

    #region Operating system and computer
    $os = Get-RmoFirstOrDefault (Invoke-RmoCim -ClassName 'Win32_OperatingSystem' -ErrorSink $ErrorSink)
    $computer = Get-RmoFirstOrDefault (Invoke-RmoCim -ClassName 'Win32_ComputerSystem' -ErrorSink $ErrorSink)

    $lastBoot = Get-RmoObjectValue $os 'LastBootUpTime'
    $uptimeSeconds = $null
    if ($null -ne $lastBoot) {
        try { $uptimeSeconds = ([datetime]::Now - $lastBoot).TotalSeconds } catch { $uptimeSeconds = $null }
    }

    $enclosures = Invoke-RmoCim -ClassName 'Win32_SystemEnclosure' -ErrorSink $ErrorSink
    $portableChassis = @(8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32)
    $isLaptop = $false
    foreach ($enclosure in $enclosures) {
        foreach ($type in @(Get-RmoObjectValue $enclosure 'ChassisTypes' @())) {
            if ([int] $type -in $portableChassis) { $isLaptop = $true }
        }
    }

    $batteries = Invoke-RmoCim -ClassName 'Win32_Battery' -ErrorSink $ErrorSink
    $onBattery = $false
    $batteryPercent = $null
    foreach ($battery in $batteries) {
        # BatteryStatus 1 is "discharging", i.e. no mains power.
        if ([int] (Get-RmoObjectValue $battery 'BatteryStatus' 0) -eq 1) { $onBattery = $true }
        $charge = Get-RmoObjectValue $battery 'EstimatedChargeRemaining'
        if ($null -ne $charge) { $batteryPercent = [int] $charge }
    }
    #endregion

    #region Processor
    $processors = @(Invoke-RmoCim -ClassName 'Win32_Processor' -ErrorSink $ErrorSink)
    $cores = 0
    $logical = 0
    $maxClock = 0
    $currentClock = 0
    $cpuName = 'Unknown processor'
    $cpuVendor = ''
    foreach ($processor in $processors) {
        $cores += [int] (Get-RmoObjectValue $processor 'NumberOfCores' 0)
        $logical += [int] (Get-RmoObjectValue $processor 'NumberOfLogicalProcessors' 0)
        $thisMax = [int] (Get-RmoObjectValue $processor 'MaxClockSpeed' 0)
        if ($thisMax -gt $maxClock) { $maxClock = $thisMax }
        $thisCurrent = [int] (Get-RmoObjectValue $processor 'CurrentClockSpeed' 0)
        if ($thisCurrent -gt $currentClock) { $currentClock = $thisCurrent }
        $name = [string] (Get-RmoObjectValue $processor 'Name' '')
        if ($name) { $cpuName = $name.Trim() -replace '\s{2,}', ' ' }
        $vendor = [string] (Get-RmoObjectValue $processor 'Manufacturer' '')
        if ($vendor) { $cpuVendor = $vendor.Trim() }
    }
    if ($logical -le 0) { $logical = [Environment]::ProcessorCount }
    if ($cores -le 0) { $cores = $logical }
    #endregion

    #region Memory, including whether there is room to add any
    $totalMemory = [double] (Get-RmoObjectValue $os 'TotalVisibleMemorySize' 0) * 1024
    if ($totalMemory -le 0) {
        $totalMemory = [double] (Get-RmoObjectValue $computer 'TotalPhysicalMemory' 0)
    }
    $freeMemory = [double] (Get-RmoObjectValue $os 'FreePhysicalMemory' 0) * 1024

    $sticks = Invoke-RmoCim -ClassName 'Win32_PhysicalMemory' -ErrorSink $ErrorSink
    $modules = foreach ($stick in $sticks) {
        [pscustomobject]@{
            Slot         = [string] (Get-RmoObjectValue $stick 'DeviceLocator' '')
            Bank         = [string] (Get-RmoObjectValue $stick 'BankLabel' '')
            CapacityBytes = [double] (Get-RmoObjectValue $stick 'Capacity' 0)
            SpeedMhz     = [int] (Get-RmoObjectValue $stick 'ConfiguredClockSpeed' (Get-RmoObjectValue $stick 'Speed' 0))
            Manufacturer = [string] (Get-RmoObjectValue $stick 'Manufacturer' '')
            PartNumber   = ([string] (Get-RmoObjectValue $stick 'PartNumber' '')).Trim()
        }
    }
    $arrays = Invoke-RmoCim -ClassName 'Win32_PhysicalMemoryArray' -ErrorSink $ErrorSink
    $totalSlots = 0
    foreach ($array in $arrays) {
        $totalSlots += [int] (Get-RmoObjectValue $array 'MemoryDevices' 0)
    }
    $usedSlots = @($modules).Count

    $memoryPerf = Get-RmoFirstOrDefault (Invoke-RmoCim -ClassName 'Win32_PerfFormattedData_PerfOS_Memory' -ErrorSink $ErrorSink)
    $committedBytes = Get-RmoObjectValue $memoryPerf 'CommittedBytes'
    $commitLimit = Get-RmoObjectValue $memoryPerf 'CommitLimit'
    $availableBytes = Get-RmoObjectValue $memoryPerf 'AvailableBytes'
    if ($null -ne $availableBytes) { $freeMemory = [double] $availableBytes }
    #endregion

    #region Storage - what the disks are, and how full the volumes are
    $mediaTypeNames = @{ 0 = 'Unspecified'; 3 = 'HDD'; 4 = 'SSD'; 5 = 'SCM' }
    $physicalByFriendly = @{}
    foreach ($disk in Invoke-RmoCim -ClassName 'MSFT_PhysicalDisk' -Namespace 'root/Microsoft/Windows/Storage' -ErrorSink $ErrorSink) {
        $friendly = [string] (Get-RmoObjectValue $disk 'FriendlyName' '')
        if (-not $friendly) { continue }
        $mediaCode = [int] (Get-RmoObjectValue $disk 'MediaType' 0)
        $physicalByFriendly[$friendly] = [pscustomobject]@{
            MediaType    = $(if ($mediaTypeNames.ContainsKey($mediaCode)) { $mediaTypeNames[$mediaCode] } else { 'Unspecified' })
            SpindleSpeed = [int] (Get-RmoObjectValue $disk 'SpindleSpeed' 0)
            BusType      = [int] (Get-RmoObjectValue $disk 'BusType' 0)
        }
    }

    $storage = foreach ($drive in Invoke-RmoCim -ClassName 'Win32_DiskDrive' -ErrorSink $ErrorSink) {
        $model = ([string] (Get-RmoObjectValue $drive 'Model' '')).Trim()
        $media = 'Unknown'
        $spindle = 0
        if ($physicalByFriendly.ContainsKey($model)) {
            $media = $physicalByFriendly[$model].MediaType
            $spindle = $physicalByFriendly[$model].SpindleSpeed
        }
        # The Storage namespace is the authority, but it is absent on older servers. The model
        # string is a weaker signal that still separates most SSDs from most spinning disks.
        if ($media -in 'Unknown', 'Unspecified') {
            if ($model -match '(?i)\b(ssd|nvme|solid\s*state)\b') { $media = 'SSD (from model name)' }
            elseif ($model -match '(?i)\b(hdd|st\d{4}|wd\d|barracuda|hgst)\b') { $media = 'HDD (from model name)' }
        }
        $interface = [string] (Get-RmoObjectValue $drive 'InterfaceType' '')
        if ($media -eq 'Unknown' -and $interface -eq 'SCSI' -and $model -match '(?i)nvme') { $media = 'SSD (from model name)' }

        [pscustomobject]@{
            DeviceId     = [string] (Get-RmoObjectValue $drive 'DeviceID' '')
            Model        = $model
            MediaType    = $media
            SpindleSpeed = $spindle
            SizeBytes    = [double] (Get-RmoObjectValue $drive 'Size' 0)
            Interface    = $interface
            Partitions   = [int] (Get-RmoObjectValue $drive 'Partitions' 0)
        }
    }

    $systemDrive = if ($env:SystemDrive) { $env:SystemDrive } else { 'C:' }
    $volumes = foreach ($volume in Invoke-RmoCim -ClassName 'Win32_LogicalDisk' -Filter 'DriveType = 3' -ErrorSink $ErrorSink) {
        $size = [double] (Get-RmoObjectValue $volume 'Size' 0)
        $free = [double] (Get-RmoObjectValue $volume 'FreeSpace' 0)
        $letter = [string] (Get-RmoObjectValue $volume 'DeviceID' '')
        [pscustomobject]@{
            DriveLetter = $letter
            Label       = [string] (Get-RmoObjectValue $volume 'VolumeName' '')
            FileSystem  = [string] (Get-RmoObjectValue $volume 'FileSystem' '')
            SizeBytes   = $size
            FreeBytes   = $free
            FreePercent = $(if ($size -gt 0) { [math]::Round(($free / $size) * 100, 1) } else { $null })
            IsSystem    = ($letter -eq $systemDrive)
        }
    }
    #endregion

    #region Graphics
    $graphics = foreach ($adapter in Invoke-RmoCim -ClassName 'Win32_VideoController' -ErrorSink $ErrorSink) {
        $driverDate = Get-RmoObjectValue $adapter 'DriverDate'
        [pscustomobject]@{
            Name          = [string] (Get-RmoObjectValue $adapter 'Name' '')
            Manufacturer  = [string] (Get-RmoObjectValue $adapter 'AdapterCompatibility' '')
            DriverVersion = [string] (Get-RmoObjectValue $adapter 'DriverVersion' '')
            DriverDate    = $driverDate
            DriverAgeDays = $(if ($null -ne $driverDate) { [math]::Round(([datetime]::Now - $driverDate).TotalDays, 0) } else { $null })
            MemoryBytes   = [double] (Get-RmoObjectValue $adapter 'AdapterRAM' 0)
            Status        = [string] (Get-RmoObjectValue $adapter 'Status' '')
        }
    }
    #endregion

    #region Page file, power plan and registered antivirus
    $pageFiles = foreach ($file in Invoke-RmoCim -ClassName 'Win32_PageFileUsage' -ErrorSink $ErrorSink) {
        [pscustomobject]@{
            Name              = [string] (Get-RmoObjectValue $file 'Name' '')
            AllocatedBytes    = [double] (Get-RmoObjectValue $file 'AllocatedBaseSize' 0) * 1MB
            CurrentUsageBytes = [double] (Get-RmoObjectValue $file 'CurrentUsage' 0) * 1MB
            PeakUsageBytes    = [double] (Get-RmoObjectValue $file 'PeakUsage' 0) * 1MB
        }
    }
    $automaticPageFile = [bool] (Get-RmoObjectValue $computer 'AutomaticManagedPagefile' $true)

    $powerPlanName = 'Unknown'
    $powerPlanGuid = ''
    foreach ($plan in Invoke-RmoCim -ClassName 'Win32_PowerPlan' -Namespace 'root/cimv2/power' -Filter 'IsActive = True' -ErrorSink $ErrorSink) {
        $powerPlanName = [string] (Get-RmoObjectValue $plan 'ElementName' 'Unknown')
        $powerPlanGuid = [string] (Get-RmoObjectValue $plan 'InstanceID' '')
    }

    # SecurityCenter2 is only present on client Windows; on a server the absence is expected
    # and not worth recording as a failure.
    $antivirus = foreach ($product in Invoke-RmoCim -ClassName 'AntiVirusProduct' -Namespace 'root/SecurityCenter2') {
        $state = [int] (Get-RmoObjectValue $product 'productState' 0)
        # The product state is a bit field. Byte 2 carries whether real-time protection is on,
        # byte 3 whether the definitions are current.
        $realTime = (($state -band 0x1000) -ne 0) -or (($state -band 0x0010) -ne 0)
        [pscustomobject]@{
            DisplayName       = [string] (Get-RmoObjectValue $product 'displayName' '')
            ProductState      = $state
            RealTimeEnabled   = $realTime
            DefinitionsCurrent = (($state -band 0x0010) -eq 0)
            ExecutablePath    = [string] (Get-RmoObjectValue $product 'pathToSignedProductExe' '')
        }
    }
    #endregion

    [pscustomobject]@{
        PSTypeName        = 'Rmo.SystemSnapshot'
        ComputerName      = [System.Environment]::MachineName
        Manufacturer      = ([string] (Get-RmoObjectValue $computer 'Manufacturer' '')).Trim()
        Model             = ([string] (Get-RmoObjectValue $computer 'Model' '')).Trim()
        IsLaptop          = $isLaptop
        OnBattery         = $onBattery
        BatteryPercent    = $batteryPercent
        Os                = [pscustomobject]@{
            Caption      = [string] (Get-RmoObjectValue $os 'Caption' '')
            Version      = [string] (Get-RmoObjectValue $os 'Version' '')
            BuildNumber  = [string] (Get-RmoObjectValue $os 'BuildNumber' '')
            Architecture = [string] (Get-RmoObjectValue $os 'OSArchitecture' '')
            InstalledUtc = Get-RmoObjectValue $os 'InstallDate'
            LastBoot     = $lastBoot
            UptimeSeconds = $uptimeSeconds
        }
        Cpu               = [pscustomobject]@{
            Name              = $cpuName
            Manufacturer      = $cpuVendor
            Cores             = $cores
            LogicalProcessors = $logical
            MaxClockMhz       = $maxClock
            CurrentClockMhz   = $currentClock
        }
        Memory            = [pscustomobject]@{
            TotalBytes     = $totalMemory
            AvailableBytes = $freeMemory
            CommittedBytes = $(if ($null -ne $committedBytes) { [double] $committedBytes } else { $null })
            CommitLimit    = $(if ($null -ne $commitLimit) { [double] $commitLimit } else { $null })
            Modules        = @($modules)
            UsedSlots      = $usedSlots
            TotalSlots     = $totalSlots
        }
        Storage           = @($storage)
        Volumes           = @($volumes)
        Graphics          = @($graphics)
        PageFiles         = @($pageFiles)
        AutomaticPageFile = $automaticPageFile
        PowerPlan         = [pscustomobject]@{ Name = $powerPlanName; Guid = $powerPlanGuid }
        Antivirus         = @($antivirus)
    }
}
