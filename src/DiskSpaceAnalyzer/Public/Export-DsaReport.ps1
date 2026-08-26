function Export-DsaReport {
    <#
        .SYNOPSIS
            Writes the analysis to disk as HTML, text, JSON or CSV.

        .DESCRIPTION
            HTML is the format to hand to a client or attach to a ticket: one self-contained
            file, no external assets, prints cleanly.

            Text suits an RMM output pane or a ticket note. JSON is the full result object for
            a monitoring pipeline. CSV writes one file per table, named from the base path,
            because the analysis is not a single rectangle.

        .PARAMETER Result
            Output of Invoke-DiskSpaceAnalysis.

        .PARAMETER Path
            Destination file. For CSV this is the base name; '<base>.actions.csv',
            '<base>.categories.csv', '<base>.oldest.csv', '<base>.largest.csv' and
            '<base>.directories.csv' are written alongside it.

        .PARAMETER Format
            Html (default), Text, Json or Csv. When omitted it is inferred from the extension.

        .PARAMETER MaxRows
            Row cap for the long tables in the HTML and text reports.

        .PARAMETER PassThru
            Emit the written file(s) as FileInfo.

        .EXAMPLE
            Invoke-DiskSpaceAnalysis -Path C:\ | Export-DsaReport -Path C:\Temp\disk.html

        .EXAMPLE
            Export-DsaReport -Result $result -Path \\share\reports\$env:COMPUTERNAME.json -Format Json
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(Mandatory, ValueFromPipeline, Position = 0)]
        [psobject] $Result,

        [Parameter(Mandatory, Position = 1)]
        [string] $Path,

        [ValidateSet('Html', 'Text', 'Json', 'Csv')]
        [string] $Format,

        [int] $MaxRows = 25,

        [switch] $PassThru
    )

    process {
        if (-not $Format) {
            $Format = switch ([System.IO.Path]::GetExtension($Path).ToLowerInvariant()) {
                '.htm'  { 'Html' }
                '.html' { 'Html' }
                '.txt'  { 'Text' }
                '.log'  { 'Text' }
                '.json' { 'Json' }
                '.csv'  { 'Csv' }
                default { 'Html' }
            }
        }

        $directory = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($Path))
        if ($directory -and -not (Test-Path -LiteralPath $directory)) {
            if ($PSCmdlet.ShouldProcess($directory, 'Create directory')) {
                $null = New-Item -ItemType Directory -Path $directory -Force
            }
        }

        $written = New-Object System.Collections.Generic.List[string]

        switch ($Format) {
            'Html' {
                if ($PSCmdlet.ShouldProcess($Path, 'Write HTML report')) {
                    $html = New-DsaHtmlReport -Result $Result -MaxRows $MaxRows
                    Set-Content -LiteralPath $Path -Value $html -Encoding UTF8
                    $written.Add($Path)
                }
            }
            'Text' {
                if ($PSCmdlet.ShouldProcess($Path, 'Write text report')) {
                    $text = New-DsaTextReport -Result $Result -MaxRows $MaxRows
                    Set-Content -LiteralPath $Path -Value $text -Encoding UTF8
                    $written.Add($Path)
                }
            }
            'Json' {
                if ($PSCmdlet.ShouldProcess($Path, 'Write JSON report')) {
                    # Depth 8 reaches the example files nested under each category.
                    $json = $Result | ConvertTo-Json -Depth 8
                    Set-Content -LiteralPath $Path -Value $json -Encoding UTF8
                    $written.Add($Path)
                }
            }
            'Csv' {
                $base = [System.IO.Path]::Combine(
                    [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($Path)),
                    [System.IO.Path]::GetFileNameWithoutExtension($Path))

                $tables = [ordered]@{
                    'actions'     = $Result.Plan.AllCandidates | Select-Object Safety, Confidence, Title, Category, SizeBytes, SizeText, FileCount, Selected, RequiresApproval, Method, WhatItIs, Reason, Remediation, Command
                    'escalations' = $Result.Plan.Escalations | Select-Object Safety, Title, Category, SizeBytes, SizeText, FileCount, WhatItIs, Reason, Remediation, Command
                    'categories'  = $Result.Summary.Categories | Select-Object Safety, Name, Category, Bytes, SizeText, EligibleBytes, EligibleSizeText, FileCount, OldestAgeDays, PercentOfScan, WhatItIs, Reason, Remediation
                    'oldest'      = $Result.Summary.OldestFiles | Select-Object AgeDays, IdleDays, Length, SizeText, FullName, Category, Safety, SafeToDelete, WhatItIs
                    'largest'     = $Result.Summary.LargestFiles | Select-Object Length, SizeText, AgeDays, FullName, Category, Safety
                    'directories' = $Result.Summary.TopDirectories | Select-Object Path, Bytes, SizeText, FileCount, PercentOfScan
                }

                foreach ($name in $tables.Keys) {
                    $target = "$base.$name.csv"
                    if ($PSCmdlet.ShouldProcess($target, 'Write CSV')) {
                        $rows = @($tables[$name])
                        if ($rows.Count -eq 0) {
                            Set-Content -LiteralPath $target -Value '' -Encoding UTF8
                        } else {
                            $rows | Export-Csv -LiteralPath $target -NoTypeInformation -Encoding UTF8
                        }
                        $written.Add($target)
                    }
                }
            }
        }

        if ($PassThru) {
            foreach ($file in $written) { Get-Item -LiteralPath $file }
        }
    }
}
