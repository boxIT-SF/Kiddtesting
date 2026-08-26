<#
.SYNOPSIS
    Runs the DiskSpaceAnalyzer test suite.

.DESCRIPTION
    No external dependencies. Creates its own fixture tree under the temp directory, exercises
    the module against it, and cleans up afterwards. Exits with the number of failures, so it
    can gate a build.

.EXAMPLE
    pwsh -File .\tests\Invoke-Tests.ps1
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
    $ModulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'src/DiskSpaceAnalyzer/DiskSpaceAnalyzer.psd1'
}
Import-Module $ModulePath -Force

# Private functions are reached through the module's own scope rather than being re-dot-sourced,
# so the tests exercise exactly the code the module runs.
$module = Get-Module DiskSpaceAnalyzer
function Use-Private { param([string] $Name, [object[]] $Arguments = @())
    & $module { param($n, $a) & $n @a } $Name $Arguments
}

#region Fixture
$fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("dsa-tests-" + [guid]::NewGuid().ToString('N').Substring(0, 8))

function New-FixtureFile {
    param([string] $RelativePath, [long] $Size, [double] $AgeDays, [double] $CreatedDaysAgo = -1)

    $full = Join-Path $fixtureRoot $RelativePath
    $directory = Split-Path $full -Parent
    if (-not (Test-Path -LiteralPath $directory)) { $null = New-Item -ItemType Directory -Path $directory -Force }

    $stream = [System.IO.File]::Create($full)
    try { $stream.SetLength($Size) } finally { $stream.Dispose() }

    $item = Get-Item -LiteralPath $full
    $now = [datetime]::UtcNow
    $item.LastWriteTimeUtc = $now.AddDays(-$AgeDays)
    $item.LastAccessTimeUtc = $now.AddDays(-$AgeDays)
    if ($CreatedDaysAgo -lt 0) { $CreatedDaysAgo = $AgeDays }
    $item.CreationTimeUtc = $now.AddDays(-$CreatedDaysAgo)
    $full
}

function New-Fixture {
    if (Test-Path -LiteralPath $fixtureRoot) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
    $null = New-Item -ItemType Directory -Path $fixtureRoot -Force

    $null = New-FixtureFile 'Windows/SoftwareDistribution/Download/update.cab' (3GB) 45
    $null = New-FixtureFile 'Windows/Temp/old.tmp'                             (500MB) 60
    $null = New-FixtureFile 'Windows/Temp/fresh.tmp'                           (200MB) 1
    $null = New-FixtureFile 'Users/jo/Downloads/big.iso'                       (4GB) 400
    $null = New-FixtureFile 'Users/jo/Documents/report.docx'                   (30MB) 1000
    $null = New-FixtureFile 'SQLData/app.ldf'                                  (20GB) 2
    $null = New-FixtureFile 'Deep/one/two/three/buried.dat'                    (10MB) 5
    foreach ($month in 1..12) {
        $null = New-FixtureFile "Business/export-$month.dat" (1GB) ($month * 30) ($month * 30)
    }
}

function New-Record {
    <#
        A hand-made file record, so aggregation behaviour that depends on file system
        attributes we cannot set on every platform (cloud placeholders, sparse files) is still
        covered.
    #>
    param(
        [string] $FullName,
        [long] $Length,
        [double] $AgeDays,
        [string] $DirectoryKey,
        [switch] $Offline,
        [switch] $Sparse,
        [datetime] $Reference = [datetime]::UtcNow
    )

    if (-not $DirectoryKey) { $DirectoryKey = ($FullName -replace '[^\\]+$', '') }
    [pscustomobject]@{
        FullName          = $FullName
        DirectoryKey      = $DirectoryKey
        Name              = ($FullName -split '\\')[-1]
        Extension         = [System.IO.Path]::GetExtension($FullName).ToLowerInvariant()
        Length            = $Length
        CreationTimeUtc   = $Reference.AddDays(-$AgeDays)
        LastWriteTimeUtc  = $Reference.AddDays(-$AgeDays)
        LastAccessTimeUtc = $Reference.AddDays(-$AgeDays)
        AgeDays           = $AgeDays
        IdleDays          = $AgeDays
        IsOffline         = [bool] $Offline
        IsSparse          = [bool] $Sparse
    }
}

New-Fixture
#endregion

