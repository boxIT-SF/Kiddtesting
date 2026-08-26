function New-RmoIdentifier {
    <#
        .SYNOPSIS
            Compiles a catalogue into the lookup Resolve-RmoProcessIdentity uses.

        .DESCRIPTION
            A scan identifies several hundred processes and does it again on every sample, so the
            matching has to be cheap. This builds:

              - a case-insensitive dictionary of exact process names, checked first;
              - the pattern entries in priority order, with their regular expressions compiled.

            Exact names always win over patterns, so the generic '(service|svc|agent|host)'
            fallback can be broad without ever taking a process a real entry claims.

        .PARAMETER Entry
            Catalogue entries, as returned by Get-RmoProcessCatalogEntry.

        .EXAMPLE
            $identifier = New-RmoIdentifier -Entry (Get-RmoProcessCatalogEntry)
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyCollection()]
        [object[]] $Entry
    )

    $options = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
               [System.Text.RegularExpressions.RegexOptions]::Compiled -bor
               [System.Text.RegularExpressions.RegexOptions]::CultureInvariant

    $exact = [System.Collections.Generic.Dictionary[string,object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $patterns = [System.Collections.Generic.List[object]]::new()
    $collisions = [System.Collections.Generic.List[string]]::new()

    foreach ($item in ($Entry | Sort-Object Priority, Id)) {
        $pathRegex = $null
        if ($item.PathPattern) {
            $pathRegex = [System.Text.RegularExpressions.Regex]::new($item.PathPattern, $options)
        }

        foreach ($name in $item.Match) {
            $key = ([string] $name).Trim()
            if (-not $key) { continue }
            # An earlier (lower priority number) entry keeps the name; record the clash so a
            # site overlay that accidentally steals a name is visible rather than silent.
            if ($exact.ContainsKey($key)) {
                $collisions.Add("'$key' is claimed by '$($exact[$key].Entry.Id)'; '$($item.Id)' also lists it.")
                continue
            }
            $exact[$key] = [pscustomobject]@{ Entry = $item; PathRegex = $pathRegex }
        }

        if ($item.NamePattern) {
            $patterns.Add([pscustomobject]@{
                Entry     = $item
                NameRegex = [System.Text.RegularExpressions.Regex]::new($item.NamePattern, $options)
                PathRegex = $pathRegex
            })
        }
    }

    foreach ($collision in $collisions) { Write-Verbose $collision }

    [pscustomobject]@{
        PSTypeName = 'Rmo.Identifier'
        Exact      = $exact
        Patterns   = @($patterns)
        Collisions = @($collisions)
        EntryCount = @($Entry).Count
    }
}
