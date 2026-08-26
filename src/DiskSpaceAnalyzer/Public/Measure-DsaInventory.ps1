function Measure-DsaInventory {
    <#
        .SYNOPSIS
            Aggregates a stream of file records into the analysis the report and the plan are
            built from.

        .DESCRIPTION
            Consumes the output of Get-DsaFileInventory from the pipeline and builds, in a
            single pass and in bounded memory:

              * totals, including a separate figure for cloud placeholders and sparse files
                whose logical size overstates the space they actually occupy;
              * an age histogram, and the oldest data on the volume;
              * a per-classification breakdown answering what the data is, whether it is safe
                to delete, and what to do about it if it is not;
              * the directories the space is actually going to;
              * a monthly series of file creation used to estimate how fast the volume is
                filling up.

        .PARAMETER InputObject
            File records, normally piped from Get-DsaFileInventory.

        .PARAMETER Classifier
            Classification context. Defaults to the shipped rule set.

        .PARAMETER TopCount
            How many entries to keep in each "largest" table.

        .PARAMETER OldestCount
            How many entries to keep in the oldest-data table.

        .PARAMETER OldestMinSizeBytes
            Minimum size for a file to appear in the oldest-data table. Without this the table
            fills with ancient but trivially small files and says nothing about space.

        .PARAMETER RootPath
            The scan roots, used to roll directories up to a useful level.

        .PARAMETER DirectoryDepth
            How many segments below each root to roll directories up to.

        .PARAMETER ReferenceTime
            The "now" used for age maths. Must match the value given to Get-DsaFileInventory.

        .EXAMPLE
            Get-DsaFileInventory -Path D:\ | Measure-DsaInventory -RootPath D:\
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(ValueFromPipeline)]
        [psobject] $InputObject,

        [psobject] $Classifier,

        [int] $TopCount = 25,

        [int] $OldestCount = 25,

        [long] $OldestMinSizeBytes = 1MB,

        [string[]] $RootPath = @(),

        [int] $DirectoryDepth = 2,

        [datetime] $ReferenceTime = [datetime]::UtcNow
    )

    begin {
        if (-not $Classifier) { $Classifier = New-DsaClassifier }

        $rootKeys = @($RootPath | ForEach-Object { ConvertTo-DsaDirectoryKey $_ })

        $fileCount = 0L
        $totalBytes = 0L
        $offlineBytes = 0L
        $offlineCount = 0L
        $sparseBytes = 0L
        $sparseCount = 0L

        $oldestWrite = [datetime]::MaxValue
        $newestWrite = [datetime]::MinValue

        $buckets = Get-DsaAgeBucketDefinition
        $bucketBytes = New-Object 'long[]' $buckets.Count
        $bucketCounts = New-Object 'long[]' $buckets.Count

        $categories = @{}
        $directories = @{}
        $extensions = @{}
        $createdByMonth = @{}
        $rollupCache = @{}

        $largest = New-Object System.Collections.ArrayList
        $oldest = New-Object System.Collections.ArrayList
    }

    process {
        if ($null -eq $InputObject) { return }

        $length = [long] $InputObject.Length
        $fileCount++
        $totalBytes += $length

        if ($InputObject.IsOffline) { $offlineCount++; $offlineBytes += $length }
        if ($InputObject.IsSparse)  { $sparseCount++;  $sparseBytes  += $length }

        $lastWrite = $InputObject.LastWriteTimeUtc
        if ($lastWrite -lt $oldestWrite) { $oldestWrite = $lastWrite }
        if ($lastWrite -gt $newestWrite) { $newestWrite = $lastWrite }

        $ageDays = [double] $InputObject.AgeDays
        $bucketIndex = Get-DsaAgeBucketIndex $ageDays
        $bucketBytes[$bucketIndex] += $length
        $bucketCounts[$bucketIndex]++

        $rule = Resolve-DsaFileCategory -Classifier $Classifier `
            -FileName $InputObject.Name -DirectoryKey $InputObject.DirectoryKey -Extension $InputObject.Extension

        $entry = $categories[$rule.Id]
        if ($null -eq $entry) {
            $entry = @{
                Rule              = $rule
                FileCount         = 0L
                Bytes             = 0L
                EligibleFileCount = 0L
                EligibleBytes     = 0L
                OfflineBytes      = 0L
                OldestUtc         = [datetime]::MaxValue
                NewestUtc         = [datetime]::MinValue
                Examples          = New-Object System.Collections.ArrayList
            }
            $categories[$rule.Id] = $entry
        }
        $entry['FileCount']++
        $entry['Bytes'] += $length
        if ($InputObject.IsOffline) { $entry['OfflineBytes'] += $length }
        if ($lastWrite -lt $entry['OldestUtc']) { $entry['OldestUtc'] = $lastWrite }
        if ($lastWrite -gt $entry['NewestUtc']) { $entry['NewestUtc'] = $lastWrite }

        # A file only counts toward reclaimable space once it is older than the rule's
        # threshold, and never if it is a placeholder that occupies no local space anyway.
        if ($ageDays -ge $rule.EligibleAfterDays -and -not $InputObject.IsOffline) {
            $entry['EligibleFileCount']++
            $entry['EligibleBytes'] += $length
        }

        Add-DsaBoundedItem -List $entry['Examples'] -SortProperty 'Length' -Keep 3 -Descending -Item ([pscustomobject]@{
            FullName = $InputObject.FullName
            Length   = $length
            AgeDays  = $ageDays
        })

        $rollupKey = $rollupCache[$InputObject.DirectoryKey]
        if ($null -eq $rollupKey) {
            $rollupKey = Get-DsaRollupKey $InputObject.DirectoryKey $rootKeys $DirectoryDepth
            $rollupCache[$InputObject.DirectoryKey] = $rollupKey
        }
        $dirEntry = $directories[$rollupKey]
        if ($null -eq $dirEntry) {
            $dirEntry = @{ Bytes = 0L; FileCount = 0L; OldestUtc = [datetime]::MaxValue }
            $directories[$rollupKey] = $dirEntry
        }
        $dirEntry['Bytes'] += $length
        $dirEntry['FileCount']++
        if ($lastWrite -lt $dirEntry['OldestUtc']) { $dirEntry['OldestUtc'] = $lastWrite }

        $ext = $InputObject.Extension
        if ([string]::IsNullOrEmpty($ext)) { $ext = '(none)' }
        $extEntry = $extensions[$ext]
        if ($null -eq $extEntry) {
            $extEntry = @{ Bytes = 0L; FileCount = 0L }
            $extensions[$ext] = $extEntry
        }
        $extEntry['Bytes'] += $length
        $extEntry['FileCount']++

        $monthKey = $InputObject.CreationTimeUtc.ToString('yyyy-MM')
        $monthEntry = $createdByMonth[$monthKey]
        if ($null -eq $monthEntry) {
            $monthEntry = @{ Bytes = 0L; FileCount = 0L }
            $createdByMonth[$monthKey] = $monthEntry
        }
        $monthEntry['Bytes'] += $length
        $monthEntry['FileCount']++

        Add-DsaBoundedItem -List $largest -SortProperty 'Length' -Keep $TopCount -Descending -Item ([pscustomobject]@{
            FullName     = $InputObject.FullName
            Length       = $length
            SizeText     = Format-DsaBytes $length
            LastWriteUtc = $lastWrite
            AgeDays      = [math]::Round($ageDays, 0)
            Category     = $rule.Name
            Safety       = $rule.Safety
            IsOffline    = $InputObject.IsOffline
        })

        if ($length -ge $OldestMinSizeBytes) {
            Add-DsaBoundedItem -List $oldest -SortProperty 'AgeDays' -Keep $OldestCount -Descending -Item ([pscustomobject]@{
                FullName     = $InputObject.FullName
                Length       = $length
                SizeText     = Format-DsaBytes $length
                LastWriteUtc = $lastWrite
                AgeDays      = [math]::Round($ageDays, 0)
                IdleDays     = [math]::Round([double] $InputObject.IdleDays, 0)
                Category     = $rule.Name
                Safety       = $rule.Safety
                WhatItIs     = $rule.Description
                SafeToDelete = $rule.Safety -eq 'Safe'
            })
        }
    }

    end {
        $onDiskBytes = $totalBytes - $offlineBytes

        $categoryRows = foreach ($key in $categories.Keys) {
            $entry = $categories[$key]
            $rule = $entry['Rule']
            [pscustomobject]@{
                PSTypeName        = 'Dsa.CategorySummary'
                Id                = $rule.Id
                Name              = $rule.Name
                Category          = $rule.Category
                Safety            = $rule.Safety
                SafetyRank        = $rule.SafetyRank
                Method            = $rule.Method
                WhatItIs          = $rule.Description
                Reason            = $rule.Reason
                Remediation       = $rule.Remediation
                Command           = $rule.Command
                RequiresReboot    = $rule.RequiresReboot
                EligibleAfterDays = $rule.EligibleAfterDays
                FileCount         = $entry['FileCount']
                Bytes             = $entry['Bytes']
                SizeText          = Format-DsaBytes $entry['Bytes']
                EligibleFileCount = $entry['EligibleFileCount']
                EligibleBytes     = $entry['EligibleBytes']
                EligibleSizeText  = Format-DsaBytes $entry['EligibleBytes']
                OfflineBytes      = $entry['OfflineBytes']
                OldestUtc         = if ($entry['OldestUtc'] -eq [datetime]::MaxValue) { $null } else { $entry['OldestUtc'] }
                NewestUtc         = if ($entry['NewestUtc'] -eq [datetime]::MinValue) { $null } else { $entry['NewestUtc'] }
                OldestAgeDays     = if ($entry['OldestUtc'] -eq [datetime]::MaxValue) { $null } else { [math]::Round(($ReferenceTime - $entry['OldestUtc']).TotalDays, 0) }
                PercentOfScan     = if ($totalBytes -gt 0) { [math]::Round(100 * $entry['Bytes'] / $totalBytes, 2) } else { 0 }
                Examples          = Get-DsaBoundedResult -List $entry['Examples'] -SortProperty 'Length' -Keep 3 -Descending
            }
        }
        $categoryRows = @($categoryRows | Sort-Object -Property @{ Expression = 'Bytes'; Descending = $true })

        $bucketRows = foreach ($bucket in $buckets) {
            [pscustomobject]@{
                PSTypeName    = 'Dsa.AgeBucket'
                Order         = $bucket.Order
                Name          = $bucket.Name
                FileCount     = $bucketCounts[$bucket.Order]
                Bytes         = $bucketBytes[$bucket.Order]
                SizeText      = Format-DsaBytes $bucketBytes[$bucket.Order]
                PercentOfScan = if ($totalBytes -gt 0) { [math]::Round(100 * $bucketBytes[$bucket.Order] / $totalBytes, 2) } else { 0 }
            }
        }

        $directoryRows = foreach ($key in $directories.Keys) {
            $entry = $directories[$key]
            [pscustomobject]@{
                PSTypeName    = 'Dsa.DirectorySummary'
                Path          = $key
                Bytes         = $entry['Bytes']
                SizeText      = Format-DsaBytes $entry['Bytes']
                FileCount     = $entry['FileCount']
                OldestUtc     = $entry['OldestUtc']
                PercentOfScan = if ($totalBytes -gt 0) { [math]::Round(100 * $entry['Bytes'] / $totalBytes, 2) } else { 0 }
            }
        }
        $directoryRows = @($directoryRows | Sort-Object -Property @{ Expression = 'Bytes'; Descending = $true } |
            Select-Object -First $TopCount)

        $extensionRows = foreach ($key in $extensions.Keys) {
            [pscustomobject]@{
                PSTypeName = 'Dsa.ExtensionSummary'
                Extension  = $key
                Bytes      = $extensions[$key]['Bytes']
                SizeText   = Format-DsaBytes $extensions[$key]['Bytes']
                FileCount  = $extensions[$key]['FileCount']
            }
        }
        $extensionRows = @($extensionRows | Sort-Object -Property @{ Expression = 'Bytes'; Descending = $true } |
            Select-Object -First $TopCount)

        $monthRows = foreach ($key in $createdByMonth.Keys) {
            [pscustomobject]@{
                PSTypeName = 'Dsa.MonthSummary'
                Month      = $key
                Bytes      = $createdByMonth[$key]['Bytes']
                SizeText   = Format-DsaBytes $createdByMonth[$key]['Bytes']
                FileCount  = $createdByMonth[$key]['FileCount']
            }
        }
        $monthRows = @($monthRows | Sort-Object Month)

        $safetyRows = foreach ($level in 'Safe', 'Review', 'Unsafe') {
            $subset = @($categoryRows | Where-Object { $_.Safety -eq $level })
            # Summed by hand: Measure-Object emits nothing at all for empty input, which
            # would make a property access on the result fail under Set-StrictMode.
            $bytes = 0L
            $eligible = 0L
            foreach ($row in $subset) {
                $bytes += $row.Bytes
                $eligible += $row.EligibleBytes
            }
            [pscustomobject]@{
                PSTypeName       = 'Dsa.SafetySummary'
                Safety           = $level
                Bytes            = [long] $bytes
                SizeText         = Format-DsaBytes $bytes
                EligibleBytes    = [long] $eligible
                EligibleSizeText = Format-DsaBytes $eligible
                CategoryCount    = $subset.Count
            }
        }

        [pscustomobject]@{
            PSTypeName        = 'Dsa.InventorySummary'
            ReferenceTime     = $ReferenceTime
            RootPath          = $RootPath
            FileCount         = $fileCount
            TotalBytes        = $totalBytes
            TotalSizeText     = Format-DsaBytes $totalBytes
            OnDiskBytes       = $onDiskBytes
            OnDiskSizeText    = Format-DsaBytes $onDiskBytes
            OfflineBytes      = $offlineBytes
            OfflineFileCount  = $offlineCount
            SparseBytes       = $sparseBytes
            SparseFileCount   = $sparseCount
            OldestWriteUtc    = if ($oldestWrite -eq [datetime]::MaxValue) { $null } else { $oldestWrite }
            NewestWriteUtc    = if ($newestWrite -eq [datetime]::MinValue) { $null } else { $newestWrite }
            OldestAgeDays     = if ($oldestWrite -eq [datetime]::MaxValue) { $null } else { [math]::Round(($ReferenceTime - $oldestWrite).TotalDays, 0) }
            AgeBuckets        = $bucketRows
            Categories        = $categoryRows
            SafetySummary     = $safetyRows
            TopDirectories    = $directoryRows
            LargestFiles      = Get-DsaBoundedResult -List $largest -SortProperty 'Length' -Keep $TopCount -Descending
            OldestFiles       = Get-DsaBoundedResult -List $oldest -SortProperty 'AgeDays' -Keep $OldestCount -Descending
            TopExtensions     = $extensionRows
            CreatedByMonth    = $monthRows
        }
    }
}
