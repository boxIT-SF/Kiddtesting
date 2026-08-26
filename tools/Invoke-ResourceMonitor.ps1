<#
.SYNOPSIS
    Runs a resource scan from the command line and prints or saves the result.

.DESCRIPTION
    The command-line face of the tool, for a support call, a scheduled run from an RMM, or a
    fleet-wide sweep. Nothing is changed on the machine.

    Exit codes, so a monitoring platform can act on the result:

        0  nothing high-impact found
        1  at least one high-impact action
        2  the scan itself failed

.PARAMETER ScanMode
    Quick (about ten seconds) or Complete (a minute or two, and the mode that finds intermittent
    and reliability problems). Defaults to Quick.

.PARAMETER Report
    Write an HTML report here. The directory is created if needed.

.PARAMETER Json
    Write the full result as JSON here, for a monitoring platform to consume.

.PARAMETER Csv
    Write one row per process here.

.PARAMETER TuningScript
    Write the generated tuning script here. It changes nothing until it is given -Run.

.PARAMETER CatalogFile
    Additional catalogue files, so a site's own software is named and attributed properly.

.PARAMETER Quiet
    Do not print the report to the console. Use with -Report for a scheduled run.

.PARAMETER PlanOnly
    Print just the verdict and the plan, without the tables.

.EXAMPLE
    .\Invoke-ResourceMonitor.ps1

.EXAMPLE
    .\Invoke-ResourceMonitor.ps1 -ScanMode Complete -PlanOnly

.EXAMPLE
    # Scheduled run: write a report to a share and say nothing on the console.
    .\Invoke-ResourceMonitor.ps1 -ScanMode Complete -Quiet `
        -Report \\fs01\reports\$env:COMPUTERNAME.html `
        -Json \\fs01\reports\$env:COMPUTERNAME.json
#>
[CmdletBinding()]
param(
    [ValidateSet('Quick', 'Complete')] [string] $ScanMode = 'Quick',
    [string] $Report,
    [string] $Json,
    [string] $Csv,
    [string] $TuningScript,
    [string[]] $CatalogFile,
    [switch] $Quiet,
    [switch] $PlanOnly
)

$ErrorActionPreference = 'Stop'

$modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'src\ResourceMonitor\ResourceMonitor.psd1'
if (-not (Test-Path -LiteralPath $modulePath)) { $modulePath = 'ResourceMonitor' }
Import-Module $modulePath -Force

try {
    $arguments = @{ ScanMode = $ScanMode }
    if ($CatalogFile) { $arguments['CatalogFile'] = $CatalogFile }
    if ($Quiet) { $arguments['Quiet'] = $true }

    $result = Invoke-ResourceAnalysis @arguments

    if (-not $Quiet) {
        if ($PlanOnly) {
            Write-Host $result.Plan.NarrativeText
            Write-Host ''
            foreach ($action in $result.Plan.Actions) {
                $colour = switch ($action.Impact) {
                    'High'   { 'Red' }
                    'Medium' { 'Yellow' }
                    'Low'    { 'Green' }
                    default  { 'Gray' }
                }
                Write-Host ("[{0}] {1}" -f $action.Impact.ToUpperInvariant(), $action.Title) -ForegroundColor $colour
                Write-Host ("        {0}" -f $action.Recommendation) -ForegroundColor DarkGray
            }
        } else {
            Write-Host (& (Get-Module ResourceMonitor) { New-RmoTextReport -Result $args[0] -Width 100 } $result)
        }
    }

    if ($Report) { Export-RmoReport -Result $result -Path $Report -Format Html }
    if ($Json) { Export-RmoReport -Result $result -Path $Json -Format Json }
    if ($Csv) { Export-RmoReport -Result $result -Path $Csv -Format Csv }
    if ($TuningScript) { New-RmoRemediationScript -Result $result -Path $TuningScript }

    if ($result.Plan.HighImpactCount -gt 0) { exit 1 }
    exit 0
} catch {
    Write-Error $_
    exit 2
}
