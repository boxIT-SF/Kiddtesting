function Get-DsaPreventiveControl {
    <#
        .SYNOPSIS
            Derives the controls that stop the volume filling up again inside the horizon.
        .DESCRIPTION
            A one-off cleanup buys time; it does not buy headroom. Whatever produced the
            reclaimable data is still running, so for each significant class of data found the
            plan proposes the recurring control that keeps it in check. Only controls relevant
            to what was actually found are returned.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [psobject] $Summary,
        [Parameter(Mandatory)] [int] $HorizonMonths,
        [long] $SignificanceBytes = 512MB
    )

    $found = @{}
    foreach ($category in $Summary.Categories) {
        if ($category.Bytes -ge $SignificanceBytes) { $found[$category.Id] = $category }
    }

    $controls = New-Object System.Collections.Generic.List[psobject]

    function Add-Control {
        param([string] $Trigger, [string] $Name, [string] $Detail, [string] $Command = '')
        $controls.Add([pscustomobject]@{
            PSTypeName = 'Dsa.PreventiveControl'
            Trigger    = $Trigger
            Name       = $Name
            Detail     = $Detail
            Command    = $Command
        })
    }

    if ($found.ContainsKey('temp-windows') -or $found.ContainsKey('temp-user') -or $found.ContainsKey('temp-extensions')) {
        Add-Control -Trigger 'Temp files' -Name 'Scheduled temp cleanup' `
            -Detail 'Run a monthly job that deletes files under the Windows and per-user temp directories older than seven days. Storage Sense does this natively on Windows 10/11; on servers use a scheduled task.' `
            -Command 'Enable Storage Sense (Intune/GPO), or a monthly scheduled task running the temp cleanup command from this report.'
    }
    if ($found.ContainsKey('win-update-cache') -or $found.ContainsKey('win-delivery-optimization')) {
        Add-Control -Trigger 'Update caches' -Name 'Cap update and Delivery Optimization caches' `
            -Detail 'Set the Delivery Optimization maximum cache size and age so the peer cache cannot grow without limit, and clear SoftwareDistribution after any failed update run.' `
            -Command 'Policy: Delivery Optimization > Max Cache Size (percent) and Max Cache Age.'
    }
    if ($found.ContainsKey('log-generic') -or $found.ContainsKey('srv-iis-logs') -or $found.ContainsKey('log-archived-evtx')) {
        Add-Control -Trigger 'Log growth' -Name 'Log rotation and retention' `
            -Detail 'Give every log-producing application a size or age ceiling, and schedule a trim for the ones that cannot rotate themselves. Agree the retention period with whoever owns the compliance requirement before automating deletion.' `
            -Command 'IIS: enable log file rolling and a scheduled trim. Event logs: wevtutil sl <log> /ms:<bytes>.'
    }
    if ($found.ContainsKey('user-downloads') -or $found.ContainsKey('user-archives') -or $found.ContainsKey('user-installers')) {
        Add-Control -Trigger 'User downloads' -Name 'Storage Sense policy for Downloads' `
            -Detail 'Publish a retention expectation and enforce it: delete files in Downloads not opened for 60 days. Announce it before enabling so nobody is surprised.' `
            -Command 'Intune/GPO: Storage Sense > Delete files in my Downloads folder if they have not been opened for more than 60 days.'
    }
    if ($found.ContainsKey('sync-onedrive')) {
        Add-Control -Trigger 'Cloud sync' -Name 'Files On-Demand' `
            -Detail 'Turn on OneDrive Files On-Demand so synced content stays in the cloud until it is opened. This is usually the largest low-risk reclaim on a user workstation and it is self-maintaining afterwards.' `
            -Command 'Intune/GPO: "Use OneDrive Files On-Demand" and "Silently move Windows known folders to OneDrive".'
    }
    if ($found.ContainsKey('sys-vss')) {
        Add-Control -Trigger 'Shadow copies' -Name 'Cap shadow copy storage' `
            -Detail 'Set an explicit ceiling on shadow copy storage per volume so restore points cannot consume the free space you just recovered.' `
            -Command 'vssadmin resize shadowstorage /for=<vol> /on=<vol> /maxsize=<size>'
    }
    if ($found.ContainsKey('srv-sql-data') -or $found.ContainsKey('srv-sql-backup')) {
        Add-Control -Trigger 'SQL Server' -Name 'Backup and log retention' `
            -Detail 'Confirm log backups run for every database in FULL recovery, and that backup retention actually prunes. An unbounded transaction log or an unpruned backup folder will refill the volume within weeks.' `
            -Command 'Maintenance plan or Ola Hallengren: DatabaseBackup with @CleanupTime, plus a log backup schedule.'
    }
    if ($found.ContainsKey('srv-hyperv')) {
        Add-Control -Trigger 'Virtualisation' -Name 'Checkpoint hygiene' `
            -Detail 'Alert on any VM checkpoint older than a few days. A forgotten checkpoint grows continuously and is one of the fastest ways to fill a host volume.' `
            -Command 'Get-VMSnapshot -VMName * | Where-Object CreationTime -lt (Get-Date).AddDays(-7)'
    }
    if ($found.ContainsKey('user-stale-profile')) {
        Add-Control -Trigger 'User profiles' -Name 'Stale profile removal' `
            -Detail 'Enable the built-in policy that deletes profiles older than a set number of days, so departed users do not accumulate.' `
            -Command 'GPO: Computer Configuration > Policies > System > User Profiles > Delete user profiles older than a specified number of days.'
    }

    Add-Control -Trigger 'Always' -Name 'Free space monitoring' `
        -Detail "Alert when free space drops back to the operating reserve rather than when the volume is nearly full. That gives a working window instead of an outage, and it is how you find out early if the growth estimate behind this $HorizonMonths-month plan was wrong." `
        -Command 'Add a disk free space check at the reserve threshold in your RMM or monitoring platform.'

    Add-Control -Trigger 'Always' -Name 'Re-scan on a schedule' `
        -Detail "Re-run this analysis monthly and compare the growth figure. Two or three real data points beat any single-scan estimate, and they turn the $HorizonMonths-month projection into a measured trend." `
        -Command 'Schedule tools\Invoke-DiskSpaceAnalyzer.ps1 -Report <share>\$env:COMPUTERNAME.html'

    $controls.ToArray()
}
