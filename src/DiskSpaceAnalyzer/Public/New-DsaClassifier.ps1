function New-DsaClassifier {
    <#
        .SYNOPSIS
            Builds a reusable classification context.

        .DESCRIPTION
            Wraps a compiled rule set together with a per-directory candidate cache. Most of
            the cost of classifying a file is testing path patterns, and files arrive grouped
            by directory, so caching the candidate rules for a directory turns a scan of a
            million files into roughly one regex pass per folder instead of per file.

        .PARAMETER Rule
            A pre-compiled rule set from Get-DsaClassificationRule. Defaults to the shipped set.

        .PARAMETER MaxCachedDirectories
            Upper bound on the directory cache before it is reset, so a scan across a very wide
            tree cannot grow the cache without limit.

        .EXAMPLE
            $classifier = New-DsaClassifier
            Resolve-DsaFileCategory -Classifier $classifier -FileName 'foo.tmp' -DirectoryKey 'C:\Windows\Temp\' -AgeDays 40
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [object[]] $Rule,
        [int] $MaxCachedDirectories = 50000
    )

    if (-not $Rule) { $Rule = Get-DsaClassificationRule }

    $fallback = $Rule | Where-Object { $_.Id -eq 'unclassified' } | Select-Object -First 1
    if (-not $fallback) {
        # Any rule set must be able to classify everything, even if only as "unknown".
        $fallback = $Rule | Select-Object -Last 1
    }

    [pscustomobject]@{
        PSTypeName           = 'Dsa.Classifier'
        Rules                = $Rule
        Fallback             = $fallback
        DirectoryCache       = @{}
        MaxCachedDirectories = $MaxCachedDirectories
    }
}
