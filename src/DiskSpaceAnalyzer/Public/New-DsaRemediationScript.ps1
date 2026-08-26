function New-DsaRemediationScript {
    <#
        .SYNOPSIS
            Writes a runnable PowerShell script that performs the safe half of the plan and
            documents the rest.

        .DESCRIPTION
            The generated script is deliberately conservative:

              * it does nothing until it is run with -Execute; by default every step reports
                what it would do and changes nothing;
              * it only automates actions the rule set classified Safe;
              * anything needing a decision, a reboot or a policy change is written into the
                script as a commented block with its remediation, so the script doubles as the
                change record;
              * it records free space before and after so the result can be verified.

        .PARAMETER Result
            Output of Invoke-DiskSpaceAnalysis.

        .PARAMETER Path
            Where to write the .ps1.

        .PARAMETER ModulePath
            Path to DiskSpaceAnalyzer.psd1 baked into the script as the default. Defaults to
            the module currently loaded.

        .PARAMETER IncludeReviewActions
            Also emit the Review actions as executable steps (still gated behind -Execute, and
            each one still carries -AllowReviewClass). Off by default.

        .PARAMETER PassThru
            Return the generated file.

        .EXAMPLE
            $result | New-DsaRemediationScript -Path .\cleanup-SRV01.ps1
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(Mandatory, ValueFromPipeline, Position = 0)] [psobject] $Result,
        [Parameter(Mandatory, Position = 1)] [string] $Path,
        [string] $ModulePath,
        [switch] $IncludeReviewActions,
        [switch] $PassThru
    )

    process {
        if (-not $ModulePath) {
            $ModulePath = Join-Path $script:DsaModuleRoot 'DiskSpaceAnalyzer.psd1'
        }

        $plan = $Result.Plan
        $roots = ($Result.Path | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }) -join ', '
        $volumeRoot = $Result.Volume.Root

        $sb = New-Object System.Text.StringBuilder
        function Add-Line { param([string] $Text = '') $null = $sb.AppendLine($Text) }
        function Add-Comment {
            param([string] $Text, [string] $Prefix = '#   ')
            foreach ($line in (Split-DsaTextBlock -Text $Text -Width 100)) {
                Add-Line ($Prefix + $line.TrimStart())
            }
        }

        Add-Line '<#'
        Add-Line '    Disk space remediation script'
        Add-Line ''
        Add-Line "    Generated  : $($Result.ScanFinishedUtc.ToString('yyyy-MM-dd HH:mm')) UTC"
        Add-Line "    Machine    : $($Result.ComputerName)"
        Add-Line "    Volume     : $volumeRoot ($($Result.Volume.FreeText) free of $($Result.Volume.CapacityText))"
        Add-Line "    Horizon    : $($plan.HorizonMonths) months"
        Add-Line "    Target     : $($plan.TargetFreeText) free ($($plan.DeficitText) short today)"
        Add-Line "    This script: reclaims up to $($plan.ReclaimableSafeText) of Safe data"
        Add-Line ''
        Add-Line '    Nothing is deleted unless you pass -Execute. Run it once without to see'
        Add-Line '    exactly what it would touch.'
        Add-Line '#>'
        Add-Line '[CmdletBinding()]'
        Add-Line 'param('
        Add-Line '    # Actually perform the deletions. Without this every step is a dry run.'
        Add-Line '    [switch] $Execute,'
        Add-Line ''
        Add-Line "    [string] `$ModulePath = '$($ModulePath.Replace("'", "''"))'"
        Add-Line ')'
        Add-Line ''
        Add-Line '$ErrorActionPreference = ''Stop'''
        Add-Line ''
        Add-Line 'Import-Module $ModulePath -Force'
        Add-Line ''
        Add-Line "`$targetRoot = '$($volumeRoot.Replace("'", "''"))'"
        Add-Line "`$scanRoots  = @($roots)"
        Add-Line '$before = Get-DsaVolumeInfo -Path $targetRoot'
        Add-Line 'Write-Host "Free before: $($before.FreeText) of $($before.CapacityText)" -ForegroundColor Cyan'
        Add-Line 'if (-not $Execute) { Write-Host "DRY RUN - nothing will be deleted. Add -Execute to apply." -ForegroundColor Yellow }'
        Add-Line ''
        Add-Line '$results = New-Object System.Collections.Generic.List[psobject]'
        Add-Line ''

        $automated = @($plan.Actions | Where-Object {
            $_.Source -eq 'Scan' -and ($_.Safety -eq 'Safe' -or ($IncludeReviewActions -and $_.Safety -eq 'Review'))
        })

        if ($automated.Count -eq 0) {
            Add-Line '# No action in this plan can be automated safely; see the manual section below.'
            Add-Line ''
        }

        foreach ($action in $automated) {
            Add-Line ('# ' + ('-' * 96))
            Add-Line "# $($action.Title) - up to $($action.SizeText) across $($action.FileCount) file(s)"
            Add-Comment $action.WhatItIs
            Add-Comment $action.Reason
            Add-Line ('# ' + ('-' * 96))
            $reviewSwitch = if ($action.Safety -eq 'Review') { ' -AllowReviewClass' } else { '' }
            Add-Line "Write-Host 'Step: $($action.Title.Replace("'", "''"))' -ForegroundColor Cyan"
            Add-Line "`$results.Add((Remove-DsaClassifiedFile -RuleId '$($action.Id)' -Path `$scanRoots$reviewSwitch -WhatIf:(-not `$Execute) -Confirm:`$false))"
            Add-Line ''
        }

        Add-Line ('# ' + ('=' * 96))
        Add-Line '# Manual steps - not automated, listed so the plan is complete.'
        Add-Line ('# ' + ('=' * 96))
        Add-Line ''

        $manual = @($plan.Actions | Where-Object { $_.Source -ne 'Scan' }) +
                  @($plan.Actions | Where-Object { $_.Source -eq 'Scan' -and $_ -notin $automated }) +
                  @($plan.Escalations | Where-Object { $_.SizeBytes -gt 0 })

        foreach ($item in $manual) {
            Add-Line "# [$($item.Safety)] $($item.Title) - $($item.SizeText)"
            Add-Comment $item.WhatItIs
            if ($item.Reason) { Add-Comment "Why: $($item.Reason)" }
            if ($item.Remediation) { Add-Comment "Do: $($item.Remediation)" }
            if ($item.Command) {
                Add-Line '#'
                foreach ($line in ($item.Command -split "`r?`n")) { Add-Line "#     $line" }
            }
            if ($item.RequiresReboot) { Add-Line '#     (requires a reboot)' }
            Add-Line '#'
        }

        Add-Line ''
        Add-Line ('# ' + ('=' * 96))
        Add-Line '# Preventive controls - put these in place or the space comes back.'
        Add-Line ('# ' + ('=' * 96))
        foreach ($control in $plan.PreventiveControls) {
            Add-Line "# $($control.Trigger): $($control.Name)"
            Add-Comment $control.Detail
            if ($control.Command) { Add-Line "#     $($control.Command)" }
            Add-Line '#'
        }

        Add-Line ''
        Add-Line '$after = Get-DsaVolumeInfo -Path $targetRoot'
        Add-Line '$freed = 0L'
        Add-Line 'foreach ($result in $results) { $freed += $result.RemovedBytes }'
        Add-Line 'Write-Host ""'
        Add-Line '$results | Format-Table RuleName, RemovedCount, RemovedText, SkippedCount -AutoSize'
        Add-Line 'Write-Host "Free after: $($after.FreeText) of $($after.CapacityText)" -ForegroundColor Cyan'
        Add-Line 'if ($Execute) {'
        Add-Line '    Write-Host "Reclaimed by this script: $(($freed / 1GB).ToString(''N2'')) GB" -ForegroundColor Green'
        Add-Line '} else {'
        Add-Line '    Write-Host "Dry run complete. Re-run with -Execute to apply." -ForegroundColor Yellow'
        Add-Line '}'

        if ($PSCmdlet.ShouldProcess($Path, 'Write remediation script')) {
            $directory = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($Path))
            if ($directory -and -not (Test-Path -LiteralPath $directory)) {
                $null = New-Item -ItemType Directory -Path $directory -Force
            }
            Set-Content -LiteralPath $Path -Value $sb.ToString() -Encoding UTF8
            if ($PassThru) { Get-Item -LiteralPath $Path }
        }
    }
}
