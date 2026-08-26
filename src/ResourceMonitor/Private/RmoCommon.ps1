# Shared helpers. Nothing here samples the machine; it only formats, ranks and guards.

function Format-RmoBytes {
    <#
        .SYNOPSIS
            Renders a byte count the way a human reads a memory figure.
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
        $value = [math]::Abs([double] $Bytes)
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

function Format-RmoRate {
    <#
        .SYNOPSIS
            A byte rate, e.g. '4.2 MB/s'. Zero renders as a dash so tables stay readable.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)] [AllowNull()] [System.Nullable[double]] $BytesPerSecond
    )

    if ($null -eq $BytesPerSecond) { return 'n/a' }
    if ([math]::Abs([double] $BytesPerSecond) -lt 1024) { return '-' }
    "$(Format-RmoBytes $BytesPerSecond)/s"
}

function Format-RmoPercent {
    <#
        .SYNOPSIS
            A percentage with one decimal place, or 'n/a' when the counter was unavailable.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)] [AllowNull()] [System.Nullable[double]] $Value,
        [int] $Decimals = 1
    )

    if ($null -eq $Value) { return 'n/a' }
    ('{0:N#}%'.Replace('#', $Decimals)) -f [double] $Value
}

function Format-RmoDuration {
    <#
        .SYNOPSIS
            A timespan as '12d 4h', '4h 20m' or '20m' - whichever two units carry the meaning.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)] [AllowNull()] [System.Nullable[double]] $TotalSeconds)

    if ($null -eq $TotalSeconds -or $TotalSeconds -lt 0) { return 'n/a' }

    $span = [timespan]::FromSeconds([double] $TotalSeconds)
    if ($span.TotalDays -ge 1) { return '{0}d {1}h' -f [int] $span.TotalDays, $span.Hours }
    if ($span.TotalHours -ge 1) { return '{0}h {1}m' -f [int] $span.TotalHours, $span.Minutes }
    if ($span.TotalMinutes -ge 1) { return '{0}m' -f [int] $span.TotalMinutes }
    '{0}s' -f [int] $span.TotalSeconds
}

function Limit-RmoValue {
    <#
        .SYNOPSIS
            Clamps a number into a range.
        .NOTES
            [math]::Clamp does not exist on the .NET Framework that Windows PowerShell 5.1
            runs on, so this stands in for it.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory, Position = 0)] [double] $Value,
        [Parameter(Mandatory, Position = 1)] [double] $Minimum,
        [Parameter(Mandatory, Position = 2)] [double] $Maximum
    )

    if ($Value -lt $Minimum) { return $Minimum }
    if ($Value -gt $Maximum) { return $Maximum }
    $Value
}

function Get-RmoFirstOrDefault {
    <#
        .SYNOPSIS
            First element of a collection, or $null when there is not one.
        .NOTES
            Set-StrictMode -Version Latest makes an out-of-bounds array index a terminating
            error, so @(Get-CimInstance ...)[0] cannot be used on a class that returned nothing.
    #>
    [CmdletBinding()]
    param([Parameter(Position = 0)] [AllowNull()] [AllowEmptyCollection()] $InputObject)

    $items = @($InputObject)
    if ($items.Count -eq 0) { return $null }
    $items[0]
}

function Get-RmoMapValue {
    <#
        .SYNOPSIS
            Reads an optional key out of a hashtable.
        .DESCRIPTION
            Needed because Set-StrictMode makes a missing key a terminating error when it is
            reached as a property.
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

function Get-RmoObjectValue {
    <#
        .SYNOPSIS
            Reads a property that may not exist on the object.
        .DESCRIPTION
            CIM classes differ between Windows builds, and perf counter classes are sometimes
            registered with a subset of their properties. Reaching for one directly under
            StrictMode turns a missing counter into a failed scan.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)] [AllowNull()] $InputObject,
        [Parameter(Mandatory, Position = 1)] [string] $Name,
        [Parameter(Position = 2)] $Default = $null
    )

    if ($null -eq $InputObject) { return $Default }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    $property.Value
}

