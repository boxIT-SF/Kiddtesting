function Export-RmoReport {
    <#
        .SYNOPSIS
            Writes the analysis to a file.

        .DESCRIPTION
            Four formats, for four audiences:

              Html  a self-contained report to attach to a ticket or send to somebody.
              Text  the same content as plain text, for a ticket note or an email body.
              Json  the whole result object, for a monitoring platform or a fleet-wide roll-up.
              Csv   one row per process, for a spreadsheet.

            The format is taken from the file extension unless it is given explicitly.

        .PARAMETER Result
            A result from Invoke-ResourceAnalysis.

        .PARAMETER Path
            Where to write it. The directory is created if it does not exist.

        .PARAMETER Format
            Html, Text, Json or Csv. Inferred from the extension when omitted.

        .PARAMETER PassThru
            Return the path that was written.

        .EXAMPLE
            Invoke-ResourceAnalysis | Export-RmoReport -Path .\report.html

        .EXAMPLE
            Export-RmoReport -Result $result -Path \\fs01\reports\$env:COMPUTERNAME.json
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)] [psobject] $Result,
        [Parameter(Mandatory, Position = 0)] [string] $Path,
        [ValidateSet('Html', 'Text', 'Json', 'Csv')] [string] $Format,
        [switch] $PassThru
    )

    process {
        if (-not $Format) {
            $Format = switch ([System.IO.Path]::GetExtension($Path).ToLowerInvariant()) {
                '.html' { 'Html' }
                '.htm'  { 'Html' }
                '.json' { 'Json' }
                '.csv'  { 'Csv' }
                '.txt'  { 'Text' }
                '.log'  { 'Text' }
                default { 'Html' }
            }
        }

        $directory = Split-Path -Path $Path -Parent
        if ($directory -and -not (Test-Path -LiteralPath $directory)) {
            $null = New-Item -ItemType Directory -Path $directory -Force
        }

        switch ($Format) {
            'Html' { New-RmoHtmlReport -Result $Result | Set-Content -LiteralPath $Path -Encoding UTF8 }
            'Text' { New-RmoTextReport -Result $Result | Set-Content -LiteralPath $Path -Encoding UTF8 }
            'Json' {
                # The raw CIM instance on each process is a live object graph; serialising it
                # produces megabytes of nothing useful and can fail outright.
                $export = [pscustomobject]@{
                    ComputerName    = $Result.System.ComputerName
                    ScanMode        = $Result.ScanMode
                    ScanStartedUtc  = $Result.ScanStartedUtc
                    DurationSeconds = $Result.DurationSeconds
                    Elevated        = $Result.Elevated
                    Cancelled       = $Result.Cancelled
                    System          = $Result.System
                    Pressure        = $Result.Pressure
                    Plan            = $Result.Plan
                    Families        = $Result.Hogs.Families | Select-Object -Property * -ExcludeProperty Members, TopMembers, ProcessNames
                    TopProcesses    = $Result.Hogs.TopMemory | Select-Object -Property * -ExcludeProperty CimInstance
                    StartupItems    = $Result.StartupItems
                    Findings        = $Result.Findings
                    ScanErrors      = $Result.ScanErrors
                }
                $export | ConvertTo-Json -Depth 8 -Compress:$false | Set-Content -LiteralPath $Path -Encoding UTF8
            }
            'Csv' {
                $Result.Hogs.Processes |
                    Select-Object ProcessId, Name, @{ n = 'WhatItIs'; e = { $_.Identity.Name } },
                        @{ n = 'Manufacturer'; e = { $_.Identity.Vendor } },
                        @{ n = 'Class'; e = { $_.Identity.Class } },
                        @{ n = 'CpuPercent'; e = { $_.CpuPercent } },
                        @{ n = 'MemoryBytes'; e = { $_.MemoryBytes } },
                        @{ n = 'MemoryMetric'; e = { $_.MemoryMetric } },
                        @{ n = 'DiskBytesPerSecond'; e = { $_.IoBytesPerSecond } },
                        HandleCount, ThreadCount, SessionId, Owner,
                        @{ n = 'Services'; e = { $_.ServiceText } },
                        ExecutablePath, CommandLine |
                    Sort-Object MemoryBytes -Descending |
                    Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
            }
        }

        Write-Verbose "Wrote $Format report to $Path"
        if ($PassThru) { $Path }
    }
}
