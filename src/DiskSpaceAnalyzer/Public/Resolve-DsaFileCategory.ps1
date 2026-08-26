function Resolve-DsaFileCategory {
    <#
        .SYNOPSIS
            Answers "what is this file, and is it safe to delete?" for a single file.

        .DESCRIPTION
            Returns the highest-priority matching classification rule. The returned object is
            the shared rule instance, not a copy - callers must not mutate it. Whether the file
            is old enough to actually be a reclamation candidate is deliberately left to the
            caller (compare AgeDays against the rule's EligibleAfterDays) so that classification
            stays free of allocations on a hot path.

        .PARAMETER Classifier
            Context from New-DsaClassifier. Supplying one across many calls is what makes the
            directory cache effective.

        .PARAMETER FileName
            File name only, no directory.

        .PARAMETER DirectoryKey
            The containing directory, normalised with ConvertTo-DsaDirectoryKey (backslashes,
            trailing separator).

        .PARAMETER Extension
            Lower-case extension including the dot. Derived from FileName when omitted.

        .EXAMPLE
            Resolve-DsaFileCategory -FileName 'pagefile.sys' -DirectoryKey 'C:\'
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [psobject] $Classifier,

        [Parameter(Mandatory, Position = 0)]
        [string] $FileName,

        [Parameter(Mandatory, Position = 1)]
        [string] $DirectoryKey,

        [string] $Extension
    )

    if (-not $Classifier) { $Classifier = New-DsaClassifier }
    if (-not $PSBoundParameters.ContainsKey('Extension')) {
        $Extension = [System.IO.Path]::GetExtension($FileName)
    }
    if ($null -eq $Extension) { $Extension = '' }

    $candidates = $Classifier.DirectoryCache[$DirectoryKey]
    if ($null -eq $candidates) {
        $matched = New-Object System.Collections.Generic.List[psobject]
        foreach ($rule in $Classifier.Rules) {
            if ($null -eq $rule.PathRegex -or $rule.PathRegex.IsMatch($DirectoryKey)) {
                $matched.Add($rule)
            }
        }
        $candidates = $matched.ToArray()

        if ($Classifier.DirectoryCache.Count -ge $Classifier.MaxCachedDirectories) {
            $Classifier.DirectoryCache.Clear()
        }
        $Classifier.DirectoryCache[$DirectoryKey] = $candidates
    }

    foreach ($rule in $candidates) {
        if ($null -ne $rule.NameRegex -and -not $rule.NameRegex.IsMatch($FileName)) { continue }
        if ($null -ne $rule.Extensions -and -not $rule.Extensions.Contains($Extension)) { continue }
        return $rule
    }

    $Classifier.Fallback
}