function Test-RmoWindows {
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

function Test-RmoElevated {
    <#
        .SYNOPSIS
            True when the session is running as an administrator.
        .DESCRIPTION
            Elevation is what makes the command line, executable path and owner of another
            user's processes readable, so the scan reports whether it had it.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if (-not (Test-RmoWindows)) { return $false }
    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
        $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        Write-Verbose "Could not determine elevation: $($_.Exception.Message)"
        $false
    }
}

function ConvertTo-RmoHtmlText {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0, ValueFromPipeline)] [AllowNull()] [string] $Text)

    process {
        if ([string]::IsNullOrEmpty($Text)) { return '' }
        $Text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
    }
}

function ConvertTo-RmoNormalizedPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0, ValueFromPipeline)] [AllowEmptyString()] [AllowNull()] [string] $Path)

    process {
        if ([string]::IsNullOrEmpty($Path)) { return '' }
        $Path.Replace('/', '\')
    }
}

function Get-RmoLeafName {
    <#
        .SYNOPSIS
            The file name of a Windows path, without its extension.
        .NOTES
            [System.IO.Path] uses the separator of the host it is running on, so on PowerShell 7
            for Linux - which is where this module's tests run - it does not treat a backslash as
            a separator at all. Splitting explicitly keeps the answer the same everywhere, which
            matters because the paths being parsed always came from Windows.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)] [AllowEmptyString()] [AllowNull()] [string] $Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $leaf = ($Path.TrimEnd('\', '/', ' ') -split '[\\/]')[-1]
    $dot = $leaf.LastIndexOf('.')
    if ($dot -gt 0) { return $leaf.Substring(0, $dot) }
    $leaf
}

function ConvertTo-RmoSlug {
    <#
        .SYNOPSIS
            Turns a name into a lower-case, hyphenated identifier.
        .DESCRIPTION
            Action ids are typed by a person - the generated tuning script takes them on the
            command line - so 'process-Google Chrome' is the wrong shape for one. This produces
            'process-google-chrome', which can be typed without quoting.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)] [AllowEmptyString()] [AllowNull()] [string] $Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return 'unnamed' }
    $slug = ($Text.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    if (-not $slug) { return 'unnamed' }
    if ($slug.Length -gt 48) { $slug = $slug.Substring(0, 48).TrimEnd('-') }
    $slug
}

function Get-RmoImpactRank {
    <#
        .SYNOPSIS
            Sort weight for an impact level - lower sorts first, so the plan leads with the
            change that makes the biggest difference.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Position = 0)] [AllowNull()] [string] $Impact)

    switch ($Impact) {
        'High'   { 0 }
        'Medium' { 1 }
        'Low'    { 2 }
        'Info'   { 3 }
        default  { 4 }
    }
}

function Get-RmoSafetyRank {
    <#
        .SYNOPSIS
            Sort weight for how safe an action is - lower is safer, so equally useful actions
            are offered from the safe end first.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Position = 0)] [AllowNull()] [string] $Safety)

    switch ($Safety) {
        'Safe'    { 0 }
        'Review'  { 1 }
        'Caution' { 2 }
        default   { 3 }
    }
}

function Get-RmoEffortRank {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Position = 0)] [AllowNull()] [string] $Effort)

    switch ($Effort) {
        'Instant' { 0 }
        'Quick'   { 1 }
        'Planned' { 2 }
        'Hardware' { 3 }
        default   { 4 }
    }
}

function Get-RmoPressureLevel {
    <#
        .SYNOPSIS
            Turns a 0-100 utilisation figure into the word a report should use for it.
        .PARAMETER Warning
            The point at which the resource starts to be felt by the person using the machine.
        .PARAMETER Critical
            The point at which it is the reason the machine is unusable.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)] [AllowNull()] [System.Nullable[double]] $Value,
        [Parameter(Position = 1)] [double] $Warning = 70,
        [Parameter(Position = 2)] [double] $Critical = 90
    )

    if ($null -eq $Value) { return 'Unknown' }
    if ($Value -ge $Critical) { return 'Critical' }
    if ($Value -ge $Warning) { return 'Elevated' }
    'Normal'
}

