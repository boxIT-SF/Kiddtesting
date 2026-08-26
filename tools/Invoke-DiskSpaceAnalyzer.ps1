<#
.SYNOPSIS
    Command-line entry point for the Disk Space Analyzer. Built to be run by hand or dropped
    into an RMM as a scheduled script.

.DESCRIPTION
    Scans a volume, prints the analysis, and optionally writes an HTML report, a JSON document
    and a cleanup script. Nothing is ever deleted by this script.

    Exit codes, so a monitoring system can act on the result:

        0  the volume already has, or can reach, the requested months of headroom
        1  cleanup alone cannot reach the target - the volume needs data moved off it or more
           capacity (the report lists what and how)
        2  the analysis itself failed

.PARAMETER Path
    Volume or folder to analyse. Defaults to the system drive.

.PARAMETER Months
    Months of headroom the plan must deliver. Defaults to 6.

.PARAMETER MinSizeMB
    Ignore files smaller than this many megabytes. Raising it speeds up a large scan
    considerably and barely changes the reclaimable totals. Defaults to 1.

.PARAMETER Report
    Write an HTML report here.

.PARAMETER Json
    Write the full result as JSON here.

.PARAMETER CleanupScript
    Write a cleanup script here. The generated script does nothing until run with -Execute.

.PARAMETER GrowthGBPerMonth
    Use a growth rate measured elsewhere instead of estimating one from file timestamps.

.PARAMETER Deep
    Also run DISM component store analysis. Slow, needs elevation.

.PARAMETER Quiet
    Do not print the report to the console. Useful when only the files or the exit code matter.

.EXAMPLE
    .\Invoke-DiskSpaceAnalyzer.ps1 -Path C:\ -Months 6

.EXAMPLE
    .\Invoke-DiskSpaceAnalyzer.ps1 -Path D:\ -Report \\fs01\reports\$env:COMPUTERNAME.html -Quiet
#>
[CmdletBinding()]
param(
    [string] $Path,
    [ValidateRange(1, 120)] [int] $Months = 6,
    [double] $MinSizeMB = 1,
    [string] $Report,
    [string] $Json,
    [string] $CleanupScript,
    [Nullable[double]] $GrowthGBPerMonth,
    [switch] $Deep,
    [switch] $Quiet
)

$ErrorActionPreference = 'Stop'

try {
    $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'src\DiskSpaceAnalyzer\DiskSpaceAnalyzer.psd1'
    if (-not (Test-Path -LiteralPath $modulePath)) {
        # Also support the module having been installed normally.
        $modulePath = 'DiskSpaceAnalyzer'
    }
    Import-Module $modulePath -Force

    $analysisArgs = @{
        HorizonMonths    = $Months
        MinFileSizeBytes = [long] ($MinSizeMB * 1MB)
    }
    if ($Path) { $analysisArgs['Path'] = $Path }
    if ($Deep) { $analysisArgs['DeepSystemProbe'] = $true }
    if ($Quiet) { $analysisArgs['Quiet'] = $true }
    if ($null -ne $GrowthGBPerMonth) { $analysisArgs['KnownGrowthBytesPerMonth'] = $GrowthGBPerMonth * 1GB }

    $result = Invoke-DiskSpaceAnalysis @analysisArgs

    if (-not $Quiet) {
        Write-Output (New-DsaTextReport -Result $result)
    }

    if ($Report)        { $null = Export-DsaReport -Result $result -Path $Report -Format Html }
    if ($Json)          { $null = Export-DsaReport -Result $result -Path $Json -Format Json }
    if ($CleanupScript) { $null = New-DsaRemediationScript -Result $result -Path $CleanupScript }

    foreach ($file in @($Report, $Json, $CleanupScript)) {
        if ($file) { Write-Output "Wrote $file" }
    }

    if ($result.Plan.Achievable) { exit 0 } else { exit 1 }

} catch {
    # -ErrorAction Continue matters here: with $ErrorActionPreference set to Stop, a plain
    # Write-Error would itself terminate and the exit code below would never be reached.
    Write-Error -ErrorRecord $_ -ErrorAction Continue
    exit 2
}
