function Get-DsaRollupKey {
    <#
        .SYNOPSIS
            Reduces a directory to the ancestor used for the "where is the space going" table.
        .DESCRIPTION
            Aggregating on every directory on a real volume produces hundreds of thousands of
            rows, none of which is actionable. Rolling up to a fixed number of segments below
            the scan root gives a table a technician can act on: 'C:\Users\jsmith\AppData'
            rather than 4,000 rows underneath it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)] [string] $DirectoryKey,
        [Parameter(Position = 1)] [string[]] $RootKey = @(),
        [Parameter(Position = 2)] [int] $Depth = 2
    )

    $matchedRoot = ''
    foreach ($root in $RootKey) {
        if ($DirectoryKey.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase) -and
            $root.Length -gt $matchedRoot.Length) {
            $matchedRoot = $root
        }
    }

    if (-not $matchedRoot) {
        # No known root (scan root was a UNC share reached another way, or a relative path):
        # fall back to the first few segments of the path itself.
        $parts = $DirectoryKey.TrimEnd('\').Split('\')
        $take = [math]::Min($parts.Count, $Depth + 1)
        return (($parts[0..($take - 1)]) -join '\') + '\'
    }

    $remainder = $DirectoryKey.Substring($matchedRoot.Length).Trim('\')
    if ([string]::IsNullOrEmpty($remainder)) { return $matchedRoot }

    $segments = $remainder.Split('\')
    $take = [math]::Min($segments.Count, $Depth)
    $matchedRoot + (($segments[0..($take - 1)]) -join '\') + '\'
}