function Test-RmoUserWritablePath {
    <#
        .SYNOPSIS
            True when an executable lives somewhere any user can write to.
        .DESCRIPTION
            Not a malware verdict on its own - plenty of legitimate software installs per-user
            into AppData. It matters as a qualifier: an unsigned, unrecognised executable
            burning a core from %TEMP% is worth a second look, and the same file under
            \Program Files is not.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)] [AllowEmptyString()] [AllowNull()] [string] $Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $normalized = (ConvertTo-RmoNormalizedPath $Path).ToLowerInvariant()

    foreach ($fragment in @(
        '\appdata\local\temp\', '\appdata\roaming\', '\appdata\local\',
        '\users\public\', '\windows\temp\', '\programdata\', '\downloads\', '\$recycle.bin\')) {
        if ($normalized.Contains($fragment)) { return $true }
    }
    $false
}

function Invoke-RmoCim {
    <#
        .SYNOPSIS
            Get-CimInstance that reports a failure instead of throwing one.
        .DESCRIPTION
            A scan reads a dozen CIM classes, several of which are absent or broken on any
            given machine - a de-registered perf counter class, a Storage namespace that is
            not there on Server 2012 R2, a WMI repository that needs rebuilding. Losing one
            reading should cost that reading, not the scan.
        .PARAMETER ErrorSink
            Optional list; the reason for a failed query is appended to it for the report.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory, Position = 0)] [string] $ClassName,
        [string] $Namespace,
        [string] $Filter,
        [string[]] $Property,
        [System.Collections.IList] $ErrorSink
    )

    $arguments = @{ ClassName = $ClassName; ErrorAction = 'Stop' }
    if ($Namespace) { $arguments['Namespace'] = $Namespace }
    if ($Filter) { $arguments['Filter'] = $Filter }
    if ($Property) { $arguments['Property'] = $Property }

    try {
        @(Get-CimInstance @arguments)
    } catch {
        $message = "Could not read $ClassName : $($_.Exception.Message)"
        Write-Verbose $message
        if ($null -ne $ErrorSink) { $null = $ErrorSink.Add($message) }
        @()
    }
}

function Test-RmoCancelled {
    <#
        .SYNOPSIS
            True when the caller has asked for the scan to stop.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)] [AllowNull()] [System.Collections.IDictionary] $CancellationSink)

    if ($null -eq $CancellationSink) { return $false }
    [bool] (Get-RmoMapValue $CancellationSink 'Cancelled' $false)
}

function Set-RmoStatus {
    <#
        .SYNOPSIS
            Publishes the current phase to the status dictionary the UI polls.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)] [AllowNull()] [System.Collections.IDictionary] $StatusSink,
        [Parameter(Mandatory, Position = 1)] [string] $Phase,
        [Parameter(Position = 2)] [string] $Detail = ''
    )

    if ($null -eq $StatusSink) { return }
    $StatusSink['Phase'] = $Phase
    $StatusSink['Detail'] = $Detail
}

function Format-RmoWrappedText {
    <#
        .SYNOPSIS
            Wraps a paragraph to a column width, with an optional hanging indent.
        .DESCRIPTION
            The explanations in this tool are sentences, not labels, and a text report that lets
            them run to 400 characters is unreadable in a console or an email.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Position = 0)] [AllowEmptyString()] [AllowNull()] [string] $Text,
        [Parameter(Position = 1)] [int] $Width = 96,
        [Parameter(Position = 2)] [string] $Indent = ''
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }

    $available = $Width - $Indent.Length
    if ($available -lt 20) { $available = 20 }

    $lines = [System.Collections.Generic.List[string]]::new()
    $current = ''
    foreach ($word in ($Text -split '\s+')) {
        if (-not $word) { continue }
        if (-not $current) {
            $current = $word
        } elseif (($current.Length + 1 + $word.Length) -le $available) {
            $current = "$current $word"
        } else {
            $lines.Add($Indent + $current)
            $current = $word
        }
    }
    if ($current) { $lines.Add($Indent + $current) }
    $lines.ToArray()
}
