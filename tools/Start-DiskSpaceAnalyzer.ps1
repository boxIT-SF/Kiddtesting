<#
.SYNOPSIS
    Opens the Disk Space Analyzer desktop window.

.DESCRIPTION
    A thin launcher so the UI can be started without knowing the module layout. Pair it with
    Start-DiskSpaceAnalyzer.cmd for a double-clickable shortcut.

.PARAMETER Path
    Pre-fill the location to scan. Defaults to the system drive.

.PARAMETER Months
    Pre-fill the headroom target. Defaults to 6.

.EXAMPLE
    .\Start-DiskSpaceAnalyzer.ps1 -Path D:\
#>
[CmdletBinding()]
param(
    [string] $Path,
    [ValidateRange(1, 120)] [int] $Months = 6
)

$ErrorActionPreference = 'Stop'

$modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'src\DiskSpaceAnalyzer\DiskSpaceAnalyzer.psd1'
if (-not (Test-Path -LiteralPath $modulePath)) { $modulePath = 'DiskSpaceAnalyzer' }
Import-Module $modulePath -Force

$uiArgs = @{ HorizonMonths = $Months }
if ($Path) { $uiArgs['Path'] = $Path }

Show-DiskSpaceAnalyzer @uiArgs
