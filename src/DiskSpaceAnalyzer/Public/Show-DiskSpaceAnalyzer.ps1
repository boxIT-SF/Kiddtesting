function Show-DiskSpaceAnalyzer {
    <#
        .SYNOPSIS
            Opens the desktop UI for the analyser.

        .DESCRIPTION
            A WinForms front end over Invoke-DiskSpaceAnalysis. The scan runs in a background
            runspace so the window stays responsive and can be cancelled, and every table is
            colour-coded by whether the data behind it is safe to delete.

            Tabs:
              Summary        the plain-language recommendation and the capacity maths
              Plan           what to reclaim, safest first, with the reason for each
              Do not delete  the large data that needs a different approach, and what that is
              Oldest data    the oldest files on the volume, classified
              Largest files  the biggest files, classified
              Classification everything found, grouped by what it is
              Folders        where the space actually went

        .PARAMETER Path
            Pre-fill the path to scan. Defaults to the system drive.

        .PARAMETER HorizonMonths
            Pre-fill the headroom target. Defaults to 6.

        .EXAMPLE
            Show-DiskSpaceAnalyzer

        .EXAMPLE
            Show-DiskSpaceAnalyzer -Path D:\ -HorizonMonths 12
    #>
    [CmdletBinding()]
    param(
        [string] $Path,
        [ValidateRange(1, 120)] [int] $HorizonMonths = 6
    )

    if (-not (Test-DsaWindows)) {
        throw 'The desktop UI requires Windows. On other platforms use Invoke-DiskSpaceAnalysis and Export-DsaReport.'
    }

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    } catch {
        throw "Windows Forms is not available in this session: $($_.Exception.Message)"
    }

    [System.Windows.Forms.Application]::EnableVisualStyles()

    $modulePath = Join-Path $script:DsaModuleRoot 'DiskSpaceAnalyzer.psd1'
    if (-not $Path) { $Path = "$env:SystemDrive\" }

    $colors = @{
        Safe   = [System.Drawing.Color]::FromArgb(24, 110, 70)
        Review = [System.Drawing.Color]::FromArgb(150, 100, 0)
        Unsafe = [System.Drawing.Color]::FromArgb(165, 34, 34)
        Muted  = [System.Drawing.Color]::FromArgb(90, 96, 104)
    }

    #region Form scaffolding
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Disk Space Analyzer'
    $form.Size = New-Object System.Drawing.Size(1180, 780)
    $form.MinimumSize = New-Object System.Drawing.Size(920, 620)
    $form.StartPosition = 'CenterScreen'

    $controlPanel = New-Object System.Windows.Forms.Panel
    $controlPanel.Dock = 'Top'
    $controlPanel.Height = 92
    $controlPanel.Padding = New-Object System.Windows.Forms.Padding(10)
    $form.Controls.Add($controlPanel)

    function New-Label {
        param([string] $Text, [int] $X, [int] $Y, [int] $Width = 90)
        $label = New-Object System.Windows.Forms.Label
        $label.Text = $Text
        $label.Location = New-Object System.Drawing.Point($X, $Y)
        $label.Size = New-Object System.Drawing.Size($Width, 20)
        $label.TextAlign = 'MiddleLeft'
        $controlPanel.Controls.Add($label)
        $label
    }

    $null = New-Label -Text 'Scan location' -X 12 -Y 12 -Width 90

    $pathBox = New-Object System.Windows.Forms.TextBox
    $pathBox.Location = New-Object System.Drawing.Point(106, 11)
    $pathBox.Size = New-Object System.Drawing.Size(430, 22)
    $pathBox.Anchor = 'Top, Left, Right'
    $pathBox.Text = $Path
    $controlPanel.Controls.Add($pathBox)

    $browseButton = New-Object System.Windows.Forms.Button
    $browseButton.Text = 'Browse...'
    $browseButton.Location = New-Object System.Drawing.Point(542, 10)
    $browseButton.Size = New-Object System.Drawing.Size(80, 24)
    $browseButton.Anchor = 'Top, Right'
    $controlPanel.Controls.Add($browseButton)

    $null = New-Label -Text 'Volumes' -X 636 -Y 12 -Width 56
    $driveBox = New-Object System.Windows.Forms.ComboBox
    $driveBox.Location = New-Object System.Drawing.Point(694, 11)
    $driveBox.Size = New-Object System.Drawing.Size(230, 22)
    $driveBox.DropDownStyle = 'DropDownList'
    $driveBox.Anchor = 'Top, Right'
    $controlPanel.Controls.Add($driveBox)

    foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
        try {
            if (-not $drive.IsReady) { continue }
            if ($drive.DriveType -notin 'Fixed', 'Network', 'Removable') { continue }
            $label = '{0}  {1} free of {2}' -f $drive.Name, (Format-DsaBytes $drive.AvailableFreeSpace), (Format-DsaBytes $drive.TotalSize)
            $null = $driveBox.Items.Add($label)
        } catch {
            Write-Verbose "Skipping drive $($drive.Name): $($_.Exception.Message)"
        }
    }

    $null = New-Label -Text 'Months of headroom' -X 12 -Y 46 -Width 122
    $horizonBox = New-Object System.Windows.Forms.NumericUpDown
    $horizonBox.Location = New-Object System.Drawing.Point(136, 45)
    $horizonBox.Size = New-Object System.Drawing.Size(56, 22)
    $horizonBox.Minimum = 1
    $horizonBox.Maximum = 120
    $horizonBox.Value = $HorizonMonths
    $controlPanel.Controls.Add($horizonBox)

    $null = New-Label -Text 'Ignore files under' -X 208 -Y 46 -Width 110
    $minSizeBox = New-Object System.Windows.Forms.ComboBox
    $minSizeBox.Location = New-Object System.Drawing.Point(320, 45)
    $minSizeBox.Size = New-Object System.Drawing.Size(110, 22)
    $minSizeBox.DropDownStyle = 'DropDownList'
    $null = $minSizeBox.Items.AddRange(@('Nothing', '64 KB', '1 MB', '10 MB', '100 MB'))
    $minSizeBox.SelectedIndex = 2
    $controlPanel.Controls.Add($minSizeBox)

    $deepBox = New-Object System.Windows.Forms.CheckBox
    $deepBox.Text = 'Deep system probe (DISM, slow, needs admin)'
    $deepBox.Location = New-Object System.Drawing.Point(446, 45)
    $deepBox.Size = New-Object System.Drawing.Size(300, 22)
    $controlPanel.Controls.Add($deepBox)

    $scanButton = New-Object System.Windows.Forms.Button
    $scanButton.Text = 'Scan'
    $scanButton.Location = New-Object System.Drawing.Point(760, 43)
    $scanButton.Size = New-Object System.Drawing.Size(78, 26)
    $scanButton.Anchor = 'Top, Right'
    $controlPanel.Controls.Add($scanButton)

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = 'Cancel'
    $cancelButton.Location = New-Object System.Drawing.Point(846, 43)
    $cancelButton.Size = New-Object System.Drawing.Size(78, 26)
    $cancelButton.Anchor = 'Top, Right'
    $cancelButton.Enabled = $false
    $controlPanel.Controls.Add($cancelButton)

    $statusStrip = New-Object System.Windows.Forms.StatusStrip
    $statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
    $statusLabel.Text = 'Ready.'
    $statusLabel.Spring = $true
    $statusLabel.TextAlign = 'MiddleLeft'
    $progressBar = New-Object System.Windows.Forms.ToolStripProgressBar
    $progressBar.Style = 'Marquee'
    $progressBar.Visible = $false
    $null = $statusStrip.Items.Add($statusLabel)
    $null = $statusStrip.Items.Add($progressBar)
    $form.Controls.Add($statusStrip)

    $buttonPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $buttonPanel.Dock = 'Bottom'
    $buttonPanel.Height = 44
    $buttonPanel.FlowDirection = 'RightToLeft'
    $buttonPanel.Padding = New-Object System.Windows.Forms.Padding(10, 8, 10, 8)
    $form.Controls.Add($buttonPanel)

    function New-ActionButton {
        param([string] $Text, [int] $Width = 150)
        $button = New-Object System.Windows.Forms.Button
        $button.Text = $Text
        $button.Size = New-Object System.Drawing.Size($Width, 26)
        $button.Enabled = $false
        $buttonPanel.Controls.Add($button)
        $button
    }

    $htmlButton = New-ActionButton -Text 'Save HTML report...'
    $scriptButton = New-ActionButton -Text 'Save cleanup script...'
    $jsonButton = New-ActionButton -Text 'Save JSON...'
    $copyButton = New-ActionButton -Text 'Copy summary'

    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Dock = 'Fill'
    $form.Controls.Add($tabs)
    $tabs.BringToFront()
    #endregion

    #region Tab helpers
    function New-Tab {
        param([string] $Text)
        $page = New-Object System.Windows.Forms.TabPage
        $page.Text = $Text
        $page.Padding = New-Object System.Windows.Forms.Padding(8)
        $tabs.TabPages.Add($page)
        $page
    }

    function New-GridTab {
        <#
            A list on top and a details pane underneath, so a row's full explanation is
            readable without squeezing it into a column.
        #>
        param([string] $Text, [object[]] $Column, [switch] $WithDetails)

        $page = New-Tab -Text $Text
        $split = New-Object System.Windows.Forms.SplitContainer
        $split.Dock = 'Fill'
        $split.Orientation = 'Horizontal'
        $split.Panel1MinSize = 120
        $split.Panel2MinSize = 80
        $page.Controls.Add($split)

        $list = New-Object System.Windows.Forms.ListView
        $list.Dock = 'Fill'
        $list.View = 'Details'
        $list.FullRowSelect = $true
        $list.GridLines = $true
        $list.MultiSelect = $false
        $list.HideSelection = $false
        foreach ($column in $Column) {
            $null = $list.Columns.Add($column.Name, $column.Width)
        }
        $split.Panel1.Controls.Add($list)

        $details = New-Object System.Windows.Forms.TextBox
        $details.Dock = 'Fill'
        $details.Multiline = $true
        $details.ReadOnly = $true
        $details.ScrollBars = 'Vertical'
        $details.BackColor = [System.Drawing.Color]::White
        $details.Font = New-Object System.Drawing.Font('Segoe UI', 9)
        if ($WithDetails) {
            $split.Panel2.Controls.Add($details)
        } else {
            $split.Panel2Collapsed = $true
        }

        # The list carries its own details pane, so event handlers need no closure to find it.
        $list.Tag = $details

        [pscustomobject]@{ Page = $page; List = $list; Details = $details; Split = $split; HasDetails = [bool] $WithDetails }
    }

    $summaryPage = New-Tab -Text 'Summary'
    $summaryBox = New-Object System.Windows.Forms.TextBox
    $summaryBox.Dock = 'Fill'
    $summaryBox.Multiline = $true
    $summaryBox.ReadOnly = $true
    $summaryBox.ScrollBars = 'Both'
    $summaryBox.WordWrap = $false
    $summaryBox.Font = New-Object System.Drawing.Font('Consolas', 9)
    $summaryBox.Text = 'Choose a location and press Scan.'
    $summaryPage.Controls.Add($summaryBox)

    $planTab = New-GridTab -Text 'Plan' -WithDetails -Column @(
        @{ Name = 'Safety'; Width = 70 }
        @{ Name = 'In plan'; Width = 60 }
        @{ Name = 'Action'; Width = 300 }
        @{ Name = 'Reclaims'; Width = 100 }
        @{ Name = 'Files'; Width = 80 }
        @{ Name = 'Confidence'; Width = 90 }
        @{ Name = 'Method'; Width = 80 }
    )
    $escalationTab = New-GridTab -Text 'Do not delete' -WithDetails -Column @(
        @{ Name = 'Safety'; Width = 70 }
        @{ Name = 'What it is'; Width = 320 }
        @{ Name = 'Size'; Width = 100 }
        @{ Name = 'Category'; Width = 160 }
    )
    $oldestTab = New-GridTab -Text 'Oldest data' -WithDetails -Column @(
        @{ Name = 'Age (days)'; Width = 80 }
        @{ Name = 'Size'; Width = 90 }
        @{ Name = 'Safe to delete'; Width = 110 }
        @{ Name = 'Classification'; Width = 230 }
        @{ Name = 'Path'; Width = 560 }
    )
    $largestTab = New-GridTab -Text 'Largest files' -Column @(
        @{ Name = 'Size'; Width = 90 }
        @{ Name = 'Age (days)'; Width = 80 }
        @{ Name = 'Safety'; Width = 70 }
        @{ Name = 'Classification'; Width = 230 }
        @{ Name = 'Path'; Width = 600 }
    )
    $categoryTab = New-GridTab -Text 'Classification' -WithDetails -Column @(
        @{ Name = 'Safety'; Width = 70 }
        @{ Name = 'What it is'; Width = 300 }
        @{ Name = 'Total'; Width = 100 }
        @{ Name = 'Reclaimable'; Width = 100 }
        @{ Name = 'Files'; Width = 90 }
        @{ Name = 'Oldest (days)'; Width = 100 }
    )
    $folderTab = New-GridTab -Text 'Folders' -Column @(
        @{ Name = 'Size'; Width = 100 }
        @{ Name = 'Share'; Width = 70 }
        @{ Name = 'Files'; Width = 90 }
        @{ Name = 'Folder'; Width = 700 }
    )
    #endregion

    #region State
    $state = [pscustomobject]@{
        Result   = $null
        Status   = [hashtable]::Synchronized(@{})
        Cancel   = [hashtable]::Synchronized(@{ Cancelled = $false })
        Shell    = $null
        Handle   = $null
    }

    function Set-Status { param([string] $Text) $statusLabel.Text = $Text }

    function Add-Row {
        param(
            [System.Windows.Forms.ListView] $List,
            [string[]] $Value,
            [string] $Safety,
            [psobject] $Tag
        )
        $item = New-Object System.Windows.Forms.ListViewItem($Value[0])
        for ($i = 1; $i -lt $Value.Count; $i++) { $null = $item.SubItems.Add($Value[$i]) }
        if ($Safety -and $colors.ContainsKey($Safety)) { $item.ForeColor = $colors[$Safety] }
        $item.Tag = $Tag
        $null = $List.Items.Add($item)
    }

    function Show-Detail {
        param([System.Windows.Forms.ListView] $List, [System.Windows.Forms.TextBox] $Box)

        if ($List.SelectedItems.Count -eq 0) { $Box.Text = ''; return }
        $tag = $List.SelectedItems[0].Tag
        if (-not $tag) { $Box.Text = ''; return }

        $lines = New-Object System.Collections.Generic.List[string]
        foreach ($property in 'Title', 'Name', 'FullName') {
            if ($tag.PSObject.Properties[$property] -and $tag.$property) {
                $lines.Add([string] $tag.$property); break
            }
        }
        foreach ($pair in @(
            @('What it is',   'WhatItIs'),
            @('Why',          'Reason'),
            @('What to do',   'Remediation'),
            @('Command',      'Command'),
            @('Method',       'Method'),
            @('Confidence',   'Confidence'))) {
            $property = $pair[1]
            if ($tag.PSObject.Properties[$property] -and $tag.$property) {
                $lines.Add('')
                $lines.Add("$($pair[0]): $($tag.$property)")
            }
        }
        if ($tag.PSObject.Properties['Examples'] -and $tag.Examples -and $tag.Examples.Count -gt 0) {
            $lines.Add('')
            $lines.Add('Largest examples:')
            foreach ($example in $tag.Examples) {
                $lines.Add("  $(Format-DsaBytes $example.Length)  $($example.FullName)")
            }
        }
        $Box.Lines = $lines.ToArray()
    }

    function Clear-Results {
        foreach ($tab in @($planTab, $escalationTab, $oldestTab, $largestTab, $categoryTab, $folderTab)) {
            $tab.List.Items.Clear()
            $tab.Details.Text = ''
        }
    }

    function Publish-Result {
        param([psobject] $Result)

        $state.Result = $Result
        Clear-Results

        $summaryBox.Text = (New-DsaTextReport -Result $Result -Width 118) -replace "`r?`n", "`r`n"
        $summaryBox.Select(0, 0)

        foreach ($action in $Result.Plan.AllCandidates) {
            Add-Row -List $planTab.List -Safety $action.Safety -Tag $action -Value @(
                $action.Safety
                $(if ($action.Selected) { 'Yes' } else { 'No' })
                $action.Title
                $action.SizeText
                $(if ($null -ne $action.FileCount) { '{0:N0}' -f $action.FileCount } else { '' })
                $action.Confidence
                $action.Method
            )
        }
        foreach ($item in $Result.Plan.Escalations) {
            Add-Row -List $escalationTab.List -Safety $item.Safety -Tag $item -Value @(
                $item.Safety, $item.Title, $item.SizeText, $item.Category
            )
        }
        foreach ($file in $Result.Summary.OldestFiles) {
            $verdict = switch ($file.Safety) {
                'Safe'   { 'Yes' }
                'Review' { 'Needs a decision' }
                default  { 'No' }
            }
            Add-Row -List $oldestTab.List -Safety $file.Safety -Tag $file -Value @(
                ('{0:N0}' -f $file.AgeDays), $file.SizeText, $verdict, $file.Category, $file.FullName
            )
        }
        foreach ($file in $Result.Summary.LargestFiles) {
            Add-Row -List $largestTab.List -Safety $file.Safety -Tag $file -Value @(
                $file.SizeText, ('{0:N0}' -f $file.AgeDays), $file.Safety, $file.Category, $file.FullName
            )
        }
        foreach ($category in $Result.Summary.Categories) {
            Add-Row -List $categoryTab.List -Safety $category.Safety -Tag $category -Value @(
                $category.Safety
                $category.Name
                $category.SizeText
                $category.EligibleSizeText
                ('{0:N0}' -f $category.FileCount)
                $(if ($null -ne $category.OldestAgeDays) { '{0:N0}' -f $category.OldestAgeDays } else { '' })
            )
        }
        foreach ($directory in $Result.Summary.TopDirectories) {
            Add-Row -List $folderTab.List -Tag $directory -Value @(
                $directory.SizeText, "$($directory.PercentOfScan)%", ('{0:N0}' -f $directory.FileCount), $directory.Path
            )
        }

        foreach ($button in $htmlButton, $scriptButton, $jsonButton, $copyButton) { $button.Enabled = $true }

        $plan = $Result.Plan
        $verdict = if ($plan.DeficitBytes -le 0) {
            "Already has $($plan.HorizonMonths) months of headroom."
        } elseif ($plan.Achievable) {
            "Reclaim $($plan.PlannedReclaimText) to cover $($plan.HorizonMonths) months."
        } else {
            "Cleanup alone falls $($plan.ShortfallText) short of $($plan.HorizonMonths) months."
        }
        Set-Status "$('{0:N0}' -f $Result.Summary.FileCount) files, $($Result.Summary.TotalSizeText) scanned in $($Result.DurationSeconds)s. $verdict"
    }
    #endregion

    #region Events
    $browseButton.Add_Click({
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = 'Choose the volume or folder to analyse'
        if ($dialog.ShowDialog() -eq 'OK') { $pathBox.Text = $dialog.SelectedPath }
    })

    $driveBox.Add_SelectedIndexChanged({
        if ($driveBox.SelectedItem) {
            $pathBox.Text = ([string] $driveBox.SelectedItem).Split(' ')[0]
        }
    })

    foreach ($tab in @($planTab, $escalationTab, $oldestTab, $categoryTab)) {
        $tab.List.Add_SelectedIndexChanged({ Show-Detail -List $this -Box $this.Tag })
    }

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 400

    $timer.Add_Tick({
        if ($state.Handle -and $state.Handle.IsCompleted) {
            $timer.Stop()
            $progressBar.Visible = $false
            $scanButton.Enabled = $true
            $cancelButton.Enabled = $false
            try {
                $output = $state.Shell.EndInvoke($state.Handle)
                $result = @($output) | Where-Object { $_ -and $_.PSObject.Properties['Plan'] } | Select-Object -First 1
                if ($result) {
                    Publish-Result -Result $result
                } else {
                    Set-Status 'The scan returned no result.'
                }
            } catch {
                Set-Status "Scan failed: $($_.Exception.Message)"
                [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Scan failed',
                    'OK', 'Error') | Out-Null
            } finally {
                $state.Shell.Dispose()
                $state.Shell = $null
                $state.Handle = $null
            }
            return
        }

        $phase = [string] $state.Status['Phase']
        $files = $state.Status['FilesScanned']
        $bytes = $state.Status['BytesScanned']
        $current = [string] $state.Status['CurrentPath']
        if ($files) {
            Set-Status ("$phase - {0:N0} files, {1} - {2}" -f $files, (Format-DsaBytes $bytes), $current)
        } elseif ($phase) {
            Set-Status $phase
        }
    })

    $scanButton.Add_Click({
        if ($state.Shell) { return }

        $target = $pathBox.Text.Trim()
        if (-not $target -or -not (Test-Path -LiteralPath $target)) {
            [System.Windows.Forms.MessageBox]::Show("'$target' does not exist.", 'Disk Space Analyzer',
                'OK', 'Warning') | Out-Null
            return
        }

        $minSize = switch ($minSizeBox.SelectedItem) {
            'Nothing'  { 0L }
            '64 KB'    { 64KB }
            '1 MB'     { 1MB }
            '10 MB'    { 10MB }
            '100 MB'   { 100MB }
            default    { 1MB }
        }

        $state.Status.Clear()
        $state.Cancel['Cancelled'] = $false
        $state.Status['Phase'] = 'Starting'

        $scanScript = {
            param($ModulePath, $Arguments, $Status, $Cancel)
            Import-Module $ModulePath -Force
            Invoke-DiskSpaceAnalysis @Arguments -StatusSink $Status -CancellationSink $Cancel -Quiet
        }

        $arguments = @{
            Path             = $target
            HorizonMonths    = [int] $horizonBox.Value
            MinFileSizeBytes = $minSize
            DeepSystemProbe  = [bool] $deepBox.Checked
        }

        $state.Shell = [powershell]::Create()
        $null = $state.Shell.AddScript($scanScript).AddArgument($modulePath).AddArgument($arguments).
            AddArgument($state.Status).AddArgument($state.Cancel)
        $state.Handle = $state.Shell.BeginInvoke()

        $scanButton.Enabled = $false
        $cancelButton.Enabled = $true
        $progressBar.Visible = $true
        foreach ($button in $htmlButton, $scriptButton, $jsonButton, $copyButton) { $button.Enabled = $false }
        Set-Status 'Scanning...'
        $timer.Start()
    })

    $cancelButton.Add_Click({
        $state.Cancel['Cancelled'] = $true
        $cancelButton.Enabled = $false
        Set-Status 'Cancelling - finishing the current folder...'
    })

    function Save-As {
        param([string] $Filter, [string] $DefaultName, [scriptblock] $Action)

        $dialog = New-Object System.Windows.Forms.SaveFileDialog
        $dialog.Filter = $Filter
        $dialog.FileName = $DefaultName
        if ($dialog.ShowDialog() -ne 'OK') { return }
        try {
            & $Action $dialog.FileName
            Set-Status "Saved $($dialog.FileName)"
        } catch {
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Save failed', 'OK', 'Error') | Out-Null
        }
    }

    $stamp = (Get-Date).ToString('yyyyMMdd')

    $htmlButton.Add_Click({
        Save-As -Filter 'HTML report (*.html)|*.html' -DefaultName "disk-$($env:COMPUTERNAME)-$stamp.html" -Action {
            param($file)
            Export-DsaReport -Result $state.Result -Path $file -Format Html
            Start-Process $file
        }
    })
    $jsonButton.Add_Click({
        Save-As -Filter 'JSON (*.json)|*.json' -DefaultName "disk-$($env:COMPUTERNAME)-$stamp.json" -Action {
            param($file)
            Export-DsaReport -Result $state.Result -Path $file -Format Json
        }
    })
    $scriptButton.Add_Click({
        Save-As -Filter 'PowerShell script (*.ps1)|*.ps1' -DefaultName "cleanup-$($env:COMPUTERNAME)-$stamp.ps1" -Action {
            param($file)
            New-DsaRemediationScript -Result $state.Result -Path $file
            [System.Windows.Forms.MessageBox]::Show(
                "Saved. The script does nothing until it is run with -Execute; run it once without to see what it would remove.",
                'Cleanup script', 'OK', 'Information') | Out-Null
        }
    })
    $copyButton.Add_Click({
        [System.Windows.Forms.Clipboard]::SetText($summaryBox.Text)
        Set-Status 'Summary copied to the clipboard.'
    })

    $form.Add_FormClosing({
        if ($state.Shell) {
            $state.Cancel['Cancelled'] = $true
            try { $state.Shell.Stop() } catch { }
            try { $state.Shell.Dispose() } catch { }
        }
        $timer.Stop()
        $timer.Dispose()
    })
    #endregion

    $form.Add_Shown({
        # SplitterDistance can only be set once the container has its final size; doing it at
        # construction time throws on a control that is still 150 pixels tall.
        foreach ($tab in @($planTab, $escalationTab, $oldestTab, $largestTab, $categoryTab, $folderTab)) {
            if (-not $tab.HasDetails) { continue }
            try {
                $tab.Split.SplitterDistance = [int] ($tab.Split.Height * 0.62)
            } catch {
                Write-Verbose "Could not position splitter on '$($tab.Page.Text)': $($_.Exception.Message)"
            }
        }
    })

    $null = $form.ShowDialog()
    $form.Dispose()
}
