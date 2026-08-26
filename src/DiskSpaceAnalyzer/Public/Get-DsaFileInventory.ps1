function Get-DsaFileInventory {
    <#
        .SYNOPSIS
            Walks one or more directory trees and streams a record for every file found.

        .DESCRIPTION
            An iterative (non-recursive) enumerator built for real volumes: it survives
            access-denied folders, keeps going past reparse points instead of following them
            into a loop, handles paths beyond MAX_PATH, and streams results so that a volume
            with millions of files can be aggregated without holding the inventory in memory.

            Two attributes are reported explicitly because they make naive size reports wrong:

              IsOffline  The file is a cloud placeholder (OneDrive / Files On-Demand). It
                         reports its full logical size but occupies almost no disk.
              IsSparse   The file is sparse, so its logical size overstates allocated space.

            Errors encountered during the walk do not stop it. They are surfaced through the
            -ErrorSink parameter so the caller can report coverage honestly.

        .PARAMETER Path
            One or more roots to scan.

        .PARAMETER MinFileSizeBytes
            Skip files below this size. Raising this dramatically speeds up a scan whose only
            purpose is finding reclaimable space.

        .PARAMETER MaxDepth
            Maximum directory depth below each root. 0 means unlimited.

        .PARAMETER ExcludePattern
            Regular expressions tested against each directory path. Matching directories, and
            everything beneath them, are skipped.

        .PARAMETER FollowReparsePoint
            Descend into junctions, symlinks and mount points. Off by default because it double
            counts data and can cycle.

        .PARAMETER ReferenceTime
            The "now" used to compute file ages. Defaults to the current UTC time.

        .PARAMETER ErrorSink
            A list that receives one record per unreadable directory.

        .PARAMETER StatusSink
            A dictionary (use a synchronized one when scanning on a background thread) updated
            with FilesScanned, BytesScanned, DirectoriesScanned, CurrentPath and ErrorCount.

        .PARAMETER CancellationSink
            A dictionary checked periodically; set its 'Cancelled' key to $true to stop the walk.

        .EXAMPLE
            Get-DsaFileInventory -Path C:\ -MinFileSizeBytes 1MB | Measure-DsaInventory
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)]
        [string[]] $Path,

        [long] $MinFileSizeBytes = 0,

        [int] $MaxDepth = 0,

        [string[]] $ExcludePattern,

        [switch] $FollowReparsePoint,

        [datetime] $ReferenceTime = [datetime]::UtcNow,

        [System.Collections.IList] $ErrorSink,

        [System.Collections.IDictionary] $StatusSink,

        [System.Collections.IDictionary] $CancellationSink
    )

    begin {
        $excludeRegexes = @()
        foreach ($pattern in $ExcludePattern) {
            $excludeRegexes += [regex]::new($pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        }

        $offlineFlag = [System.IO.FileAttributes]::Offline
        $sparseFlag  = [System.IO.FileAttributes]::SparseFile
        $reparseFlag = [System.IO.FileAttributes]::ReparsePoint
        # Files On-Demand placeholders that have never been hydrated. These two flags have no
        # entry in the FileAttributes enum, so they are tested as raw bits.
        $recallFlags = 0x00500000   # RECALL_ON_OPEN | RECALL_ON_DATA_ACCESS

        $filesScanned = 0L
        $bytesScanned = 0L
        $dirsScanned = 0L
        $errorCount = 0L

        function Write-DsaScanError {
            param([string] $FailedPath, [string] $Reason)

            # Explicit null test: an empty ArrayList is falsy in PowerShell, so a plain
            # truthiness check would silently drop the first error of every scan.
            if ($null -ne $ErrorSink) {
                $null = $ErrorSink.Add([pscustomobject]@{
                    Path   = ConvertFrom-DsaExtendedPath $FailedPath
                    Reason = $Reason
                })
            }
            Write-Verbose "Skipping '$FailedPath': $Reason"
        }
    }

    process {
        foreach ($root in $Path) {
            if ([string]::IsNullOrWhiteSpace($root)) { continue }

            $resolvedRoot = $root
            try {
                $resolvedRoot = (Resolve-Path -LiteralPath $root -ErrorAction Stop).ProviderPath
            } catch {
                Write-DsaScanError -FailedPath $root -Reason "Path could not be resolved: $($_.Exception.Message)"
                $errorCount++
                continue
            }

            # A file passed directly as a root is reported on its own.
            if (Test-Path -LiteralPath $resolvedRoot -PathType Leaf) {
                $leaf = [System.IO.FileInfo]::new((Get-DsaExtendedPath $resolvedRoot))
                if ($leaf.Length -ge $MinFileSizeBytes) {
                    New-DsaFileRecord -File $leaf -ReferenceTime $ReferenceTime `
                        -OfflineFlag $offlineFlag -SparseFlag $sparseFlag -RecallFlags $recallFlags
                }
                continue
            }

            $rootDepth = (ConvertTo-DsaNormalizedPath $resolvedRoot).TrimEnd('\').Split('\').Count

            $stack = New-Object System.Collections.Generic.Stack[string]
            $stack.Push((Get-DsaExtendedPath $resolvedRoot))

            while ($stack.Count -gt 0) {
                if ($null -ne $CancellationSink -and $CancellationSink['Cancelled']) {
                    Write-Verbose 'Scan cancelled by caller.'
                    break
                }

                $current = $stack.Pop()
                $display = ConvertFrom-DsaExtendedPath $current
                $directoryKey = ConvertTo-DsaDirectoryKey $display

                $skip = $false
                foreach ($regex in $excludeRegexes) {
                    if ($regex.IsMatch($directoryKey)) { $skip = $true; break }
                }
                if ($skip) { continue }

                $dirsScanned++
                if ($null -ne $StatusSink -and ($dirsScanned % 25) -eq 0) {
                    $StatusSink['CurrentPath'] = $display
                    $StatusSink['DirectoriesScanned'] = $dirsScanned
                    $StatusSink['FilesScanned'] = $filesScanned
                    $StatusSink['BytesScanned'] = $bytesScanned
                    $StatusSink['ErrorCount'] = $errorCount
                }

                $info = $null
                try {
                    $info = [System.IO.DirectoryInfo]::new($current)
                } catch {
                    Write-DsaScanError -FailedPath $display -Reason $_.Exception.Message
                    $errorCount++
                    continue
                }

                try {
                    foreach ($file in $info.EnumerateFiles()) {
                        $length = 0L
                        try { $length = $file.Length } catch { $length = 0L }
                        if ($length -lt $MinFileSizeBytes) { continue }

                        $filesScanned++
                        $bytesScanned += $length

                        New-DsaFileRecord -File $file -ReferenceTime $ReferenceTime `
                            -OfflineFlag $offlineFlag -SparseFlag $sparseFlag -RecallFlags $recallFlags `
                            -DirectoryKey $directoryKey
                    }
                } catch {
                    Write-DsaScanError -FailedPath $display -Reason $_.Exception.Message
                    $errorCount++
                }

                if ($MaxDepth -gt 0) {
                    $currentDepth = $directoryKey.TrimEnd('\').Split('\').Count
                    if (($currentDepth - $rootDepth) -ge $MaxDepth) { continue }
                }

                try {
                    foreach ($child in $info.EnumerateDirectories()) {
                        if (-not $FollowReparsePoint -and ($child.Attributes -band $reparseFlag)) {
                            Write-Verbose "Not following reparse point '$($child.FullName)'."
                            continue
                        }
                        $stack.Push($child.FullName)
                    }
                } catch {
                    Write-DsaScanError -FailedPath $display -Reason $_.Exception.Message
                    $errorCount++
                }
            }
        }
    }

    end {
        if ($null -ne $StatusSink) {
            $StatusSink['DirectoriesScanned'] = $dirsScanned
            $StatusSink['FilesScanned'] = $filesScanned
            $StatusSink['BytesScanned'] = $bytesScanned
            $StatusSink['ErrorCount'] = $errorCount
            $StatusSink['Complete'] = $true
        }
    }
}
