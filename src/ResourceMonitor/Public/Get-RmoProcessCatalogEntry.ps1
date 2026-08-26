function Get-RmoProcessCatalogEntry {
    <#
        .SYNOPSIS
            Loads the catalogue that says what each process is, who makes it, and what to do
            when it is the thing eating the machine.

        .DESCRIPTION
            Reads Data\ProcessCatalog.psd1, optionally overlays caller-supplied files, validates
            each entry and returns them in priority order.

            Entries are merged by Id, so an overlay can replace a shipped entry (same Id) or add
            new ones. This is the supported way to teach the tool about a line-of-business
            application, and the way to give a site's own software a proper name and publisher in
            the report instead of a filename.

            Compiled results are cached for the session; use -Force after editing a file.

        .PARAMETER Path
            One or more additional .psd1 catalogue files to overlay on the shipped set.

        .PARAMETER Force
            Bypass the session cache and reload from disk.

        .EXAMPLE
            Get-RmoProcessCatalogEntry | Where-Object Class -eq 'Unwanted'

        .EXAMPLE
            Get-RmoProcessCatalogEntry -Path .\SiteApps.psd1 -Force
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [string[]] $Path,
        [switch] $Force
    )

    $cacheKey = if ($Path) { $Path -join '|' } else { '<default>' }
    if ($null -eq $script:RmoCatalogCache) { $script:RmoCatalogCache = @{} }
    if (-not $Force -and $script:RmoCatalogCache.ContainsKey($cacheKey)) {
        return $script:RmoCatalogCache[$cacheKey]
    }

    $files = [System.Collections.Generic.List[string]]::new()
    $files.Add((Join-Path $script:RmoModuleRoot 'Data\ProcessCatalog.psd1'))
    foreach ($extra in $Path) {
        if (-not (Test-Path -LiteralPath $extra)) {
            throw "Catalogue file not found: $extra"
        }
        $files.Add((Resolve-Path -LiteralPath $extra).ProviderPath)
    }

    $validClasses = @(
        'Browser', 'Security', 'Sync', 'System', 'Servicing', 'Communication', 'Media',
        'Productivity', 'Development', 'Virtualisation', 'Gaming', 'Vendor utility',
        'Remote access', 'Driver utility', 'Installer', 'Unwanted')

    # Later files win on Id so an overlay can replace a shipped entry outright.
    $merged = [ordered]@{}
    foreach ($file in $files) {
        $data = Import-PowerShellDataFile -LiteralPath $file
        if (-not $data.Contains('Entries')) { throw "Catalogue file '$file' contains no Entries key." }
        foreach ($raw in $data['Entries']) {
            foreach ($required in 'Id', 'Name', 'Class', 'Description') {
                if (-not $raw.Contains($required)) {
                    throw "An entry in '$file' is missing the required key '$required'."
                }
            }
            $class = [string] $raw['Class']
            if ($class -notin $validClasses) {
                throw "Entry '$($raw['Id'])' has an unknown Class '$class'. Valid values: $($validClasses -join ', ')."
            }
            if (-not $raw.Contains('Match') -and -not $raw.Contains('NamePattern')) {
                throw "Entry '$($raw['Id'])' has neither Match nor NamePattern, so nothing can ever match it."
            }
            $merged[[string] $raw['Id']] = $raw
        }
    }

    $entries = foreach ($raw in $merged.Values) {
        [pscustomobject]@{
            PSTypeName  = 'Rmo.CatalogEntry'
            Id          = [string] $raw['Id']
            Name        = [string] $raw['Name']
            Vendor      = [string] (Get-RmoMapValue $raw 'Vendor' '')
            Family      = [string] (Get-RmoMapValue $raw 'Family' ([string] $raw['Name']))
            Class       = [string] $raw['Class']
            Essential   = [bool] (Get-RmoMapValue $raw 'Essential' $false)
            Description = [string] $raw['Description']
            Expected    = [string] (Get-RmoMapValue $raw 'Expected' '')
            Guidance    = [string] (Get-RmoMapValue $raw 'Guidance' '')
            Command     = [string] (Get-RmoMapValue $raw 'Command' '')
            Match       = @(Get-RmoMapValue $raw 'Match' @())
            NamePattern = [string] (Get-RmoMapValue $raw 'NamePattern' '')
            PathPattern = [string] (Get-RmoMapValue $raw 'PathPattern' '')
            Priority    = [int] (Get-RmoMapValue $raw 'Priority' 500)
        }
    }

    $sorted = @($entries | Sort-Object Priority, Id)
    $script:RmoCatalogCache[$cacheKey] = $sorted
    $sorted
}
