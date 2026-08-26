function Get-DsaVolumeInfo {
    <#
        .SYNOPSIS
            Returns capacity and free space for the volume that hosts a path.

        .DESCRIPTION
            Uses System.IO.DriveInfo, which works on every supported Windows build without
            admin rights, and enriches it with the volume label, file system and drive type
            from CIM when that is available.

        .PARAMETER Path
            A path, drive root or drive letter. Defaults to the system drive.

        .EXAMPLE
            Get-DsaVolumeInfo -Path 'C:\Users'
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Position = 0, ValueFromPipeline)]
        [string] $Path
    )

    process {
        if ([string]::IsNullOrWhiteSpace($Path)) {
            $Path = if ((Test-DsaWindows) -and $env:SystemDrive) { "$env:SystemDrive\" } else { '/' }
        }

        $full = $Path
        try {
            $full = [System.IO.Path]::GetFullPath($Path)
        } catch {
            Write-Verbose "Could not expand '$Path': $($_.Exception.Message)"
        }

        $root = [System.IO.Path]::GetPathRoot($full)
        if ([string]::IsNullOrEmpty($root)) { $root = $full }

        $drive = $null
        try {
            $drive = [System.IO.DriveInfo]::new($root)
        } catch {
            # UNC paths have no DriveInfo. Report what we can rather than failing the scan.
            return [pscustomobject]@{
                PSTypeName      = 'Dsa.VolumeInfo'
                Path            = $full
                Root            = $root
                Name            = $root
                Label           = ''
                FileSystem      = ''
                DriveType       = 'Network or unknown'
                CapacityBytes   = $null
                FreeBytes       = $null
                UsedBytes       = $null
                PercentFree     = $null
                PercentUsed     = $null
                CapacityText    = 'n/a'
                FreeText        = 'n/a'
                UsedText        = 'n/a'
                IsReady         = $false
                Note            = "Capacity is not available for '$root'. Size figures come from the scan only."
            }
        }

        $capacity = $null; $free = $null; $used = $null; $label = ''; $fileSystem = ''; $driveType = ''
        $ready = $false
        try {
            $ready = $drive.IsReady
            if ($ready) {
                $capacity = [long] $drive.TotalSize
                $free = [long] $drive.AvailableFreeSpace
                $used = $capacity - $free
                $label = [string] $drive.VolumeLabel
                $fileSystem = [string] $drive.DriveFormat
            }
            $driveType = [string] $drive.DriveType
        } catch {
            Write-Verbose "DriveInfo for '$root' is incomplete: $($_.Exception.Message)"
        }

        [pscustomobject]@{
            PSTypeName    = 'Dsa.VolumeInfo'
            Path          = $full
            Root          = $root
            Name          = $drive.Name
            Label         = $label
            FileSystem    = $fileSystem
            DriveType     = $driveType
            CapacityBytes = $capacity
            FreeBytes     = $free
            UsedBytes     = $used
            PercentFree   = if ($capacity) { [math]::Round(100 * $free / $capacity, 1) } else { $null }
            PercentUsed   = if ($capacity) { [math]::Round(100 * $used / $capacity, 1) } else { $null }
            CapacityText  = Format-DsaBytes $capacity
            FreeText      = Format-DsaBytes $free
            UsedText      = Format-DsaBytes $used
            IsReady       = $ready
            Note          = ''
        }
    }
}