try {

Describe-Suite 'Byte and path helpers' {
    Test-Case 'formats bytes with sensible units' {
        Assert-Equal '0 B'     (Use-Private 'Format-DsaBytes' @(0))
        Assert-Equal '1,023 B' (Use-Private 'Format-DsaBytes' @(1023))
        Assert-Equal '1.5 KB'  (Use-Private 'Format-DsaBytes' @(1536))
        Assert-Equal '12.0 GB' (Use-Private 'Format-DsaBytes' @(12GB))
        Assert-Equal '1.0 TB'  (Use-Private 'Format-DsaBytes' @(1TB))
    }
    Test-Case 'formats null as n/a and keeps the sign on negatives' {
        Assert-Equal 'n/a'      (Use-Private 'Format-DsaBytes' @($null))
        Assert-Equal '-1.0 GB'  (Use-Private 'Format-DsaBytes' @(-1GB))
    }
    Test-Case 'normalises directory keys' {
        Assert-Equal 'C:\Windows\Temp\' (Use-Private 'ConvertTo-DsaDirectoryKey' @('C:/Windows/Temp'))
        Assert-Equal 'C:\Windows\Temp\' (Use-Private 'ConvertTo-DsaDirectoryKey' @('C:\Windows\Temp\'))
        Assert-Equal '\'                (Use-Private 'ConvertTo-DsaDirectoryKey' @(''))
    }
    Test-Case 'places ages in the right band at the boundaries' {
        Assert-Equal 0 (Use-Private 'Get-DsaAgeBucketIndex' @(29.9))
        Assert-Equal 1 (Use-Private 'Get-DsaAgeBucketIndex' @(30))
        Assert-Equal 3 (Use-Private 'Get-DsaAgeBucketIndex' @(364.9))
        Assert-Equal 5 (Use-Private 'Get-DsaAgeBucketIndex' @(1824))
        Assert-Equal 6 (Use-Private 'Get-DsaAgeBucketIndex' @(1825))
    }
    Test-Case 'parses the size strings vssadmin and DISM emit' {
        Assert-Equal 13260711526 (Use-Private 'ConvertFrom-DsaSizeText' @('Used Shadow Copy Storage space: 12.35 GB (4%)'))
        Assert-Equal 8589934592  (Use-Private 'ConvertFrom-DsaSizeText' @('Actual Size of Component Store : 8,192.00 MB'))
        Assert-Equal $null       (Use-Private 'ConvertFrom-DsaSizeText' @('UNBOUNDED'))
        Assert-Equal $null       (Use-Private 'ConvertFrom-DsaSizeText' @(''))
    }
    Test-Case 'rolls directories up to the requested depth' {
        Assert-Equal 'C:\Users\jo\'    (Use-Private 'Get-DsaRollupKey' @('C:\Users\jo\AppData\Local\Temp\', @('C:\'), 2))
        Assert-Equal 'C:\'             (Use-Private 'Get-DsaRollupKey' @('C:\', @('C:\'), 2))
        Assert-Equal 'D:\Data\Deep\'   (Use-Private 'Get-DsaRollupKey' @('D:\Data\Deep\Deeper\', @('D:\Data\'), 1))
    }
    Test-Case 'falls back to leading segments when no root matches' {
        Assert-Equal 'E:\Some\Where\' (Use-Private 'Get-DsaRollupKey' @('E:\Some\Where\Else\', @('Z:\'), 2))
    }
    Test-Case 'word-wraps text to the requested width' {
        $lines = @(Use-Private 'Split-DsaTextBlock' @(('word ' * 60), 60, 0, 0))
        Assert-True ($lines.Count -gt 1) 'expected the text to wrap onto several lines'
        foreach ($line in $lines) { Assert-True ($line.Length -le 62) "line was $($line.Length) characters" }
    }
}

Describe-Suite 'Classification rule set' {
    $rules = Get-DsaClassificationRule

    Test-Case 'loads and compiles every shipped rule' {
        Assert-True ($rules.Count -gt 40) "only $($rules.Count) rules loaded"
    }
    Test-Case 'rule ids and priorities are unique' {
        $duplicateIds = @($rules | Group-Object Id | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
        Assert-Equal 0 $duplicateIds.Count "duplicate ids: $($duplicateIds -join ', ')"
        $duplicatePriorities = @($rules | Group-Object Priority | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
        Assert-Equal 0 $duplicatePriorities.Count "duplicate priorities: $($duplicatePriorities -join ', ')"
    }
    Test-Case 'every rule declares a valid safety level and a description' {
        foreach ($rule in $rules) {
            Assert-True ($rule.Safety -in 'Safe', 'Review', 'Unsafe') "$($rule.Id) has safety '$($rule.Safety)'"
            Assert-True (-not [string]::IsNullOrWhiteSpace($rule.Description)) "$($rule.Id) has no Description"
            Assert-True (-not [string]::IsNullOrWhiteSpace($rule.Reason)) "$($rule.Id) has no Reason"
        }
    }
    Test-Case 'every Unsafe rule says what to do instead' {
        # This is the whole promise of the tool: if it is not safe to delete, there is an
        # alternative. A rule without one would leave a technician stuck.
        foreach ($rule in ($rules | Where-Object { $_.Safety -eq 'Unsafe' })) {
            Assert-True (-not [string]::IsNullOrWhiteSpace($rule.Remediation)) "$($rule.Id) is Unsafe with no Remediation"
        }
    }
    Test-Case 'every Review rule says what decision is needed' {
        foreach ($rule in ($rules | Where-Object { $_.Safety -eq 'Review' -and $_.Id -ne 'unclassified' })) {
            Assert-True (-not [string]::IsNullOrWhiteSpace($rule.Remediation)) "$($rule.Id) is Review with no Remediation"
        }
    }
    Test-Case 'a rule file overlay replaces a shipped rule by id' {
        $overlay = Join-Path $fixtureRoot 'overlay.psd1'
        Set-Content -LiteralPath $overlay -Encoding UTF8 -Value @'
@{
    Rules = @(
        @{
            Id = 'temp-windows'; Name = 'Site override'; Category = 'Custom'; Safety = 'Review'
            Priority = 40; PathPattern = '\\Windows\\Temp\\'
            Description = 'Overridden.'; Reason = 'Site policy.'; Remediation = 'Ask the site owner.'
        }
        @{
            Id = 'site-app'; Name = 'Line of business app data'; Category = 'Custom'; Safety = 'Unsafe'
            Priority = 5; PathPattern = '\\LobApp\\'
            Description = 'Business data.'; Reason = 'Not reproducible.'; Remediation = 'Archive to the file server.'
        }
    )
}
'@
        $merged = Get-DsaClassificationRule -Path $overlay -Force
        $overridden = $merged | Where-Object { $_.Id -eq 'temp-windows' }
        Assert-Equal 'Site override' $overridden.Name
        Assert-Equal 'Review' $overridden.Safety
        Assert-True ([bool]($merged | Where-Object { $_.Id -eq 'site-app' })) 'the added rule is missing'

        # Reload the shipped set so later suites are unaffected.
        $null = Get-DsaClassificationRule -Force
    }
    Test-Case 'a rule with an invalid safety level is rejected' {
        $bad = Join-Path $fixtureRoot 'bad.psd1'
        Set-Content -LiteralPath $bad -Encoding UTF8 -Value @'
@{ Rules = @(@{ Id = 'x'; Name = 'x'; Category = 'x'; Safety = 'Maybe'; Priority = 1 }) }
'@
        Assert-Throws { Get-DsaClassificationRule -Path $bad -Force } 'invalid Safety'
        $null = Get-DsaClassificationRule -Force
    }
}

Describe-Suite 'Classifying a file' {
    $classifier = New-DsaClassifier

    $expectations = @(
        @{ Name = 'pagefile.sys';  Directory = 'C:\';                                                                   Id = 'sys-pagefile' }
        @{ Name = 'hiberfil.sys';  Directory = 'C:\';                                                                   Id = 'sys-hiberfil' }
        @{ Name = 'a.cab';         Directory = 'C:\Windows\SoftwareDistribution\Download\';                             Id = 'win-update-cache' }
        @{ Name = 'a.tmp';         Directory = 'C:\Windows\Temp\';                                                      Id = 'temp-windows' }
        @{ Name = 'a.dat';         Directory = 'C:\Users\jo\AppData\Local\Temp\';                                       Id = 'temp-user' }
        @{ Name = 'f_000001';      Directory = 'C:\Users\jo\AppData\Local\Google\Chrome\User Data\Default\Cache\';       Id = 'cache-chromium' }
        @{ Name = 'mail.ost';      Directory = 'C:\Users\jo\AppData\Local\Microsoft\Outlook\';                           Id = 'mail-ost' }
        @{ Name = 'mail.pst';      Directory = 'C:\Users\jo\Documents\';                                                 Id = 'mail-pst' }
        @{ Name = 'app.ldf';       Directory = 'D:\SQLData\';                                                            Id = 'srv-sql-data' }
        @{ Name = 'db.bak';        Directory = 'E:\Backup\';                                                             Id = 'srv-sql-backup' }
        @{ Name = 'vm.avhdx';      Directory = 'D:\HyperV\';                                                             Id = 'srv-hyperv' }
        @{ Name = 'u_ex.log';      Directory = 'C:\inetpub\logs\LogFiles\W3SVC1\';                                       Id = 'srv-iis-logs' }
        @{ Name = 'Security.evtx'; Directory = 'C:\Windows\System32\winevt\Logs\';                                       Id = 'log-eventlog' }
        @{ Name = 'setup.iso';     Directory = 'C:\Users\jo\Downloads\';                                                 Id = 'user-downloads' }
        @{ Name = 'holiday.mp4';   Directory = 'D:\Media\';                                                              Id = 'user-media' }
        @{ Name = 'notes.txt';     Directory = 'C:\Users\jo\Documents\';                                                 Id = 'user-documents' }
        @{ Name = 'thing.dat';     Directory = 'D:\SomeApp\';                                                            Id = 'unclassified' }
        @{ Name = 'Windows.edb';   Directory = 'C:\ProgramData\Microsoft\Search\Data\Applications\Windows\';             Id = 'sys-searchindex' }
        @{ Name = 'file.bin';      Directory = 'C:\$Recycle.Bin\S-1-5-21-1\';                                            Id = 'sys-recyclebin' }
        @{ Name = 'x.dll';         Directory = 'C:\Windows\WinSxS\amd64_something\';                                     Id = 'win-winsxs' }
    )

    foreach ($expectation in $expectations) {
        $case = $expectation
        Test-Case "classifies $($case.Name) under $($case.Directory) as $($case.Id)" {
            $rule = Resolve-DsaFileCategory -Classifier $classifier -FileName $case.Name -DirectoryKey $case.Directory
            Assert-Equal $case.Id $rule.Id
        }.GetNewClosure()
    }

    Test-Case 'a rule needing both a path and an extension requires both' {
        # cache-container matches only a .vhdx under the container paths.
        $inPath = Resolve-DsaFileCategory -Classifier $classifier -FileName 'ext4.vhdx' `
            -DirectoryKey 'C:\Users\jo\AppData\Local\Packages\CanonicalGroup\LocalState\'
        Assert-Equal 'cache-container' $inPath.Id

        $wrongExtension = Resolve-DsaFileCategory -Classifier $classifier -FileName 'notes.txt' `
            -DirectoryKey 'C:\Users\jo\AppData\Local\Packages\CanonicalGroup\LocalState\'
        Assert-True ($wrongExtension.Id -ne 'cache-container') 'a .txt should not match the container rule'
    }

    Test-Case 'the directory cache does not change the answer' {
        $fresh = New-DsaClassifier
        $first = Resolve-DsaFileCategory -Classifier $fresh -FileName 'a.tmp' -DirectoryKey 'C:\Windows\Temp\'
        $second = Resolve-DsaFileCategory -Classifier $fresh -FileName 'b.log' -DirectoryKey 'C:\Windows\Temp\'
        $third = Resolve-DsaFileCategory -Classifier $fresh -FileName 'a.tmp' -DirectoryKey 'C:\Windows\Temp\'
        Assert-Equal 'temp-windows' $first.Id
        Assert-Equal 'temp-windows' $second.Id
        Assert-Equal $first.Id $third.Id
    }
}

Describe-Suite 'Scanning the file system' {
    Test-Case 'finds every file under the root' {
        $files = @(Get-DsaFileInventory -Path $fixtureRoot)
        $expected = @(Get-ChildItem -LiteralPath $fixtureRoot -Recurse -File).Count
        Assert-Equal $expected $files.Count
    }
    Test-Case 'honours the minimum size filter' {
        $files = @(Get-DsaFileInventory -Path $fixtureRoot -MinFileSizeBytes 1GB)
        Assert-True ($files.Count -gt 0) 'expected at least one large file'
        foreach ($file in $files) { Assert-True ($file.Length -ge 1GB) "$($file.FullName) is below the filter" }
    }
    Test-Case 'honours the depth limit' {
        $shallow = @(Get-DsaFileInventory -Path $fixtureRoot -MaxDepth 1)
        $deep = @(Get-DsaFileInventory -Path $fixtureRoot)
        Assert-True ($shallow.Count -lt $deep.Count) 'a depth limit should return fewer files'
        Assert-False ([bool]($shallow | Where-Object { $_.Name -eq 'buried.dat' })) 'the deeply nested file leaked through'
    }
    Test-Case 'honours exclusions' {
        $files = @(Get-DsaFileInventory -Path $fixtureRoot -ExcludePattern '\\Windows\\')
        Assert-False ([bool]($files | Where-Object { $_.DirectoryKey -match '\\Windows\\' })) 'an excluded folder was scanned'
    }
    Test-Case 'reports an unreadable root without throwing' {
        $errors = New-Object System.Collections.ArrayList
        $files = @(Get-DsaFileInventory -Path (Join-Path $fixtureRoot 'no-such-folder') -ErrorSink $errors)
        Assert-Equal 0 $files.Count
        Assert-Equal 1 $errors.Count
        Assert-Match $errors[0].Reason 'could not be resolved'
    }
    Test-Case 'publishes progress to the status sink' {
        $status = @{}
        $null = Get-DsaFileInventory -Path $fixtureRoot -StatusSink $status
        Assert-True ($status['FilesScanned'] -gt 0) 'no file count was published'
        Assert-True ($status['BytesScanned'] -gt 0) 'no byte count was published'
        Assert-True ([bool] $status['Complete']) 'the scan did not report completion'
    }
    Test-Case 'stops when the caller cancels' {
        $cancel = @{ Cancelled = $true }
        $files = @(Get-DsaFileInventory -Path $fixtureRoot -CancellationSink $cancel)
        Assert-Equal 0 $files.Count
    }
    Test-Case 'derives age from the last write time' {
        $files = @(Get-DsaFileInventory -Path $fixtureRoot)
        $iso = $files | Where-Object { $_.Name -eq 'big.iso' }
        Assert-Near 400 $iso.AgeDays 1 'the fixture sets this file to 400 days old'
    }
    Test-Case 'clamps a future timestamp to zero rather than a negative age' {
        $future = New-FixtureFile 'Odd/future.dat' 1024 -5
        try {
            $record = @(Get-DsaFileInventory -Path (Split-Path $future -Parent))[0]
            Assert-Equal 0 $record.AgeDays
        } finally {
            Remove-Item -LiteralPath $future -Force
        }
    }
}

Describe-Suite 'Aggregating the inventory' {
    $summary = Get-DsaFileInventory -Path $fixtureRoot | Measure-DsaInventory -RootPath $fixtureRoot -OldestMinSizeBytes 0

    Test-Case 'totals match the sum of file lengths' {
        $expected = 0L
        foreach ($file in (Get-ChildItem -LiteralPath $fixtureRoot -Recurse -File)) { $expected += $file.Length }
        Assert-Equal $expected $summary.TotalBytes
    }
    Test-Case 'the age histogram accounts for every byte' {
        $bucketed = 0L
        foreach ($bucket in $summary.AgeBuckets) { $bucketed += $bucket.Bytes }
        Assert-Equal $summary.TotalBytes $bucketed
    }
    Test-Case 'classifications account for every byte' {
        $classified = 0L
        foreach ($category in $summary.Categories) { $classified += $category.Bytes }
        Assert-Equal $summary.TotalBytes $classified
    }
    Test-Case 'a file younger than its rule threshold is classified but not reclaimable' {
        $temp = $summary.Categories | Where-Object { $_.Id -eq 'temp-windows' }
        # The fixture has a 500 MB file at 60 days and a 200 MB file at 1 day; the rule's
        # threshold is 7 days, so only the older one may be counted as reclaimable.
        Assert-Equal (700MB) $temp.Bytes
        Assert-Equal (500MB) $temp.EligibleBytes
    }
    Test-Case 'the oldest table is sorted oldest first' {
        $ages = @($summary.OldestFiles | ForEach-Object { $_.AgeDays })
        for ($i = 1; $i -lt $ages.Count; $i++) {
            Assert-True ($ages[$i - 1] -ge $ages[$i]) 'the oldest table is out of order'
        }
        Assert-Equal 'report.docx' (Split-Path $summary.OldestFiles[0].FullName -Leaf)
    }
    Test-Case 'the oldest table respects its minimum size' {
        $filtered = Get-DsaFileInventory -Path $fixtureRoot | Measure-DsaInventory -RootPath $fixtureRoot -OldestMinSizeBytes 1GB
        foreach ($file in $filtered.OldestFiles) { Assert-True ($file.Length -ge 1GB) "$($file.FullName) is under the floor" }
    }
    Test-Case 'cloud placeholders are counted separately and never as reclaimable' {
        $records = @(
            New-Record -FullName 'C:\Windows\Temp\a.tmp' -Length 100MB -AgeDays 100
            New-Record -FullName 'C:\Windows\Temp\b.tmp' -Length 400MB -AgeDays 100 -Offline
        )
        $result = $records | Measure-DsaInventory -RootPath 'C:\'
        Assert-Equal (500MB) $result.TotalBytes
        Assert-Equal (400MB) $result.OfflineBytes
        Assert-Equal (100MB) $result.OnDiskBytes
        $temp = $result.Categories | Where-Object { $_.Id -eq 'temp-windows' }
        Assert-Equal (100MB) $temp.EligibleBytes "a placeholder occupies no disk, so freeing it frees nothing"
    }
    Test-Case 'sparse files are flagged' {
        $result = @(New-Record -FullName 'D:\d\x.dat' -Length 1GB -AgeDays 5 -Sparse) | Measure-DsaInventory
        Assert-Equal 1 $result.SparseFileCount
        Assert-Equal (1GB) $result.SparseBytes
    }
    Test-Case 'creation months are keyed as yyyy-MM' {
        foreach ($month in $summary.CreatedByMonth) { Assert-Match $month.Month '^\d{4}-\d{2}$' }
    }
    Test-Case 'safety totals agree with the classification totals' {
        $safetyTotal = 0L
        foreach ($row in $summary.SafetySummary) { $safetyTotal += $row.Bytes }
        Assert-Equal $summary.TotalBytes $safetyTotal
    }
}

Describe-Suite 'Estimating growth' {
    Test-Case 'uses the median of complete months and ignores the partial current one' {
        $reference = [datetime]::new(2026, 6, 15, 0, 0, 0, [System.DateTimeKind]::Utc)
        $summary = [pscustomobject]@{
            ReferenceTime  = $reference
            TotalBytes     = 100GB
            OldestAgeDays  = 400
            CreatedByMonth = @(
                [pscustomobject]@{ Month = '2026-01'; Bytes = 1GB;   FileCount = 1 }
                [pscustomobject]@{ Month = '2026-02'; Bytes = 2GB;   FileCount = 1 }
                [pscustomobject]@{ Month = '2026-03'; Bytes = 3GB;   FileCount = 1 }
                [pscustomobject]@{ Month = '2026-04'; Bytes = 4GB;   FileCount = 1 }
                [pscustomobject]@{ Month = '2026-05'; Bytes = 5GB;   FileCount = 1 }
                [pscustomobject]@{ Month = '2026-06'; Bytes = 500GB; FileCount = 1 }
            )
        }
        $growth = Measure-DsaGrowthRate -Summary $summary
        Assert-Equal 5 $growth.SampleMonths 'the current month must be excluded'
        Assert-Equal (3GB) $growth.BytesPerMonth
        Assert-Equal (5GB) $growth.PeakBytes
    }
    Test-Case 'flags a lumpy series in the caveats' {
        $reference = [datetime]::new(2026, 6, 15, 0, 0, 0, [System.DateTimeKind]::Utc)
        $summary = [pscustomobject]@{
            ReferenceTime  = $reference
            TotalBytes     = 100GB
            OldestAgeDays  = 400
            CreatedByMonth = @(
                [pscustomobject]@{ Month = '2026-01'; Bytes = 1GB;  FileCount = 1 }
                [pscustomobject]@{ Month = '2026-02'; Bytes = 1GB;  FileCount = 1 }
                [pscustomobject]@{ Month = '2026-03'; Bytes = 1GB;  FileCount = 1 }
                [pscustomobject]@{ Month = '2026-04'; Bytes = 90GB; FileCount = 1 }
            )
        }
        $growth = Measure-DsaGrowthRate -Summary $summary
        Assert-Match ($growth.Caveats -join ' ') 'uneven'
    }
    Test-Case 'falls back to a whole-scan average with too little history' {
        $reference = [datetime]::UtcNow
        $summary = [pscustomobject]@{
            ReferenceTime  = $reference
            TotalBytes     = 12GB
            OldestAgeDays  = 365
            CreatedByMonth = @([pscustomobject]@{ Month = '1999-01'; Bytes = 12GB; FileCount = 1 })
        }
        $growth = Measure-DsaGrowthRate -Summary $summary
        Assert-Equal 'Low' $growth.Confidence
        Assert-Match $growth.Method 'Whole-scan average'
        Assert-Near 1.0 ($growth.BytesPerMonth / 1GB) 0.05 '12 GB over 12 months is about 1 GB a month'
    }
    Test-Case 'a supplied rate overrides the estimate' {
        $summary = [pscustomobject]@{
            ReferenceTime = [datetime]::UtcNow; TotalBytes = 1GB; OldestAgeDays = 30; CreatedByMonth = @()
        }
        $growth = Measure-DsaGrowthRate -Summary $summary -KnownBytesPerMonth 7GB
        Assert-Equal (7GB) $growth.BytesPerMonth
        Assert-Equal 'High' $growth.Confidence
    }
}

Describe-Suite 'Building the six-month plan' {
    function New-PlanInput {
        param([long] $Free = 20GB, [long] $Capacity = 500GB, [double] $GrowthPerMonth = 4GB, [object[]] $Categories)

        $volume = [pscustomobject]@{
            Root = 'C:\'; CapacityBytes = $Capacity; FreeBytes = $Free; UsedBytes = ($Capacity - $Free)
            PercentUsed = [math]::Round(100 * ($Capacity - $Free) / $Capacity, 1)
            PercentFree = [math]::Round(100 * $Free / $Capacity, 1)
            CapacityText = (Use-Private 'Format-DsaBytes' @($Capacity))
            FreeText = (Use-Private 'Format-DsaBytes' @($Free))
            UsedText = (Use-Private 'Format-DsaBytes' @($Capacity - $Free))
        }
        $growth = [pscustomobject]@{
            BytesPerMonth = $GrowthPerMonth; Confidence = 'High'; Method = 'test'; Caveats = @()
        }
        $summary = [pscustomobject]@{
            ReferenceTime = [datetime]::UtcNow
            FileCount = 100; TotalBytes = 400GB; OfflineBytes = 0; OfflineFileCount = 0
            TotalSizeText = '400.0 GB'; OldestAgeDays = 900
            Categories = $Categories
        }
        [pscustomobject]@{ Volume = $volume; Growth = $growth; Summary = $summary }
    }

    function New-Category {
        param([string] $Id, [string] $Safety, [long] $Bytes, [long] $Eligible = -1, [string] $Name = '')

        if ($Eligible -lt 0) { $Eligible = $Bytes }
        if (-not $Name) { $Name = $Id }
        [pscustomobject]@{
            Id = $Id; Name = $Name; Category = 'test'; Safety = $Safety
            SafetyRank = (Use-Private 'Get-DsaSafetyRank' @($Safety))
            Method = 'Delete'; WhatItIs = 'test data'; Reason = 'because'; Remediation = 'do the thing'
            Command = ''; RequiresReboot = $false; EligibleAfterDays = 0
            FileCount = 10; Bytes = $Bytes; SizeText = (Use-Private 'Format-DsaBytes' @($Bytes))
            EligibleFileCount = 10; EligibleBytes = $Eligible
            EligibleSizeText = (Use-Private 'Format-DsaBytes' @($Eligible))
            OfflineBytes = 0; OldestUtc = $null; NewestUtc = $null; OldestAgeDays = 100
            PercentOfScan = 1; Examples = @()
        }
    }

    Test-Case 'the target is projected growth plus the operating reserve' {
        $input = New-PlanInput -Free 20GB -Capacity 500GB -GrowthPerMonth 4GB -Categories @()
        $plan = New-DsaSpacePlan -Summary $input.Summary -Volume $input.Volume -Growth $input.Growth `
            -HorizonMonths 6 -SafetyFactor 1.25 -MinimumFreePercent 15 -MinimumFreeBytes 10GB

        # 4 GB x 6 months x 1.25 = 30 GB of growth; reserve is 15% of 500 GB = 75 GB.
        Assert-Equal (30GB) $plan.ProjectedGrowthBytes
        Assert-Equal (75GB) $plan.ReserveBytes
        Assert-Equal (105GB) $plan.TargetFreeBytes
        Assert-Equal (85GB) $plan.DeficitBytes
    }
    Test-Case 'the reserve floor cannot swamp a small volume' {
        $input = New-PlanInput -Free 5GB -Capacity 30GB -GrowthPerMonth 100MB -Categories @()
        $plan = New-DsaSpacePlan -Summary $input.Summary -Volume $input.Volume -Growth $input.Growth `
            -MinimumFreePercent 15 -MinimumFreeBytes 10GB -MaximumReservePercent 25

        # The 10 GB floor is a third of a 30 GB volume, so the 25 percent cap pulls it back.
        Assert-Equal (7.5GB) $plan.ReserveBytes
        Assert-Match ($plan.Assumptions -join ' ') 'capped at'
    }
    Test-Case 'Unsafe data is never counted toward the target' {
        $categories = @(
            New-Category -Id 'srv-sql-data' -Safety 'Unsafe' -Bytes 200GB
            New-Category -Id 'temp-windows' -Safety 'Safe' -Bytes 5GB
        )
        $input = New-PlanInput -Free 10GB -Capacity 500GB -GrowthPerMonth 1GB -Categories $categories
        $plan = New-DsaSpacePlan -Summary $input.Summary -Volume $input.Volume -Growth $input.Growth

        Assert-Equal (5GB) $plan.ReclaimableSafeBytes
        Assert-False ([bool]($plan.AllCandidates | Where-Object { $_.Safety -eq 'Unsafe' })) 'Unsafe data became a candidate'
        Assert-True ([bool]($plan.Escalations | Where-Object { $_.Id -eq 'srv-sql-data' })) 'Unsafe data was not escalated'
        Assert-False $plan.Achievable 'the target cannot be met, so this must not claim otherwise'
        Assert-True ($plan.ShortfallBytes -gt 0) 'a shortfall should be reported'
    }
    Test-Case 'selection stops once the deficit is covered' {
        $categories = @(
            New-Category -Id 'temp-windows' -Safety 'Safe' -Bytes 50GB
            New-Category -Id 'temp-user' -Safety 'Safe' -Bytes 40GB
            New-Category -Id 'user-downloads' -Safety 'Review' -Bytes 100GB
        )
        $input = New-PlanInput -Free 60GB -Capacity 500GB -GrowthPerMonth 1GB -Categories $categories
        $plan = New-DsaSpacePlan -Summary $input.Summary -Volume $input.Volume -Growth $input.Growth

        # Target is 75 GB reserve + 7.5 GB growth = 82.5 GB, so 22.5 GB is missing and the
        # first Safe item alone covers it.
        Assert-Equal 1 $plan.Actions.Count
        Assert-Equal 'temp-windows' $plan.Actions[0].Id
        Assert-True $plan.Achievable
        Assert-True $plan.AchievableWithSafeOnly
    }
    Test-Case 'identified data is proposed before unidentified data' {
        $categories = @(
            New-Category -Id 'unclassified' -Safety 'Review' -Bytes 400GB
            New-Category -Id 'user-downloads' -Safety 'Review' -Bytes 50GB
        )
        $input = New-PlanInput -Free 10GB -Capacity 500GB -GrowthPerMonth 1GB -Categories $categories
        $plan = New-DsaSpacePlan -Summary $input.Summary -Volume $input.Volume -Growth $input.Growth

        Assert-Equal 'user-downloads' $plan.AllCandidates[0].Id 'unidentified data must not be the first thing proposed'
    }
    Test-Case 'a healthy volume still gets the safe housekeeping' {
        $categories = @(New-Category -Id 'temp-windows' -Safety 'Safe' -Bytes 5GB)
        $input = New-PlanInput -Free 300GB -Capacity 500GB -GrowthPerMonth 1GB -Categories $categories
        $plan = New-DsaSpacePlan -Summary $input.Summary -Volume $input.Volume -Growth $input.Growth

        Assert-Equal 0 $plan.DeficitBytes
        Assert-Equal 1 $plan.Actions.Count
        Assert-Match ($plan.Recommendation -join ' ') 'no cleanup is strictly required'
    }
    Test-Case 'a system probe takes precedence over the scan for the same thing' {
        $categories = @(New-Category -Id 'sys-hiberfil' -Safety 'Review' -Bytes 1GB)
        $probe = [pscustomobject]@{
            Id = 'sys-hiberfil'; Name = 'Hibernation file'; Category = 'System reserved'; Safety = 'Review'
            SafetyRank = 1; SizeBytes = 13GB; SizeText = '13.0 GB'; WhatItIs = 'probe'; Reason = 'probe'
            Remediation = 'powercfg'; Command = 'powercfg /hibernate off'; Method = 'Policy'
            RequiresReboot = $false; RequiresElevation = $true; Confidence = 'High'
            Available = $true; Unavailable = ''; Source = 'System'
        }
        $input = New-PlanInput -Free 10GB -Capacity 500GB -GrowthPerMonth 1GB -Categories $categories
        $plan = New-DsaSpacePlan -Summary $input.Summary -Volume $input.Volume -Growth $input.Growth -SystemOpportunity @($probe)

        $matches = @($plan.AllCandidates | Where-Object { $_.Id -eq 'sys-hiberfil' })
        Assert-Equal 1 $matches.Count 'the same item must not appear twice'
        Assert-Equal (13GB) $matches[0].SizeBytes 'the probe measurement should win'
    }
    Test-Case 'preventive controls are proposed for what was actually found' {
        $categories = @(New-Category -Id 'sync-onedrive' -Safety 'Review' -Bytes 20GB)
        $input = New-PlanInput -Categories $categories
        $plan = New-DsaSpacePlan -Summary $input.Summary -Volume $input.Volume -Growth $input.Growth

        $names = @($plan.PreventiveControls | ForEach-Object { $_.Name })
        Assert-True ($names -contains 'Files On-Demand') 'OneDrive data should suggest Files On-Demand'
        Assert-True ($names -contains 'Free space monitoring') 'monitoring should always be proposed'
        Assert-False ($names -contains 'Checkpoint hygiene') 'no virtual disks were found, so this is noise'
    }
}

Describe-Suite 'Deletion guards' {
    Test-Case 'refuses to delete data classified Unsafe' {
        Assert-Throws { Remove-DsaClassifiedFile -RuleId 'srv-sql-data' -Path $fixtureRoot -Confirm:$false } 'classified Unsafe'
    }
    Test-Case 'refuses data classified Review without an explicit override' {
        Assert-Throws { Remove-DsaClassifiedFile -RuleId 'user-downloads' -Path $fixtureRoot -Confirm:$false } 'classified Review'
    }
    Test-Case 'refuses an unknown rule id' {
        Assert-Throws { Remove-DsaClassifiedFile -RuleId 'not-a-rule' -Path $fixtureRoot -Confirm:$false } 'No classification rule'
    }
    Test-Case 'refuses to lower a rule age threshold' {
        Assert-Throws { Remove-DsaClassifiedFile -RuleId 'temp-windows' -Path $fixtureRoot -MinAgeDays 1 -Confirm:$false } 'below the rule'
    }
    Test-Case 'WhatIf deletes nothing' {
        $before = @(Get-ChildItem -LiteralPath $fixtureRoot -Recurse -File).Count
        $result = Remove-DsaClassifiedFile -RuleId 'temp-windows' -Path $fixtureRoot -WhatIf
        $after = @(Get-ChildItem -LiteralPath $fixtureRoot -Recurse -File).Count
        Assert-Equal $before $after
        Assert-Equal 0 $result.RemovedCount
    }
    Test-Case 'deletes only the files the rule matched and is old enough' {
        $result = Remove-DsaClassifiedFile -RuleId 'temp-windows' -Path $fixtureRoot -Confirm:$false
        Assert-Equal 1 $result.RemovedCount 'only the 60-day-old temp file qualifies'
        Assert-Equal (500MB) $result.RemovedBytes
        Assert-True (Test-Path -LiteralPath (Join-Path $fixtureRoot 'Windows/Temp/fresh.tmp')) 'the recent temp file must survive'
        New-Fixture
    }
}

Describe-Suite 'End-to-end analysis and reporting' {
    $result = Invoke-DiskSpaceAnalysis -Path $fixtureRoot -HorizonMonths 6 -OldestMinSizeBytes 0 -Quiet
    $reportRoot = Join-Path $fixtureRoot '_reports'

    Test-Case 'the result carries every section a report needs' {
        foreach ($property in 'Volume', 'Summary', 'Growth', 'Plan', 'SystemOpportunities', 'ScanErrors', 'Parameters') {
            Assert-True ([bool] $result.PSObject.Properties[$property]) "the result has no $property"
        }
        Assert-True ($result.Summary.FileCount -gt 0) 'nothing was scanned'
        Assert-True ($result.Plan.Recommendation.Count -gt 0) 'no recommendation was produced'
    }
    Test-Case 'the recommendation names the horizon that was asked for' {
        Assert-Match ($result.Plan.Recommendation -join ' ') '6 months'
    }
    Test-Case 'writes a self-contained HTML report' {
        $file = Join-Path $reportRoot 'report.html'
        $null = Export-DsaReport -Result $result -Path $file
        $html = Get-Content -LiteralPath $file -Raw
        Assert-Match $html '<html'
        Assert-Match $html 'Recommendation'
        Assert-Match $html 'Oldest data on the volume'
        Assert-Match $html 'must not simply be deleted'
        Assert-NotMatch $html '(?i)<script src=|<link[^>]+href="http' 'the report must not reference anything external'
    }
    Test-Case 'escapes markup found in file names' {
        $tricky = New-FixtureFile 'Odd/<script>alert(1)</script>.tmp' 2048 30
        try {
            $oddResult = Invoke-DiskSpaceAnalysis -Path (Split-Path $tricky -Parent) -OldestMinSizeBytes 0 -Quiet
            $file = Join-Path $reportRoot 'odd.html'
            $null = Export-DsaReport -Result $oddResult -Path $file
            $html = Get-Content -LiteralPath $file -Raw
            Assert-Match $html '&lt;script&gt;'
            Assert-NotMatch $html '<script>alert'
        } finally {
            Remove-Item -LiteralPath $tricky -Force -ErrorAction SilentlyContinue
        }
    }
    Test-Case 'writes a text report' {
        $file = Join-Path $reportRoot 'report.txt'
        $null = Export-DsaReport -Result $result -Path $file
        $text = Get-Content -LiteralPath $file -Raw
        Assert-Match $text 'RECOMMENDATION'
        Assert-Match $text 'STEP 1 - RECLAIM'
        Assert-Match $text 'STEP 3 - KEEP IT CLEAR'
    }
    Test-Case 'writes JSON that parses back' {
        $file = Join-Path $reportRoot 'report.json'
        $null = Export-DsaReport -Result $result -Path $file
        $parsed = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
        Assert-Equal $result.Summary.FileCount $parsed.Summary.FileCount
        Assert-True ($parsed.Plan.Recommendation.Count -gt 0) 'the recommendation did not survive the round trip'
    }
    Test-Case 'writes one CSV per table' {
        $null = Export-DsaReport -Result $result -Path (Join-Path $reportRoot 'tables.csv')
        foreach ($name in 'actions', 'escalations', 'categories', 'oldest', 'largest', 'directories') {
            Assert-True (Test-Path -LiteralPath (Join-Path $reportRoot "tables.$name.csv")) "tables.$name.csv was not written"
        }
    }
    Test-Case 'generates a cleanup script that is valid PowerShell' {
        $file = Join-Path $reportRoot 'cleanup.ps1'
        $null = New-DsaRemediationScript -Result $result -Path $file
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref] $null, [ref] $errors)
        Assert-Equal 0 @($errors).Count "the generated script does not parse: $(@($errors) | ForEach-Object { $_.Message })"
    }
    Test-Case 'the cleanup script is inert until it is run with -Execute' {
        $script = Get-Content -LiteralPath (Join-Path $reportRoot 'cleanup.ps1') -Raw
        Assert-Match $script '\[switch\] \$Execute'
        # Every deletion has to be gated on -Execute.
        foreach ($line in ($script -split "`r?`n" | Where-Object { $_ -match 'Remove-DsaClassifiedFile' -and $_ -notmatch '^\s*#' })) {
            Assert-Match $line '-WhatIf:\(-not \$Execute\)' "an ungated deletion: $line"
        }
    }
    Test-Case 'the cleanup script never automates Unsafe data' {
        $script = Get-Content -LiteralPath (Join-Path $reportRoot 'cleanup.ps1') -Raw
        foreach ($line in ($script -split "`r?`n" | Where-Object { $_ -match 'Remove-DsaClassifiedFile' -and $_ -notmatch '^\s*#' })) {
            Assert-NotMatch $line "'srv-sql-data'|'srv-hyperv'|'mail-pst'|'user-documents'" "an Unsafe rule was automated: $line"
        }
    }
    Test-Case 'a path that does not exist is an error, not an empty analysis' {
        Assert-Throws { Invoke-DiskSpaceAnalysis -Path (Join-Path $fixtureRoot 'nowhere') -Quiet } 'None of the requested paths exist'
    }
    Test-Case 'system probes are skipped cleanly on a non-Windows host' {
        if (Use-Private 'Test-DsaWindows') {
            Assert-True $true 'running on Windows; probes are exercised by the analysis itself'
        } else {
            Assert-Equal 0 @($result.SystemOpportunities).Count
        }
    }
}

} finally {
    if (Test-Path -LiteralPath $fixtureRoot) {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

exit (Write-TestSummary)
