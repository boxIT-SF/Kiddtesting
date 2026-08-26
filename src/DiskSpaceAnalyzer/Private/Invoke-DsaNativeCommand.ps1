function Invoke-DsaNativeCommand {
    <#
        .SYNOPSIS
            Runs a console tool and returns its output, never throwing.
        .NOTES
            The system probes call tools that may be missing, may need elevation, or may take
            a long time. A failure there must degrade the report, not end the analysis.
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory, Position = 0)] [string] $FilePath,
        [Parameter(Position = 1)] [string[]] $ArgumentList = @(),
        [int] $TimeoutSeconds = 180
    )

    $result = [pscustomobject]@{
        Succeeded = $false
        ExitCode  = $null
        Output    = @()
        Error     = ''
    }

    # Get-Command can return several matches for the same tool name; take the first.
    $command = Get-Command -Name $FilePath -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $command) {
        $result.Error = "'$FilePath' is not available on this machine."
        return $result
    }

    $stdout = [System.IO.Path]::GetTempFileName()
    $stderr = [System.IO.Path]::GetTempFileName()
    try {
        # Start-Process rejects an empty ArgumentList, so it is only supplied when populated.
        $startArgs = @{
            FilePath               = $command.Source
            NoNewWindow            = $true
            PassThru               = $true
            RedirectStandardOutput = $stdout
            RedirectStandardError  = $stderr
            ErrorAction            = 'Stop'
        }
        if ($ArgumentList -and $ArgumentList.Count -gt 0) { $startArgs['ArgumentList'] = $ArgumentList }

        $process = Start-Process @startArgs

        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill() } catch { }
            $result.Error = "'$FilePath' did not finish within $TimeoutSeconds seconds."
            return $result
        }

        # The timed overload can return before the redirected streams are flushed to disk.
        # The parameterless overload waits for that too.
        $process.WaitForExit()

        $result.ExitCode = $process.ExitCode
        $result.Output = @(Get-Content -LiteralPath $stdout -ErrorAction SilentlyContinue)
        $result.Succeeded = ($process.ExitCode -eq 0)
        if (-not $result.Succeeded) {
            $errorText = (Get-Content -LiteralPath $stderr -Raw -ErrorAction SilentlyContinue)
            $result.Error = if ($errorText) { $errorText.Trim() } else { "Exit code $($process.ExitCode)." }
        }
    } catch {
        $result.Error = $_.Exception.Message
    } finally {
        Remove-Item -LiteralPath $stdout, $stderr -Force -ErrorAction SilentlyContinue
    }

    $result
}

function Test-DsaElevated {
    <#
        .SYNOPSIS
            True when the session is running elevated. Several probes and most remediation
            commands need it, and saying so up front is better than a confusing failure.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if (-not (Test-DsaWindows)) { return $false }
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function ConvertFrom-DsaSizeText {
    <#
        .SYNOPSIS
            Parses the "12.34 GB" style sizes emitted by vssadmin and DISM into bytes.
    #>
    [CmdletBinding()]
    [OutputType([System.Nullable[long]])]
    param([Parameter(Position = 0)] [AllowEmptyString()] [string] $Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    # Both tools localise the thousands separator but not the unit suffix.
    $match = [regex]::Match($Text, '(?<value>[\d.,]+)\s*(?<unit>bytes|B|KB|MB|GB|TB|PB)', 'IgnoreCase')
    if (-not $match.Success) { return $null }

    $raw = $match.Groups['value'].Value
    $value = 0.0
    if (-not [double]::TryParse($raw, [ref] $value)) {
        if (-not [double]::TryParse($raw.Replace(',', ''), [ref] $value)) { return $null }
    }

    $multiplier = switch ($match.Groups['unit'].Value.ToUpperInvariant()) {
        'BYTES' { 1L }
        'B'     { 1L }
        'KB'    { 1KB }
        'MB'    { 1MB }
        'GB'    { 1GB }
        'TB'    { 1TB }
        'PB'    { 1PB }
        default { 1L }
    }
    [long] ($value * $multiplier)
}
