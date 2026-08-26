<#
.SYNOPSIS
    Opens the Resource Monitor desktop window.

.DESCRIPTION
    A thin launcher so the window can be started without knowing the module layout. Pair it with
    Start-ResourceMonitor.cmd for a double-clickable shortcut.

.PARAMETER ScanMode
    Pre-select Quick or Complete. Defaults to Quick.

.PARAMETER StartScan
    Begin scanning as soon as the window opens.

.EXAMPLE
    .\Start-ResourceMonitor.ps1

.EXAMPLE
    .\Start-ResourceMonitor.ps1 -ScanMode Complete -StartScan
#>
[CmdletBinding()]
param(
    [ValidateSet('Quick', 'Complete')] [string] $ScanMode = 'Quick',
    [switch] $StartScan
)

$ErrorActionPreference = 'Stop'

$modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'src\ResourceMonitor\ResourceMonitor.psd1'
if (-not (Test-Path -LiteralPath $modulePath)) { $modulePath = 'ResourceMonitor' }
Import-Module $modulePath -Force

Show-ResourceMonitor -ScanMode $ScanMode -StartScan:$StartScan
