function Get-DsaClassificationRule {
    <#
        .SYNOPSIS
            Loads and compiles the rule set that identifies what a file is and whether it is
            safe to delete.

        .DESCRIPTION
            Reads Data\ClassificationRules.psd1 (or a caller-supplied replacement/overlay),
            pre-compiles the regular expressions, and returns the rules sorted by priority so
            the first match for a file is the most specific one.

            Compiled rules are cached for the lifetime of the session. Use -Force to reload
            after editing the data file.

        .PARAMETER Path
            One or more additional .psd1 rule files. Rules are merged by Id, so an overlay file
            can override a shipped rule (same Id) or add site-specific ones (new Id). This is
            the supported way to teach the analyser about a line-of-business application.

        .PARAMETER Force
            Bypass the in-session cache and reload from disk.

        .EXAMPLE
            Get-DsaClassificationRule | Where-Object Safety -eq 'Unsafe' | Select-Object Name, Remediation

        .EXAMPLE
            Get-DsaClassificationRule -Path .\SiteRules.psd1 -Force
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [string[]] $Path,
        [switch] $Force
    )

    $cacheKey = if ($Path) { ($Path -join '|') } else { '<default>' }
    if (-not $Force -and $script:DsaRuleCache -and $script:DsaRuleCache.ContainsKey($cacheKey)) {
        return $script:DsaRuleCache[$cacheKey]
    }
    if (-not $script:DsaRuleCache) { $script:DsaRuleCache = @{} }

    $files = New-Object System.Collections.Generic.List[string]
    $files.Add((Join-Path $script:DsaModuleRoot 'Data\ClassificationRules.psd1'))
    foreach ($extra in $Path) {
        if (-not (Test-Path -LiteralPath $extra)) {
            throw "Rule file not found: $extra"
        }
        $files.Add((Resolve-Path -LiteralPath $extra).ProviderPath)
    }

    # Later files win on Id so an overlay can replace a shipped rule outright.
    $merged = [ordered]@{}
    foreach ($file in $files) {
        $data = Import-PowerShellDataFile -LiteralPath $file
        if (-not $data.Contains('Rules')) { throw "Rule file '$file' contains no Rules key." }
        foreach ($raw in $data['Rules']) {
            foreach ($required in 'Id', 'Name', 'Category', 'Safety', 'Priority') {
                if (-not $raw.ContainsKey($required)) {
                    throw "Rule in '$file' is missing the required key '$required'."
                }
            }
            if ($raw['Safety'] -notin 'Safe', 'Review', 'Unsafe') {
                throw "Rule '$($raw['Id'])' has invalid Safety '$($raw['Safety'])'. Use Safe, Review or Unsafe."
            }
            $merged[[string] $raw['Id']] = $raw
        }
    }

    $options = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
               [System.Text.RegularExpressions.RegexOptions]::Compiled -bor
               [System.Text.RegularExpressions.RegexOptions]::CultureInvariant

    $compiled = foreach ($raw in $merged.Values) {
        $rawExtensions = Get-DsaMapValue $raw 'Extensions'
        $extensions = $null
        if ($rawExtensions) {
            $extensions = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($ext in $rawExtensions) { $null = $extensions.Add([string] $ext) }
        }

        $pathPattern = Get-DsaMapValue $raw 'PathPattern'
        $namePattern = Get-DsaMapValue $raw 'NamePattern'
        $eligibleAfterDays = Get-DsaMapValue $raw 'EligibleAfterDays' 0

        [pscustomobject]@{
            PSTypeName        = 'Dsa.ClassificationRule'
            Id                = [string] $raw['Id']
            Name              = [string] $raw['Name']
            Category          = [string] $raw['Category']
            Safety            = [string] $raw['Safety']
            SafetyRank        = Get-DsaSafetyRank ([string] $raw['Safety'])
            Priority          = [int] $raw['Priority']
            Description       = [string] (Get-DsaMapValue $raw 'Description' '')
            Reason            = [string] (Get-DsaMapValue $raw 'Reason' '')
            Remediation       = [string] (Get-DsaMapValue $raw 'Remediation' '')
            Command           = [string] (Get-DsaMapValue $raw 'Command' '')
            Method            = [string] (Get-DsaMapValue $raw 'Method' 'Policy')
            RequiresReboot    = [bool] (Get-DsaMapValue $raw 'RequiresReboot' $false)
            EligibleAfterDays = [double] $eligibleAfterDays
            PathRegex         = if ($pathPattern) { [regex]::new([string] $pathPattern, $options) } else { $null }
            NameRegex         = if ($namePattern) { [regex]::new([string] $namePattern, $options) } else { $null }
            Extensions        = $extensions
        }
    }

    $sorted = @($compiled | Sort-Object Priority, Id)
    $script:DsaRuleCache[$cacheKey] = $sorted
    $sorted
}
