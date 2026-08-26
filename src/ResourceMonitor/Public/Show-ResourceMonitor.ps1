function Show-ResourceMonitor {
    <#
        .SYNOPSIS
            Opens the desktop window.

        .DESCRIPTION
            A WinForms front end over Invoke-ResourceAnalysis. The scan runs in a background
            runspace so the window stays responsive and can be cancelled, and every table names
            what each item is and who publishes it rather than only what it is consuming.

            Tabs:
              Verdict        which resource is the constraint, and what to do first
              Plan           every action, ordered, with the evidence behind it
              By product     consumers grouped by what they belong to
              Processes      every process, with its publisher and the services it hosts
              Starts itself  what launches at sign-in and what it is costing now
              The machine    processor, memory, disks, graphics, power and antivirus

        .PARAMETER ScanMode
            Pre-select Quick or Complete.

        .PARAMETER StartScan
            Begin scanning as soon as the window opens.

        .EXAMPLE
            Show-ResourceMonitor

        .EXAMPLE
            Show-ResourceMonitor -ScanMode Complete -StartScan
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Quick', 'Complete')] [string] $ScanMode = 'Quick',
        [switch] $StartScan
    )

    if (-not (Test-RmoWindows)) {
        throw 'The desktop window requires Windows. On other platforms use Invoke-ResourceAnalysis and Export-RmoReport.'
    }

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    } catch {
        throw "Windows Forms is not available in this session: $($_.Exception.Message)"
    }

    [System.Windows.Forms.Application]::EnableVisualStyles()
    $modulePath = Join-Path $script:RmoModuleRoot 'ResourceMonitor.psd1'

    $colors = @{
        High    = [System.Drawing.Color]::FromArgb(165, 34, 34)
        Medium  = [System.Drawing.Color]::FromArgb(150, 100, 0)
        Low     = [System.Drawing.Color]::FromArgb(24, 110, 70)
        Info    = [System.Drawing.Color]::FromArgb(90, 96, 104)
        Unwanted = [System.Drawing.Color]::FromArgb(165, 34, 34)
        Muted   = [System.Drawing.Color]::FromArgb(90, 96, 104)
    }

    #region Form scaffolding
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Resource Monitor'
    $form.Size = New-Object System.Drawing.Size(1200, 800)
    $form.MinimumSize = New-Object System.Drawing.Size(940, 640)
    $form.StartPosition = 'CenterScreen'

    $controlPanel = New-Object System.Windows.Forms.Panel
    $controlPanel.Dock = 'Top'
    $controlPanel.Height = 58
    $controlPanel.Padding = New-Object System.Windows.Forms.Padding(10)
    $form.Controls.Add($controlPanel)

    $quickButton = New-Object System.Windows.Forms.Button
    $quickButton.Text = 'Quick scan'
    $quickButton.Location = New-Object System.Drawing.Point(12, 14)
    $quickButton.Size = New-Object System.Drawing.Size(112, 28)
    $controlPanel.Controls.Add($quickButton)

    $completeButton = New-Object System.Windows.Forms.Button
    $completeButton.Text = 'Complete scan'
    $completeButton.Location = New-Object System.Drawing.Point(132, 14)
    $completeButton.Size = New-Object System.Drawing.Size(126, 28)
    $controlPanel.Controls.Add($completeButton)

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = 'Cancel'
    $cancelButton.Location = New-Object System.Drawing.Point(266, 14)
    $cancelButton.Size = New-Object System.Drawing.Size(78, 28)
    $cancelButton.Enabled = $false
    $controlPanel.Controls.Add($cancelButton)

    $modeLabel = New-Object System.Windows.Forms.Label
    $modeLabel.Location = New-Object System.Drawing.Point(360, 19)
    $modeLabel.Size = New-Object System.Drawing.Size(560, 20)
    $modeLabel.ForeColor = $colors.Muted
    $modeLabel.Text = 'Quick: one interval, about ten seconds.  Complete: four intervals, signatures, scheduled tasks and crash history.'
    $controlPanel.Controls.Add($modeLabel)

    $statusStrip = New-Object System.Windows.Forms.StatusStrip
    $statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
    $statusLabel.Text = 'Ready. Choose a scan.'
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
        param([string] $Text, [int] $Width = 152)
        $button = New-Object System.Windows.Forms.Button
        $button.Text = $Text
        $button.Size = New-Object System.Drawing.Size($Width, 26)
        $button.Enabled = $false
        $buttonPanel.Controls.Add($button)
        $button
    }

    $htmlButton = New-ActionButton -Text 'Save HTML report...'
    $scriptButton = New-ActionButton -Text 'Save tuning script...'
    $jsonButton = New-ActionButton -Text 'Save JSON...'
    $csvButton = New-ActionButton -Text 'Save process CSV...'
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
            A list on top and a details pane underneath. The explanations here are paragraphs -
            what the thing is, who makes it, why it matters - and they will not fit in a column.
        #>
        param([string] $Text, [object[]] $Column, [switch] $WithDetails)

        $page = New-Tab -Text $Text
        $split = New-Object System.Windows.Forms.SplitContainer
        $split.Dock = 'Fill'
        $split.Orientation = 'Horizontal'
        $split.Panel1MinSize = 120
        $split.Panel2MinSize = 90
        $page.Controls.Add($split)

        $list = New-Object System.Windows.Forms.ListView
        $list.Dock = 'Fill'
        $list.View = 'Details'
        $list.FullRowSelect = $true
        $list.GridLines = $true
        $list.MultiSelect = $false
        $list.HideSelection = $false
        foreach ($column in $Column) { $null = $list.Columns.Add($column.Name, $column.Width) }
        $split.Panel1.Controls.Add($list)

        $details = New-Object System.Windows.Forms.TextBox
        $details.Dock = 'Fill'
        $details.Multiline = $true
        $details.ReadOnly = $true
        $details.ScrollBars = 'Vertical'
        $details.BackColor = [System.Drawing.Color]::White
        $details.Font = New-Object System.Drawing.Font('Segoe UI', 9)
        if ($WithDetails) { $split.Panel2.Controls.Add($details) } else { $split.Panel2Collapsed = $true }

        # The list carries its own details pane, so event handlers need no closure to find it.
        $list.Tag = $details

        [pscustomobject]@{ Page = $page; List = $list; Details = $details; Split = $split; HasDetails = [bool] $WithDetails }
    }

    $verdictPage = New-Tab -Text 'Verdict'
    $verdictBox = New-Object System.Windows.Forms.TextBox
    $verdictBox.Dock = 'Fill'
    $verdictBox.Multiline = $true
    $verdictBox.ReadOnly = $true
    $verdictBox.ScrollBars = 'Both'
    $verdictBox.WordWrap = $false
    $verdictBox.Font = New-Object System.Drawing.Font('Consolas', 9)
    $verdictBox.Text = 'Press Quick scan to measure what this machine is doing.'
    $verdictPage.Controls.Add($verdictBox)

    $planTab = New-GridTab -Text 'Plan' -WithDetails -Column @(
        @{ Name = 'Impact'; Width = 60 }
        @{ Name = 'Action'; Width = 380 }
        @{ Name = 'Category'; Width = 130 }
        @{ Name = 'Effort'; Width = 70 }
        @{ Name = 'Risk'; Width = 60 }
        @{ Name = 'Memory'; Width = 85 }
        @{ Name = 'CPU'; Width = 65 }
    )
    $familyTab = New-GridTab -Text 'By product' -WithDetails -Column @(
        @{ Name = 'Product'; Width = 230 }
        @{ Name = 'Manufacturer'; Width = 190 }
        @{ Name = 'Memory'; Width = 85 }
        @{ Name = 'CPU'; Width = 65 }
        @{ Name = 'Disk'; Width = 90 }
        @{ Name = 'Proc'; Width = 50 }
        @{ Name = 'Class'; Width = 120 }
    )
    $processTab = New-GridTab -Text 'Processes' -WithDetails -Column @(
        @{ Name = 'Process'; Width = 150 }
        @{ Name = 'PID'; Width = 60 }
        @{ Name = 'Memory'; Width = 85 }
        @{ Name = 'CPU'; Width = 65 }
        @{ Name = 'Disk'; Width = 90 }
        @{ Name = 'Handles'; Width = 70 }
        @{ Name = 'What it is'; Width = 240 }
        @{ Name = 'Manufacturer'; Width = 180 }
    )
    $startupTab = New-GridTab -Text 'Starts itself' -WithDetails -Column @(
        @{ Name = 'Impact'; Width = 60 }
        @{ Name = 'Entry'; Width = 220 }
        @{ Name = 'Manufacturer'; Width = 180 }
        @{ Name = 'Where from'; Width = 150 }
        @{ Name = 'Running'; Width = 70 }
        @{ Name = 'Memory now'; Width = 90 }
        @{ Name = 'Enabled'; Width = 70 }
    )
    $machinePage = New-Tab -Text 'The machine'
    $machineBox = New-Object System.Windows.Forms.TextBox
    $machineBox.Dock = 'Fill'
    $machineBox.Multiline = $true
    $machineBox.ReadOnly = $true
    $machineBox.ScrollBars = 'Both'
    $machineBox.WordWrap = $false
    $machineBox.Font = New-Object System.Drawing.Font('Consolas', 9)
    $machinePage.Controls.Add($machineBox)
    #endregion

    #region State
    $state = [pscustomobject]@{
        Result = $null
        Status = [hashtable]::Synchronized(@{})
        Cancel = [hashtable]::Synchronized(@{ Cancelled = $false })
        Shell  = $null
        Handle = $null
        Mode   = $ScanMode
    }

    function Set-Status { param([string] $Text) $statusLabel.Text = $Text }

    function Add-Row {
        param(
            [System.Windows.Forms.ListView] $List,
            [string[]] $Value,
            [string] $Colour,
            [psobject] $Tag
        )
        $item = New-Object System.Windows.Forms.ListViewItem($Value[0])
        for ($i = 1; $i -lt $Value.Count; $i++) { $null = $item.SubItems.Add($Value[$i]) }
        if ($Colour -and $colors.ContainsKey($Colour)) { $item.ForeColor = $colors[$Colour] }
        $item.Tag = $Tag
        $null = $List.Items.Add($item)
    }

    function Show-Detail {
        param([System.Windows.Forms.ListView] $List, [System.Windows.Forms.TextBox] $Box)

        if ($List.SelectedItems.Count -eq 0) { $Box.Text = ''; return }
        $tag = $List.SelectedItems[0].Tag
        if (-not $tag) { $Box.Text = ''; return }

        $lines = [System.Collections.Generic.List[string]]::new()
        function Add-Pair {
            param([string] $Label, [psobject] $Source, [string] $Property)
            if (-not $Source) { return }
            if (-not $Source.PSObject.Properties[$Property]) { return }
            $value = $Source.$Property
            if ($null -eq $value -or "$value" -eq '') { return }
            $lines.Add('')
            $lines.Add("${Label}: $value")
        }

        # A plan action, a product group, a process and a startup entry all carry a different
        # shape. Rather than four handlers, ask each object for whichever fields it has.
        foreach ($property in 'Title', 'Family', 'Name') {
            if ($tag.PSObject.Properties[$property] -and $tag.$property) {
                $lines.Add([string] $tag.$property); break
            }
        }
        $identity = if ($tag.PSObject.Properties['Identity']) { $tag.Identity } else { $tag }

        Add-Pair 'Manufacturer' $identity 'Vendor'
        Add-Pair 'Type' $tag 'Class'
        Add-Pair 'Category' $tag 'Category'
        Add-Pair 'Measured' $tag 'Evidence'
        Add-Pair 'What it is' $identity 'Description'
        Add-Pair 'What it is' $tag 'Detail'
        Add-Pair 'What normal looks like' $identity 'Expected'
        Add-Pair 'Do this' $tag 'Recommendation'
        Add-Pair 'Do this' $identity 'Guidance'
        Add-Pair 'Expected gain' $tag 'Gain'
        Add-Pair 'Command' $tag 'Command'
        Add-Pair 'Executable' $tag 'ExecutablePath'
        Add-Pair 'Command line' $tag 'CommandLine'
        Add-Pair 'Hosting services' $tag 'ServiceText'
        Add-Pair 'Signature' $identity 'SignatureStatus'
        Add-Pair 'Publisher determined from' $identity 'VendorSource'
        Add-Pair 'Running as' $tag 'Owner'
        Add-Pair 'Running for' $tag 'AgeText'
        Add-Pair 'Note' $tag 'Note'

        if ($tag.PSObject.Properties['TopMembers'] -and @($tag.TopMembers).Count -gt 0) {
            $lines.Add('')
            $lines.Add('Largest processes in this group:')
            foreach ($member in $tag.TopMembers) {
                $lines.Add("  $($member.MemoryText)  $($member.CpuText)  $($member.Name) (pid $($member.ProcessId))")
            }
        }
        $Box.Lines = $lines.ToArray()
    }

    function Clear-Results {
        foreach ($tab in @($planTab, $familyTab, $processTab, $startupTab)) {
            $tab.List.Items.Clear()
            $tab.Details.Text = ''
        }
    }

    function Publish-Result {
        param([psobject] $Result)

        $state.Result = $Result
        Clear-Results

        $verdictBox.Text = (New-RmoTextReport -Result $Result -Width 118) -replace "`r?`n", "`r`n"
        $verdictBox.Select(0, 0)

        foreach ($action in $Result.Plan.Actions) {
            Add-Row -List $planTab.List -Colour $action.Impact -Tag $action -Value @(
                $action.Impact
                $action.Title
                $action.Category
                $action.Effort
                $action.Safety
                $action.MemoryText
                (Format-RmoPercent $action.CpuPercent)
            )
        }
        foreach ($family in $Result.Hogs.Families) {
            $colour = if ($family.Class -eq 'Unwanted') { 'Unwanted' } elseif ($family.Essential) { 'Info' } else { '' }
            Add-Row -List $familyTab.List -Colour $colour -Tag $family -Value @(
                $family.Family
                $family.Vendor
                $family.MemoryText
                $family.CpuText
                $family.DiskText
                ('{0:N0}' -f $family.ProcessCount)
                $family.Class
            )
        }
        foreach ($item in @($Result.Hogs.Processes | Sort-Object MemoryBytes -Descending)) {
            $colour = if ($item.Identity.Class -eq 'Unwanted') { 'Unwanted' } elseif ($item.Identity.Essential) { 'Info' } else { '' }
            Add-Row -List $processTab.List -Colour $colour -Tag $item -Value @(
                $item.Name
                ('{0}' -f $item.ProcessId)
                $item.MemoryText
                $item.CpuText
                $item.DiskText
                ('{0:N0}' -f $item.HandleCount)
                $item.Identity.Name
                $item.Identity.Vendor
            )
        }
        foreach ($item in @($Result.StartupItems | Sort-Object MemoryBytes -Descending)) {
            Add-Row -List $startupTab.List -Colour $item.Impact -Tag $item -Value @(
                $item.Impact
                $item.Name
                $item.Identity.Vendor
                $item.Source
                $(if ($item.Running) { "yes ($($item.InstanceCount))" } else { 'no' })
                $item.MemoryText
                $(if ($item.Enabled) { 'yes' } else { 'no' })
            )
        }

        $machineBox.Text = (New-RmoMachineText -Result $Result) -replace "`r?`n", "`r`n"
        $machineBox.Select(0, 0)

        foreach ($button in $htmlButton, $scriptButton, $jsonButton, $csvButton, $copyButton) { $button.Enabled = $true }

        $plan = $Result.Plan
        $verdict = if ($plan.Bottleneck -eq 'None') {
            'No single resource was constrained.'
        } else {
            "Constraint: $($plan.Bottleneck)."
        }
        Set-Status ("$($Result.ScanMode) scan of $($Result.Pressure.Counts.Processes) processes in $($Result.DurationSeconds)s. " +
            "$verdict $($plan.HighImpactCount) high-impact actions, up to $($plan.RecoverableMemoryText) recoverable.")
    }

    function New-RmoMachineText {
        param([psobject] $Result)

        $system = $Result.System
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add("Computer          $($system.ComputerName)  ($($system.Manufacturer) $($system.Model))")
        $lines.Add("Operating system  $($system.Os.Caption) build $($system.Os.BuildNumber), $($system.Os.Architecture)")
        $lines.Add("Installed         $($system.Os.InstalledUtc)")
        $lines.Add("Uptime            $(Format-RmoDuration $system.Os.UptimeSeconds)")
        $lines.Add("Form factor       $(if ($system.IsLaptop) { 'Portable' } else { 'Desktop or server' })$(if ($system.OnBattery) { " - on battery at $($system.BatteryPercent)%" })")
        $lines.Add("Power plan        $($system.PowerPlan.Name)")
        $lines.Add('')
        $lines.Add("Processor         $($system.Cpu.Name)")
        $lines.Add("                  $($system.Cpu.Cores) cores, $($system.Cpu.LogicalProcessors) logical, $($system.Cpu.MaxClockMhz) MHz rated, $($system.Cpu.CurrentClockMhz) MHz now")
        $lines.Add('')
        $lines.Add("Memory            $(Format-RmoBytes $system.Memory.TotalBytes) fitted, $(Format-RmoBytes $system.Memory.AvailableBytes) available")
        $lines.Add("Slots             $($system.Memory.UsedSlots) of $($system.Memory.TotalSlots) populated")
        foreach ($module in $system.Memory.Modules) {
            $lines.Add("                  $($module.Slot): $(Format-RmoBytes $module.CapacityBytes) at $($module.SpeedMhz) MHz, $($module.Manufacturer) $($module.PartNumber)")
        }
        $lines.Add('')
        $lines.Add('Disks')
        foreach ($disk in $system.Storage) {
            $lines.Add("                  $($disk.Model) - $(Format-RmoBytes $disk.SizeBytes), $($disk.MediaType), $($disk.Interface)")
        }
        $lines.Add('Volumes')
        foreach ($volume in $system.Volumes) {
            $lines.Add("                  $($volume.DriveLetter) $($volume.Label) - $(Format-RmoBytes $volume.FreeBytes) free of $(Format-RmoBytes $volume.SizeBytes) ($(Format-RmoPercent $volume.FreePercent))")
        }
        $lines.Add('')
        $lines.Add('Graphics')
        foreach ($adapter in $system.Graphics) {
            $lines.Add("                  $($adapter.Name) - driver $($adapter.DriverVersion), $($adapter.DriverAgeDays) days old")
        }
        $lines.Add('')
        $lines.Add('Antivirus registered with Windows')
        if (@($system.Antivirus).Count -eq 0) {
            $lines.Add('                  none reported (normal on Windows Server)')
        }
        foreach ($product in $system.Antivirus) {
            $lines.Add("                  $($product.DisplayName) - real-time $(if ($product.RealTimeEnabled) { 'on' } else { 'off' })")
        }
        $lines.Add('')
        $lines.Add('Page file')
        if (@($system.PageFiles).Count -eq 0) {
            $lines.Add("                  none allocated (automatic management: $($system.AutomaticPageFile))")
        }
        foreach ($file in $system.PageFiles) {
            $lines.Add("                  $($file.Name) - $(Format-RmoBytes $file.AllocatedBytes) allocated, $(Format-RmoBytes $file.PeakUsageBytes) peak use")
        }
        $lines -join [Environment]::NewLine
    }
    #endregion

    #region Events
    foreach ($tab in @($planTab, $familyTab, $processTab, $startupTab)) {
        $tab.List.Add_SelectedIndexChanged({ Show-Detail -List $this -Box $this.Tag })
    }

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 400

    $timer.Add_Tick({
        if ($state.Handle -and $state.Handle.IsCompleted) {
            $timer.Stop()
            $progressBar.Visible = $false
            $quickButton.Enabled = $true
            $completeButton.Enabled = $true
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
                [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Scan failed', 'OK', 'Error') | Out-Null
            } finally {
                $state.Shell.Dispose()
                $state.Shell = $null
                $state.Handle = $null
            }
            return
        }

        $phase = [string] $state.Status['Phase']
        $detail = [string] $state.Status['Detail']
        if ($phase) {
            Set-Status $(if ($detail) { "$phase - $detail" } else { "$phase..." })
        }
    })

    function Start-Scan {
        param([string] $Mode)

        if ($state.Shell) { return }

        $state.Mode = $Mode
        $state.Status.Clear()
        $state.Cancel['Cancelled'] = $false
        $state.Status['Phase'] = 'Starting'

        $scanScript = {
            param($ModulePath, $Mode, $Status, $Cancel)
            Import-Module $ModulePath -Force
            Invoke-ResourceAnalysis -ScanMode $Mode -StatusSink $Status -CancellationSink $Cancel -Quiet
        }

        $state.Shell = [powershell]::Create()
        $null = $state.Shell.AddScript($scanScript).AddArgument($modulePath).AddArgument($Mode).
            AddArgument($state.Status).AddArgument($state.Cancel)
        $state.Handle = $state.Shell.BeginInvoke()

        $quickButton.Enabled = $false
        $completeButton.Enabled = $false
        $cancelButton.Enabled = $true
        $progressBar.Visible = $true
        foreach ($button in $htmlButton, $scriptButton, $jsonButton, $csvButton, $copyButton) { $button.Enabled = $false }
        Set-Status "$Mode scan running..."
        $timer.Start()
    }

    $quickButton.Add_Click({ Start-Scan -Mode 'Quick' })
    $completeButton.Add_Click({ Start-Scan -Mode 'Complete' })

    $cancelButton.Add_Click({
        $state.Cancel['Cancelled'] = $true
        $cancelButton.Enabled = $false
        Set-Status 'Cancelling - finishing the current step...'
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

    $stamp = (Get-Date).ToString('yyyyMMdd-HHmm')

    $htmlButton.Add_Click({
        Save-As -Filter 'HTML report (*.html)|*.html' -DefaultName "resources-$($env:COMPUTERNAME)-$stamp.html" -Action {
            param($file)
            Export-RmoReport -Result $state.Result -Path $file -Format Html
            Start-Process $file
        }
    })
    $jsonButton.Add_Click({
        Save-As -Filter 'JSON (*.json)|*.json' -DefaultName "resources-$($env:COMPUTERNAME)-$stamp.json" -Action {
            param($file)
            Export-RmoReport -Result $state.Result -Path $file -Format Json
        }
    })
    $csvButton.Add_Click({
        Save-As -Filter 'CSV (*.csv)|*.csv' -DefaultName "resources-$($env:COMPUTERNAME)-$stamp.csv" -Action {
            param($file)
            Export-RmoReport -Result $state.Result -Path $file -Format Csv
        }
    })
    $scriptButton.Add_Click({
        Save-As -Filter 'PowerShell script (*.ps1)|*.ps1' -DefaultName "tune-$($env:COMPUTERNAME)-$stamp.ps1" -Action {
            param($file)
            New-RmoRemediationScript -Result $state.Result -Path $file
            [System.Windows.Forms.MessageBox]::Show(
                "Saved. Run it with no arguments to read the plan; it changes nothing until it is given -Run with the id of an action.",
                'Tuning script', 'OK', 'Information') | Out-Null
        }
    })
    $copyButton.Add_Click({
        [System.Windows.Forms.Clipboard]::SetText($verdictBox.Text)
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
        # SplitterDistance can only be set once the container has its final size; setting it at
        # construction throws on a control that is still 150 pixels tall.
        foreach ($tab in @($planTab, $familyTab, $processTab, $startupTab)) {
            if (-not $tab.HasDetails) { continue }
            try {
                $tab.Split.SplitterDistance = [int] ($tab.Split.Height * 0.58)
            } catch {
                Write-Verbose "Could not position the splitter on '$($tab.Page.Text)': $($_.Exception.Message)"
            }
        }
        if ($StartScan) { Start-Scan -Mode $ScanMode }
    })

    $null = $form.ShowDialog()
    $form.Dispose()
}
