# Shared helpers. Nothing in here touches the file system except Test-DsaWindows.

function Format-DsaBytes {
    <#
        .SYNOPSIS
            Renders a byte count the way a human reads a disk usage report.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0, ValueFromPipeline)]
        [AllowNull()]
        [System.Nullable[double]] $Bytes,

        [int] $Decimals = 1
    )
    process {
        if ($null -eq $Bytes) { return 'n/a' }

        $negative = $Bytes -lt 0
        $value = [math]::Abs([double]$Bytes)
        $units = @('B', 'KB', 'MB', 'GB', 'TB', 'PB')
        $index = 0
        while ($value -ge 1024 -and $index -lt ($units.Count - 1)) {
            $value = $value / 1024
            $index++
        }

        # Whole bytes never need a decimal point.
        $places = if ($index -eq 0) { 0 } else { $Decimals }
        $text = '{0:N#} {1}'.Replace('#', $places) -f $value, $units[$index]
        if ($negative) { "-$text" } else { $text }
    }
}

function ConvertTo-DsaNormalizedPath {
    <#
        .SYNOPSIS
            Normalises a path to Windows separators so rule matching behaves identically
            regardless of the host the analyser or its tests run on.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0, ValueFromPipeline)]
        [AllowEmptyString()]
        [string] $Path
    )
    process {
        if ([string]::IsNullOrEmpty($Path)) { return '' }
        $Path.Replace('/', '\')
    }
}

function ConvertTo-DsaDirectoryKey {
    <#
        .SYNOPSIS
            Directory portion of a path, normalised and with a guaranteed trailing separator
            so that rule patterns can anchor on '\Temp\' without matching '\Templates'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)] [string] $DirectoryPath)

    $normalized = ConvertTo-DsaNormalizedPath $DirectoryPath
    if ([string]::IsNullOrEmpty($normalized)) { return '\' }
    if (-not $normalized.EndsWith('\')) { $normalized += '\' }
    $normalized
}

function Test-DsaWindows {
    <#
        .SYNOPSIS
            True when running on Windows. Windows PowerShell 5.1 has no $IsWindows, and it
            only ever runs on Windows, so an undefined variable means Windows.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $flag = Get-Variable -Name IsWindows -Scope Global -ErrorAction SilentlyContinue
    if ($null -eq $flag) { return $true }
    [bool] $flag.Value
}

function Get-DsaExtendedPath {
    <#
        .SYNOPSIS
            Applies the \\?\ prefix so enumeration keeps working past MAX_PATH.
        .NOTES
            Only on Windows, only for rooted paths already long enough to need it, and never
            twice.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0, Mandatory)] [string] $Path)

    if (-not (Test-DsaWindows)) { return $Path }
    if ($Path.StartsWith('\\?\')) { return $Path }

    # Only reach for the prefix when the path actually needs it. Windows PowerShell 5.1 on
    # older .NET Framework builds rejects '\\?\' paths outright, so applying it to every
    # path would trade a rare failure for a universal one.
    if ($Path.Length -lt 240) { return $Path }

    if ($Path.StartsWith('\\')) { return '\\?\UNC\' + $Path.Substring(2) }
    if ($Path -match '^[A-Za-z]:\\') { return '\\?\' + $Path }
    $Path
}

function ConvertFrom-DsaExtendedPath {
    <#
        .SYNOPSIS
            Strips the \\?\ prefix again so reports show paths a human can paste into Explorer.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)] [AllowEmptyString()] [string] $Path)

    if ([string]::IsNullOrEmpty($Path)) { return $Path }
    if ($Path.StartsWith('\\?\UNC\')) { return '\\' + $Path.Substring(8) }
    if ($Path.StartsWith('\\?\')) { return $Path.Substring(4) }
    $Path
}

function Get-DsaAgeBucketDefinition {
    <#
        .SYNOPSIS
            The age bands used for the "how old is the data" histogram, oldest last.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param()

    @(
        [pscustomobject]@{ Order = 0; Name = 'Under 30 days';  MinDays = 0;    MaxDays = 30 }
        [pscustomobject]@{ Order = 1; Name = '30 - 90 days';   MinDays = 30;   MaxDays = 90 }
        [pscustomobject]@{ Order = 2; Name = '90 - 180 days';  MinDays = 90;   MaxDays = 180 }
        [pscustomobject]@{ Order = 3; Name = '180 days - 1 y'; MinDays = 180;  MaxDays = 365 }
        [pscustomobject]@{ Order = 4; Name = '1 - 2 years';    MinDays = 365;  MaxDays = 730 }
        [pscustomobject]@{ Order = 5; Name = '2 - 5 years';    MinDays = 730;  MaxDays = 1825 }
        [pscustomobject]@{ Order = 6; Name = 'Over 5 years';   MinDays = 1825; MaxDays = [double]::MaxValue }
    )
}

function Get-DsaAgeBucketIndex {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Position = 0, Mandatory)] [double] $AgeDays)

    if ($AgeDays -lt 30)   { return 0 }
    if ($AgeDays -lt 90)   { return 1 }
    if ($AgeDays -lt 180)  { return 2 }
    if ($AgeDays -lt 365)  { return 3 }
    if ($AgeDays -lt 730)  { return 4 }
    if ($AgeDays -lt 1825) { return 5 }
    return 6
}

function Get-DsaSafetyRank {
    <#
        .SYNOPSIS
            Sort weight for a safety level - lower is safer, so plans fill from the safe end.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Position = 0)] [AllowNull()] [string] $Safety)

    switch ($Safety) {
        'Safe'   { 0 }
        'Review' { 1 }
        'Unsafe' { 2 }
        default  { 3 }
    }
}

function ConvertTo-DsaHtmlText {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0, ValueFromPipeline)] [AllowNull()] [string] $Text)

    process {
        if ([string]::IsNullOrEmpty($Text)) { return '' }
        $Text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
    }
}

function Add-DsaBoundedItem {
    <#
        .SYNOPSIS
            Appends to a top-N list, trimming back down once it grows past a slack threshold.
        .DESCRIPTION
            Keeping every file in memory is not an option on a volume with millions of them.
            This keeps the list bounded while only paying for a sort every few hundred adds.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.ArrayList] $List,
        [Parameter(Mandatory)] [psobject] $Item,
        [Parameter(Mandatory)] [string] $SortProperty,
        [Parameter(Mandatory)] [int] $Keep,
        [switch] $Descending
    )

    $null = $List.Add($Item)
    if ($List.Count -le ($Keep * 4)) { return }

    $sorted = $List | Sort-Object -Property $SortProperty -Descending:$Descending.IsPresent |
        Select-Object -First $Keep
    $List.Clear()
    foreach ($entry in $sorted) { $null = $List.Add($entry) }
}

function Get-DsaBoundedResult {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.ArrayList] $List,
        [Parameter(Mandatory)] [string] $SortProperty,
        [Parameter(Mandatory)] [int] $Keep,
        [switch] $Descending
    )

    @($List | Sort-Object -Property $SortProperty -Descending:$Descending.IsPresent |
        Select-Object -First $Keep)
}

function Get-DsaMapValue {
    <#
        .SYNOPSIS
            Reads an optional key out of a hashtable. Needed because Set-StrictMode makes a
            missing key a terminating error when accessed as a property.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)] [System.Collections.IDictionary] $Table,
        [Parameter(Mandatory, Position = 1)] [string] $Key,
        [Parameter(Position = 2)] $Default = $null
    )

    if ($Table.Contains($Key) -and $null -ne $Table[$Key]) { return $Table[$Key] }
    $Default
}
