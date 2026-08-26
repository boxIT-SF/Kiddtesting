<#
    A minimal assertion harness.

    Pester would be the usual choice, but this tool is meant to be dropped onto a locked-down
    Windows server and verified there, where installing a module from the gallery is often not
    an option. This has no dependencies, runs on Windows PowerShell 5.1 and PowerShell 7, and
    exits non-zero when anything fails.
#>

$script:DsaTestState = [pscustomobject]@{
    Suite    = ''
    Passed   = 0
    Failed   = 0
    Failures = New-Object System.Collections.Generic.List[string]
}

function Reset-TestState {
    $script:DsaTestState.Suite = ''
    $script:DsaTestState.Passed = 0
    $script:DsaTestState.Failed = 0
    $script:DsaTestState.Failures.Clear()
}

function Describe-Suite {
    param([Parameter(Mandatory)] [string] $Name, [Parameter(Mandatory)] [scriptblock] $Body)

    $script:DsaTestState.Suite = $Name
    Write-Host ''
    Write-Host $Name -ForegroundColor Cyan
    Write-Host ('-' * $Name.Length) -ForegroundColor DarkGray
    & $Body
}

function Test-Case {
    param([Parameter(Mandatory)] [string] $Name, [Parameter(Mandatory)] [scriptblock] $Body)

    try {
        & $Body
        $script:DsaTestState.Passed++
        Write-Host "  [pass] $Name" -ForegroundColor Green
    } catch {
        $script:DsaTestState.Failed++
        $message = "$($script:DsaTestState.Suite) / $Name : $($_.Exception.Message)"
        $script:DsaTestState.Failures.Add($message)
        Write-Host "  [FAIL] $Name" -ForegroundColor Red
        Write-Host "         $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Assert-Equal {
    param($Expected, $Actual, [string] $Because = '')

    if ($Expected -ne $Actual) {
        throw "expected [$Expected] but got [$Actual]. $Because".Trim()
    }
}

function Assert-True {
    param([bool] $Condition, [string] $Because = 'condition was false')
    if (-not $Condition) { throw $Because }
}

function Assert-False {
    param([bool] $Condition, [string] $Because = 'condition was true')
    if ($Condition) { throw $Because }
}

function Assert-Match {
    param([string] $Text, [string] $Pattern, [string] $Because = '')
    if ($Text -notmatch $Pattern) {
        throw "expected text to match /$Pattern/. $Because".Trim()
    }
}

function Assert-NotMatch {
    param([string] $Text, [string] $Pattern, [string] $Because = '')
    if ($Text -match $Pattern) {
        throw "expected text NOT to match /$Pattern/. $Because".Trim()
    }
}

function Assert-Throws {
    param([scriptblock] $Body, [string] $Pattern = '.', [string] $Because = '')

    try {
        & $Body
    } catch {
        if ($_.Exception.Message -notmatch $Pattern) {
            throw "threw, but message did not match /$Pattern/: $($_.Exception.Message)"
        }
        return
    }
    throw "expected a terminating error matching /$Pattern/ but none was thrown. $Because".Trim()
}

function Assert-Near {
    param([double] $Expected, [double] $Actual, [double] $Tolerance = 0.001, [string] $Because = '')
    if ([math]::Abs($Expected - $Actual) -gt $Tolerance) {
        throw "expected ~$Expected but got $Actual (tolerance $Tolerance). $Because".Trim()
    }
}

function Write-TestSummary {
    $state = $script:DsaTestState
    Write-Host ''
    Write-Host ('=' * 60) -ForegroundColor DarkGray
    if ($state.Failed -eq 0) {
        Write-Host "All $($state.Passed) tests passed." -ForegroundColor Green
    } else {
        Write-Host "$($state.Passed) passed, $($state.Failed) FAILED." -ForegroundColor Red
        foreach ($failure in $state.Failures) { Write-Host "  - $failure" -ForegroundColor Red }
    }
    Write-Host ('=' * 60) -ForegroundColor DarkGray
    $state.Failed
}
