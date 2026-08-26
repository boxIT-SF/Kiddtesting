function New-DsaFileRecord {
    <#
        .SYNOPSIS
            Turns a FileInfo into the flat record the aggregator consumes.
        .NOTES
            Timestamps come from the FileInfo cache populated during enumeration, so this adds
            no extra I/O. Age is measured from LastWriteTime; IdleDays uses LastAccessTime,
            which NTFS does not maintain by default and is therefore reported separately rather
            than folded into the age.
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory)] [System.IO.FileInfo] $File,
        [Parameter(Mandatory)] [datetime] $ReferenceTime,
        [Parameter(Mandatory)] [System.IO.FileAttributes] $OfflineFlag,
        [Parameter(Mandatory)] [System.IO.FileAttributes] $SparseFlag,
        [Parameter(Mandatory)] [int] $RecallFlags,
        [string] $DirectoryKey
    )

    $attributes = [System.IO.FileAttributes] 0
    try { $attributes = $File.Attributes } catch { }

    $lastWrite = $File.LastWriteTimeUtc
    $created = $File.CreationTimeUtc
    $lastAccess = $File.LastAccessTimeUtc

    # A timestamp in the future (clock skew, bad archive metadata) would otherwise create
    # negative ages and poison the age histogram.
    $ageDays = [math]::Max(0.0, ($ReferenceTime - $lastWrite).TotalDays)
    $idleDays = [math]::Max(0.0, ($ReferenceTime - $lastAccess).TotalDays)

    $fullName = ConvertFrom-DsaExtendedPath $File.FullName
    if (-not $DirectoryKey) {
        $DirectoryKey = ConvertTo-DsaDirectoryKey ([System.IO.Path]::GetDirectoryName($fullName))
    }

    [pscustomobject]@{
        PSTypeName        = 'Dsa.FileRecord'
        FullName          = $fullName
        DirectoryKey      = $DirectoryKey
        Name              = $File.Name
        Extension         = $File.Extension.ToLowerInvariant()
        Length            = $File.Length
        CreationTimeUtc   = $created
        LastWriteTimeUtc  = $lastWrite
        LastAccessTimeUtc = $lastAccess
        AgeDays           = $ageDays
        IdleDays          = $idleDays
        IsOffline         = [bool] (($attributes -band $OfflineFlag) -or ([int] $attributes -band $RecallFlags))
        IsSparse          = [bool] ($attributes -band $SparseFlag)
    }
}
