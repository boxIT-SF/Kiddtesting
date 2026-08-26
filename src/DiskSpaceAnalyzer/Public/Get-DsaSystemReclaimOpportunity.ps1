function Get-DsaSystemReclaimOpportunity {
    <#
        .SYNOPSIS
            Finds space that a file-level scan cannot see or cannot act on.

        .DESCRIPTION
            Some of the biggest wins on a Windows volume are invisible to (or unusable from) a
            directory walk: the hibernation file and page file cannot be enumerated while in
            use, shadow copy storage is not addressable as files, the component store's real
            footprint is hidden behind hard links, and a stale user profile has to be removed
            through the profile API rather than by deleting a folder.

            Every probe degrades quietly. A missing tool, a lack of elevation or a slow
            response produces an opportunity marked as unavailable with the reason attached,
            never an error that ends the analysis.

        .PARAMETER Path
            The volume being analysed. Defaults to the system drive.

        .PARAMETER Deep
            Also run DISM component store analysis. It is accurate but slow (often a minute or
            more) and needs elevation, so it is off by default.

        .PARAMETER StaleProfileDays
            Age at which a user profile is reported as possibly abandoned.

        .EXAMPLE
            Get-DsaSystemReclaimOpportunity -Path C:\ -Deep
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [string] $Path,
        [switch] $Deep,
        [int] $StaleProfileDays = 180
    )

    $results = New-Object System.Collections.Generic.List[psobject]

    function New-DsaOpportunity {
        param(
            [string] $Id,
            [string] $Name,
            [string] $Category,
            [ValidateSet('Safe', 'Review', 'Unsafe')] [string] $Safety,
            [System.Nullable[long]] $SizeBytes,
            [string] $WhatItIs,
            [string] $Reason,
            [string] $Remediation,
            [string] $Command,
            [string] $Method = 'Tool',
            [switch] $RequiresReboot,
            [switch] $RequiresElevation,
            [string] $Confidence = 'Medium',
            [string] $Unavailable = ''
        )

        [pscustomobject]@{
            PSTypeName        = 'Dsa.ReclaimOpportunity'
            Id                = $Id
            Name              = $Name
            Category          = $Category
            Safety            = $Safety
            SafetyRank        = Get-DsaSafetyRank $Safety
            SizeBytes         = $SizeBytes
            SizeText          = Format-DsaBytes $SizeBytes
            WhatItIs          = $WhatItIs
            Reason            = $Reason
            Remediation       = $Remediation
            Command           = $Command
            Method            = $Method
            RequiresReboot    = [bool] $RequiresReboot
            RequiresElevation = [bool] $RequiresElevation
            Confidence        = $Confidence
            Available         = [string]::IsNullOrEmpty($Unavailable)
            Unavailable       = $Unavailable
            Source            = 'System'
        }
    }

    if (-not (Test-DsaWindows)) {
        Write-Verbose 'System reclaim probes are Windows-specific; skipping.'
        return @()
    }

    if ([string]::IsNullOrWhiteSpace($Path)) { $Path = "$env:SystemDrive\" }
    $volumeRoot = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($Path))
    $driveLetter = $volumeRoot.TrimEnd('\')
    $elevated = Test-DsaElevated

    #region Hibernation file
    $hiberPath = Join-Path $volumeRoot 'hiberfil.sys'
    $hiberSize = $null
    try {
        $hiberInfo = [System.IO.FileInfo]::new($hiberPath)
        if ($hiberInfo.Exists) { $hiberSize = [long] $hiberInfo.Length }
    } catch {
        Write-Verbose "Could not stat hiberfil.sys: $($_.Exception.Message)"
    }
    if ($hiberSize) {
        $results.Add((New-DsaOpportunity -Id 'sys-hiberfil' -Name 'Hibernation file' -Category 'System reserved' `
            -Safety 'Review' -SizeBytes $hiberSize -Confidence 'High' -RequiresElevation `
            -WhatItIs 'hiberfil.sys - the reserved RAM image for hibernate and Fast Startup, sized from installed memory.' `
            -Reason 'Turning hibernation off reclaims the whole file immediately and permanently. The cost is losing hibernate and Fast Startup.' `
            -Remediation 'On a server or a desktop that is never hibernated, disable it. On a laptop, shrink it to 40 percent instead of removing it.' `
            -Command 'powercfg /hibernate off' -Method 'Policy'))
    }
    #endregion

    #region Page file
    try {
        $pageFiles = @(Get-CimInstance -ClassName Win32_PageFileUsage -ErrorAction Stop)
        foreach ($pageFile in $pageFiles) {
            if ($pageFile.Name -notlike "$driveLetter*") { continue }
            $allocated = [long] $pageFile.AllocatedBaseSize * 1MB
            $results.Add((New-DsaOpportunity -Id 'sys-pagefile' -Name 'Page file allocation' -Category 'System reserved' `
                -Safety 'Unsafe' -SizeBytes $allocated -Confidence 'High' -RequiresElevation -RequiresReboot `
                -WhatItIs "$($pageFile.Name) - virtual memory backing store, currently allocated $(Format-DsaBytes $allocated)." `
                -Reason 'The page file cannot be deleted, and removing it destabilises the machine and disables kernel crash dumps.' `
                -Remediation 'If the volume is genuinely tight, cap it at a fixed size or move it to another volume, keeping enough for the configured crash dump type. Requires a reboot.' `
                -Command 'SystemPropertiesAdvanced.exe   # Performance > Advanced > Virtual memory' -Method 'Policy'))
        }
    } catch {
        $results.Add((New-DsaOpportunity -Id 'sys-pagefile' -Name 'Page file allocation' -Category 'System reserved' `
            -Safety 'Unsafe' -SizeBytes $null -WhatItIs 'Virtual memory backing store.' `
            -Reason '' -Remediation '' -Command '' `
            -Unavailable "Could not query Win32_PageFileUsage: $($_.Exception.Message)"))
    }
    #endregion

    #region Shadow copy storage
    $vss = Invoke-DsaNativeCommand -FilePath 'vssadmin.exe' -ArgumentList @('list', 'shadowstorage') -TimeoutSeconds 60
    if ($vss.Succeeded) {
        $used = $null
        $allocated = $null
        $maximum = $null
        foreach ($line in $vss.Output) {
            if ($line -match 'Used Shadow Copy Storage space:\s*(?<size>.+)$')      { $used = ConvertFrom-DsaSizeText $Matches['size'] }
            elseif ($line -match 'Allocated Shadow Copy Storage space:\s*(?<size>.+)$') { $allocated = ConvertFrom-DsaSizeText $Matches['size'] }
            elseif ($line -match 'Maximum Shadow Copy Storage space:\s*(?<size>.+)$')   { $maximum = ConvertFrom-DsaSizeText $Matches['size'] }
        }
        if ($null -ne $allocated -or $null -ne $used) {
            $reclaimable = if ($null -ne $allocated) { $allocated } else { $used }
            $results.Add((New-DsaOpportunity -Id 'sys-vss-storage' -Name 'Shadow copy storage' -Category 'Shadow copies' `
                -Safety 'Review' -SizeBytes $reclaimable -Confidence 'High' -RequiresElevation `
                -WhatItIs "Volume Shadow Copy allocation backing System Restore and Previous Versions. Used $(Format-DsaBytes $used), allocated $(Format-DsaBytes $allocated), ceiling $(Format-DsaBytes $maximum)." `
                -Reason 'The underlying files are not deletable directly, but capping the allocation releases the oldest shadow copies immediately.' `
                -Remediation 'Confirm with whoever owns backup and recovery first: lowering the ceiling discards restore points and Previous Versions history, and some backup products depend on them.' `
                -Command "vssadmin resize shadowstorage /for=$driveLetter /on=$driveLetter /maxsize=25GB" -Method 'Tool'))
        }
    } else {
        $reasonText = if ($elevated) { $vss.Error } else { 'Requires an elevated session.' }
        $results.Add((New-DsaOpportunity -Id 'sys-vss-storage' -Name 'Shadow copy storage' -Category 'Shadow copies' `
            -Safety 'Review' -SizeBytes $null -WhatItIs 'Volume Shadow Copy allocation.' -Reason '' `
            -Remediation 'Re-run elevated to size this.' -Command 'vssadmin list shadowstorage' `
            -Unavailable "vssadmin could not be queried: $reasonText"))
    }
    #endregion

    #region Component store
    if ($Deep) {
        $dism = Invoke-DsaNativeCommand -FilePath 'Dism.exe' `
            -ArgumentList @('/Online', '/Cleanup-Image', '/AnalyzeComponentStore') -TimeoutSeconds 600
        if ($dism.Succeeded) {
            $actual = $null
            $backups = $null
            $recommended = $false
            foreach ($line in $dism.Output) {
                if ($line -match 'Actual Size of Component Store\s*:\s*(?<size>.+)$')          { $actual = ConvertFrom-DsaSizeText $Matches['size'] }
                elseif ($line -match 'Backups and Disabled Features\s*:\s*(?<size>.+)$')       { $backups = ConvertFrom-DsaSizeText $Matches['size'] }
                elseif ($line -match 'Component Store Cleanup Recommended\s*:\s*Yes')          { $recommended = $true }
            }
            $results.Add((New-DsaOpportunity -Id 'win-winsxs-cleanup' -Name 'Component store cleanup' -Category 'Windows servicing' `
                -Safety 'Review' -SizeBytes $backups -Confidence 'Medium' -RequiresElevation `
                -WhatItIs "WinSxS actual size $(Format-DsaBytes $actual), of which superseded backups and disabled features account for $(Format-DsaBytes $backups)." `
                -Reason ("DISM reports cleanup as " + $(if ($recommended) { 'recommended' } else { 'not currently needed' }) + ". Only the superseded payloads are removed; nothing in use is touched.") `
                -Remediation 'Run StartComponentCleanup. Add /ResetBase only once the current patch level is known good, because it removes the ability to uninstall installed updates.' `
                -Command 'Dism.exe /Online /Cleanup-Image /StartComponentCleanup' -Method 'Tool'))
        } else {
            $reasonText = if ($elevated) { $dism.Error } else { 'Requires an elevated session.' }
            $results.Add((New-DsaOpportunity -Id 'win-winsxs-cleanup' -Name 'Component store cleanup' -Category 'Windows servicing' `
                -Safety 'Review' -SizeBytes $null -WhatItIs 'Superseded servicing payloads in WinSxS.' -Reason '' `
                -Remediation 'Re-run elevated to size this.' -Command 'Dism.exe /Online /Cleanup-Image /AnalyzeComponentStore' `
                -Unavailable "DISM analysis could not be run: $reasonText"))
        }
    }
    #endregion

    #region Stale user profiles
    try {
        $cutoff = (Get-Date).AddDays(-$StaleProfileDays)
        $stale = @(Get-CimInstance -ClassName Win32_UserProfile -ErrorAction Stop |
            Where-Object { -not $_.Special -and $_.LocalPath -like "$driveLetter*" -and $_.LastUseTime -and $_.LastUseTime -lt $cutoff })

        if ($stale.Count -gt 0) {
            $list = ($stale | Sort-Object LastUseTime | Select-Object -First 10 |
                ForEach-Object { "$($_.LocalPath) (last used $($_.LastUseTime.ToString('yyyy-MM-dd')))" }) -join '; '
            $results.Add((New-DsaOpportunity -Id 'user-stale-profile' -Name 'Stale user profiles' -Category 'User profiles' `
                -Safety 'Review' -SizeBytes $null -Confidence 'Medium' -RequiresElevation `
                -WhatItIs "$($stale.Count) profile(s) on $driveLetter not used in $StaleProfileDays days: $list" `
                -Reason 'Profiles of departed staff and one-off logins are frequently the largest reclaimable block on a shared machine. Sizes are in the directory breakdown of this report.' `
                -Remediation 'Confirm each account is genuinely inactive in the directory, capture anything unique, then remove through the profile API so the registry entry goes with it. Deleting the folder alone leaves a broken profile behind.' `
                -Command 'Get-CimInstance Win32_UserProfile | Where-Object { -not $_.Special -and $_.LastUseTime -lt (Get-Date).AddDays(-180) } | Remove-CimInstance' `
                -Method 'Tool'))
        }
    } catch {
        Write-Verbose "Could not enumerate user profiles: $($_.Exception.Message)"
    }
    #endregion

    $results.ToArray()
}
