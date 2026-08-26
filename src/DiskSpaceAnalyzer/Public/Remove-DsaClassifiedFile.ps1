function Remove-DsaClassifiedFile {
    <#
        .SYNOPSIS
            Deletes the files belonging to one classification rule, with the rule's own safety
            level enforced.

        .DESCRIPTION
            The deliberate counterpart to the analysis: it can only ever remove files that the
            rule set has positively identified, and by default only those the rule set calls
            Safe. Everything else has to be dealt with through its remediation, which is the
            whole point of the classification.

            It supports -WhatIf, skips files that are locked or protected rather than failing,
            never follows reparse points, never touches cloud placeholders (deleting one
            deletes the cloud copy too), and reports exactly what it freed.

        .PARAMETER RuleId
            The classification rule to act on, for example 'temp-windows'. See
            Get-DsaClassificationRule.

        .PARAMETER Path
            Roots to search. The rule's own path pattern still has to match, so passing a broad
            root is safe - it narrows, it does not widen.

        .PARAMETER MinAgeDays
            Override the rule's own age threshold. Cannot be set below it.

        .PARAMETER AllowReviewClass
            Permit rules classified Review. Required, and deliberately awkward, because those
            need a human decision first.

        .PARAMETER RuleFile
            Additional rule files, matching whatever was used for the analysis.

        .EXAMPLE
            Remove-DsaClassifiedFile -RuleId temp-windows -Path C:\ -WhatIf

        .EXAMPLE
            Remove-DsaClassifiedFile -RuleId win-update-cache -Path C:\ -Confirm:$false
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory, Position = 0)] [string] $RuleId,
        [Parameter(Mandatory, Position = 1)] [string[]] $Path,
        [Nullable[double]] $MinAgeDays,
        [switch] $AllowReviewClass,
        [string[]] $RuleFile
    )

    $rules = if ($RuleFile) { Get-DsaClassificationRule -Path $RuleFile -Force } else { Get-DsaClassificationRule }
    $rule = $rules | Where-Object { $_.Id -eq $RuleId } | Select-Object -First 1
    if (-not $rule) { throw "No classification rule with Id '$RuleId'. Use Get-DsaClassificationRule to list them." }

    if ($rule.Safety -eq 'Unsafe') {
        throw "Rule '$RuleId' ($($rule.Name)) is classified Unsafe and will not be deleted by this command. $($rule.Remediation)"
    }
    if ($rule.Safety -eq 'Review' -and -not $AllowReviewClass) {
        throw "Rule '$RuleId' ($($rule.Name)) is classified Review, which needs a decision first. Re-run with -AllowReviewClass once that decision is made. $($rule.Remediation)"
    }

    $threshold = $rule.EligibleAfterDays
    if ($null -ne $MinAgeDays) {
        if ($MinAgeDays -lt $rule.EligibleAfterDays) {
            throw "MinAgeDays $MinAgeDays is below the rule's own threshold of $($rule.EligibleAfterDays) days. The threshold exists to avoid deleting files still in use."
        }
        $threshold = [double] $MinAgeDays
    }

    $classifier = New-DsaClassifier -Rule $rules
    $reference = [datetime]::UtcNow

    $removedCount = 0L
    $removedBytes = 0L
    $skipped = New-Object System.Collections.ArrayList

    Get-DsaFileInventory -Path $Path -ReferenceTime $reference | ForEach-Object {
        $record = $_
        if ($record.AgeDays -lt $threshold) { return }
        if ($record.IsOffline) { return }

        $match = Resolve-DsaFileCategory -Classifier $classifier -FileName $record.Name `
            -DirectoryKey $record.DirectoryKey -Extension $record.Extension
        if ($match.Id -ne $rule.Id) { return }

        if ($PSCmdlet.ShouldProcess($record.FullName, "Delete ($($rule.Name), $(Format-DsaBytes $record.Length), $([int] $record.AgeDays) days old)")) {
            try {
                Remove-Item -LiteralPath $record.FullName -Force -ErrorAction Stop
                $removedCount++
                $removedBytes += $record.Length
            } catch {
                # In-use and protected files are expected here, not exceptional.
                $null = $skipped.Add([pscustomobject]@{
                    Path   = $record.FullName
                    Length = $record.Length
                    Reason = $_.Exception.Message
                })
            }
        }
    }

    [pscustomobject]@{
        PSTypeName     = 'Dsa.RemovalResult'
        RuleId         = $rule.Id
        RuleName       = $rule.Name
        Safety         = $rule.Safety
        MinAgeDays     = $threshold
        RemovedCount   = $removedCount
        RemovedBytes   = $removedBytes
        RemovedText    = Format-DsaBytes $removedBytes
        SkippedCount   = $skipped.Count
        Skipped        = @($skipped)
        WhatIfMode     = [bool] $WhatIfPreference
    }
}
