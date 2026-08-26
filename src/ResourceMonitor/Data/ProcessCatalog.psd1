<#
    ProcessCatalog.psd1

    What every process on the machine actually is, who makes it, and what to do when it is the
    thing eating the computer.

    A resource report that says "svchost.exe - 34% CPU" tells the person reading it nothing.
    This catalogue is what turns a sampled process list into an explanation:

        1. What is this?          -> Name / Class / Description
        2. Who makes it?          -> Vendor
        3. Is this normal?        -> Expected
        4. What do I do about it? -> Guidance / Command

    Matching (see Resolve-RmoProcessIdentity), first match wins:

        Match         One or more process names, without the .exe, compared case-insensitively.
                      This is an exact lookup and is tried before any pattern.
        NamePattern   Case-insensitive regex over the process name, for families whose members
                      are numbered or suffixed. Patterns are tried in Priority order.
        PathPattern   Case-insensitive regex over the full executable path. Used to separate
                      two unrelated programs that ship the same generic executable name, and
                      only ever narrows a Match/NamePattern that is already a candidate.

    Fields:

        Family        Grouping key. Thirty chrome.exe processes at 300 MB each are not thirty
                      problems, they are one 9 GB problem, and the plan has to say so.
        Class         Browser, Security, Sync, System, Servicing, Communication, Media,
                      Productivity, Development, Virtualisation, Gaming, Vendor utility,
                      Remote access, Driver utility, Installer, Unwanted.
        Essential     $true means the machine does not run without it. Nothing in the plan will
                      ever propose stopping, disabling or uninstalling it - at most it will
                      explain what is driving it.
        Expected      What a normal reading looks like, so a high number can be judged rather
                      than just reported.
        Guidance      What to do when this process is at the top of the list.
        Command       An optional PowerShell one-liner implementing the guidance. It is only
                      ever written into the generated script commented out.
#>
@{
    SchemaVersion = 1
    Entries = @(

        #region Windows kernel and session infrastructure ---------------------------------------
        @{
            Id = 'sys-idle'
            Match = @('Idle')
            Name = 'System Idle Process'
            Vendor = 'Microsoft Corporation'
            Family = 'Windows kernel'
            Class = 'System'
            Essential = $true
            Description = 'Not a program. A placeholder the scheduler charges time to when a CPU core has nothing to do.'
            Expected = 'The idle process holding most of the CPU is the machine being healthy.'
            Guidance = 'Nothing to do. High idle time means the CPU is not the bottleneck.'
        }
        @{
            Id = 'sys-system'
            Match = @('System')
            Name = 'Windows kernel and drivers'
            Vendor = 'Microsoft Corporation'
            Family = 'Windows kernel'
            Class = 'System'
            Essential = $true
            Description = 'The kernel itself, plus every loaded device driver. Work charged here is almost always a driver, not Windows.'
            Expected = 'A few percent CPU. Its disk figures cover all file system and paging traffic, so they are legitimately large.'
            Guidance = 'Sustained CPU in System is a driver problem, not an application one. Check storage, network and chipset driver versions, and look for a failing disk in the system event log. Elevated disk numbers here with high memory pressure are paging, so treat it as a memory shortage.'
        }
        @{
            Id = 'sys-registry'
            Match = @('Registry')
            Name = 'Registry process'
            Vendor = 'Microsoft Corporation'
            Family = 'Windows kernel'
            Class = 'System'
            Essential = $true
            Description = 'Holds the registry hives in memory on Windows 10 1803 and later, so that hive data is pageable instead of sitting in kernel pool.'
            Expected = 'Tens to a few hundred MB. It grows with the size of the hives, so a machine with a large user profile or thousands of installed components will show more.'
            Guidance = 'Not actionable directly. A very large Registry process points at bloated hives - usually a machine with a long history of software installs.'
        }
        @{
            Id = 'sys-memcompression'
            Match = @('Memory Compression', 'MemCompression')
            Name = 'Memory Compression'
            Vendor = 'Microsoft Corporation'
            Family = 'Windows kernel'
            Class = 'System'
            Essential = $true
            Description = 'Holds the compressed page store. Windows compresses pages it would otherwise write to the page file, trading a little CPU for a lot less disk.'
            Expected = 'Small on a machine with spare RAM. Growing to gigabytes is the clearest single sign that the machine is short of memory.'
            Guidance = 'This is a symptom, not a cause. If it is large, the fix is on the memory side: close or cap whatever is consuming RAM, or add RAM.'
        }
        @{
            Id = 'sys-securesystem'
            Match = @('Secure System', 'LsaIso')
            Name = 'Virtualisation-based security'
            Vendor = 'Microsoft Corporation'
            Family = 'Windows security'
            Class = 'System'
            Essential = $true
            Description = 'The isolated (VBS / Credential Guard) side of the machine. Its memory is reserved for the secure kernel and cannot be reclaimed by anything else.'
            Expected = 'A few hundred MB, and it is normal for its working set to read oddly - it is not a normal process.'
            Guidance = 'Leave it alone. On a low-RAM machine that genuinely cannot afford the reservation, VBS and Memory Integrity are a policy decision, not a tuning one.'
        }
        @{
            Id = 'sys-svchost'
            Match = @('svchost')
            Name = 'Service Host'
            Vendor = 'Microsoft Corporation'
            Family = 'Windows services'
            Class = 'System'
            Essential = $true
            Description = 'A shared container for Windows services. On its own the name means nothing - what matters is which services are inside this particular copy.'
            Expected = 'Dozens of instances. Since Windows 10 1703, machines with more than 3.5 GB of RAM split most services into their own instance.'
            Guidance = 'The scan lists the services hosted by each instance. Act on the service that is busy, not on svchost. Windows Update (wuauserv, BITS, DoSvc), Windows Search (WSearch) and telemetry (DiagTrack) are the usual candidates.'
        }
        @{
            Id = 'sys-services'
            Match = @('services')
            Name = 'Service Control Manager'
            Vendor = 'Microsoft Corporation'
            Family = 'Windows services'
            Class = 'System'
            Essential = $true
            Description = 'Starts, stops and tracks every Windows service.'
            Expected = 'Near zero CPU and a small working set.'
            Guidance = 'Not actionable. Busy here usually means services are being started and stopped repeatedly - look for a service that is crash-looping.'
        }
        @{
            Id = 'sys-lsass'
            Match = @('lsass')
            Name = 'Local Security Authority'
            Vendor = 'Microsoft Corporation'
            Family = 'Windows security'
            Class = 'System'
            Essential = $true
            Description = 'Handles sign-in, password and token validation, and on a domain controller the directory database itself.'
            Expected = 'Low on a workstation. On a domain controller it is legitimately one of the busiest processes on the machine.'
            Guidance = 'Never stop it. High CPU on a workstation is normally an authentication loop - a stale cached credential, a mapped drive to a dead server, or an application retrying a bad password. Check the security event log for repeated 4625 failures.'
        }
        @{
            Id = 'sys-csrss'
            Match = @('csrss')
            Name = 'Client/Server Runtime Subsystem'
            Vendor = 'Microsoft Corporation'
            Family = 'Windows kernel'
            Class = 'System'
            Essential = $true
            Description = 'The user-mode side of the Windows subsystem - process and thread bookkeeping, console windows, shutdown.'
            Expected = 'One instance per session, near-zero CPU.'
            Guidance = 'Not actionable. Sustained CPU here is usually a graphics driver or a program creating and destroying windows in a loop.'
        }
        @{
            Id = 'sys-dwm'
            Match = @('dwm')
            Name = 'Desktop Window Manager'
            Vendor = 'Microsoft Corporation'
            Family = 'Windows shell'
            Class = 'System'
            Essential = $true
            Description = 'Composites everything you see on screen - window contents, transparency, animations, and the final frame handed to the display.'
            Expected = 'Low single-digit CPU, more with several high-resolution or high-refresh displays attached.'
            Guidance = 'High DWM cost is almost always the graphics driver or a display configuration. Update the GPU driver, and on a machine without a usable GPU driver reduce animations under Visual Effects.'
        }
        @{
            Id = 'sys-wininit'
            Match = @('wininit', 'winlogon', 'smss', 'fontdrvhost')
            Name = 'Windows startup and session components'
            Vendor = 'Microsoft Corporation'
            Family = 'Windows kernel'
            Class = 'System'
            Essential = $true
            Description = 'Session manager, logon and font host. They set the session up and then sit almost idle.'
            Expected = 'Near-zero CPU, small memory.'
            Guidance = 'Not actionable.'
        }
        @{
            Id = 'sys-explorer'
            Match = @('explorer')
            Name = 'Windows Explorer'
            Vendor = 'Microsoft Corporation'
            Family = 'Windows shell'
            Class = 'System'
            Essential = $true
            Description = 'The desktop, taskbar, Start menu and every file browser window.'
            Expected = 'Low CPU, a few hundred MB. It also loads every shell extension installed on the machine, so third-party software runs inside it.'
            Guidance = 'Sustained CPU or a growing working set in Explorer is usually a shell extension - cloud sync overlays, archivers, antivirus context menus. Restarting it is harmless and often enough. If it recurs, disable non-Microsoft shell extensions to find the culprit.'
            Command = 'Stop-Process -Name explorer -Force'
        }
        @{
            Id = 'sys-taskhost'
            Match = @('taskhostw', 'taskhost', 'sihost', 'dllhost', 'conhost', 'backgroundTaskHost', 'RuntimeBroker')
            Name = 'Windows task and component hosts'
            Vendor = 'Microsoft Corporation'
            Family = 'Windows shell'
            Class = 'System'
            Essential = $true
            Description = 'Generic containers Windows uses to run scheduled tasks, COM components, console windows and Store app background work. As with svchost, the container is not the workload.'
            Expected = 'Several instances, low CPU each.'
            Guidance = 'Identify what is inside before acting. For dllhost, the command line names the COM component; for backgroundTaskHost and RuntimeBroker it is a Store app. Nothing here should be stopped on its own.'
        }
        @{
            Id = 'sys-wmiprvse'
            Match = @('WmiPrvSE')
            Name = 'WMI Provider Host'
            Vendor = 'Microsoft Corporation'
            Family = 'Windows services'
            Class = 'System'
            Essential = $true
            Description = 'Runs WMI queries on behalf of whatever asked for them - management agents, monitoring tools, inventory scripts, and this scan.'
            Expected = 'Brief bursts. Sustained high CPU means something is querying it hard, often with an expensive class like Win32_Product.'
            Guidance = 'Find the caller rather than killing the host: an RMM agent, a monitoring probe, or a script polling on a short interval. Win32_Product in particular triggers an MSI reconfiguration of every installed package and should never be polled.'
        }
        @{
            Id = 'sys-audiodg'
            Match = @('audiodg')
            Name = 'Windows Audio Device Graph Isolation'
            Vendor = 'Microsoft Corporation'
            Family = 'Windows audio'
            Class = 'System'
            Essential = $true
            Description = 'Runs audio processing out of process, including any effects the sound card vendor installed.'
            Expected = 'Low, and only while audio is playing.'
            Guidance = 'High CPU here is nearly always a vendor audio enhancement. Turn off audio enhancements for the playback device, or update the audio driver.'
        }
        @{
            Id = 'sys-spoolsv'
            Match = @('spoolsv', 'PrintIsolationHost', 'printfilterpipelinesvc')
            Name = 'Print Spooler'
            Vendor = 'Microsoft Corporation'
            Family = 'Windows printing'
            Class = 'System'
            Essential = $false
            Description = 'Queues print jobs and loads every installed printer driver, including third-party ones.'
            Expected = 'Idle unless something is printing.'
            Guidance = 'A spooler pinned at high CPU is usually a stuck job or a bad printer driver. Clear the queue and restart the service. On a machine that never prints, the service can be disabled outright.'
            Command = 'Restart-Service Spooler'
        }
        @{
            Id = 'sys-ctfmon'
            Match = @('ctfmon', 'TextInputHost')
            Name = 'Text input and IME host'
            Vendor = 'Microsoft Corporation'
            Family = 'Windows shell'
            Class = 'System'
            Essential = $true
            Description = 'Handles keyboard layouts, input methods, handwriting and the touch keyboard.'
            Expected = 'Near-zero CPU.'
            Guidance = 'Not actionable. Removing unused input languages occasionally quietens it.'
        }
        @{
            Id = 'sys-shellhosts'
            Match = @('ShellExperienceHost', 'StartMenuExperienceHost', 'LockApp', 'SystemSettings', 'ApplicationFrameHost', 'SystemSettingsBroker')
            Name = 'Windows shell UI hosts'
            Vendor = 'Microsoft Corporation'
            Family = 'Windows shell'
            Class = 'System'
            Essential = $true
            Description = 'The Start menu, lock screen, Settings app and the frame around Store apps.'
            Expected = 'Idle and suspended most of the time; a burst when opened.'
            Guidance = 'Not actionable individually. Repeated high CPU in the Start menu host usually clears with a rebuild of the tile database or a new profile.'
        }
        #endregion

        #region Windows search, servicing and telemetry -----------------------------------------
        @{
            Id = 'win-searchindexer'
            Match = @('SearchIndexer', 'SearchProtocolHost', 'SearchFilterHost')
            Name = 'Windows Search indexer'
            Vendor = 'Microsoft Corporation'
            Family = 'Windows Search'
            Class = 'Servicing'
            Essential = $false
            Description = 'Builds the content index behind Start menu search, File Explorer search and Outlook search.'
            Expected = 'Heavy for the first hours after a build, a profile migration, or a large file copy, then near-idle. Sustained heavy use days later means it is not finishing.'
            Guidance = 'Trim what it indexes rather than switching it off - Outlook and Explorer search get noticeably worse without it. Remove large code, media and archive trees from the indexed locations. If it never settles, the index is corrupt: rebuild it.'
            Command = 'Stop-Service WSearch; Remove-Item "$env:ProgramData\Microsoft\Search\Data\Applications\Windows\*" -Recurse -Force; Start-Service WSearch'
        }
        @{
            Id = 'win-searchapp'
            Match = @('SearchApp', 'SearchHost', 'SearchUI')
            Name = 'Windows Search UI'
            Vendor = 'Microsoft Corporation'
            Family = 'Windows Search'
            Class = 'System'
            Essential = $true
            Description = 'The search box and its results panel, including web suggestions.'
            Expected = 'Idle until the search box is used.'
            Guidance = 'Turning off web search results in the Start menu removes most of its background work on a machine with a slow connection.'
        }
        @{
            Id = 'win-tiworker'
            Match = @('TiWorker', 'TrustedInstaller')
            Name = 'Windows Modules Installer'
            Vendor = 'Microsoft Corporation'
            Family = 'Windows servicing'
            Class = 'Servicing'
            Essential = $false
            Description = 'Applies updates and servicing-stack changes, and maintains the component store.'
            Expected = 'Sustained high CPU and disk while updates install, and again after a restart. It is throttled while the machine is in use.'
            Guidance = 'This is work that has to happen. Let it finish, and reboot if a restart is pending - it will keep restarting the work until it can complete. Only investigate if it has been busy for days, which usually means a failing update or a corrupt component store.'
            Command = 'DISM /Online /Cleanup-Image /RestoreHealth'
        }
        @{
            Id = 'win-uso'
            Match = @('MoUsoCoreWorker', 'usoclient', 'UsoClient', 'MusNotification', 'MusNotificationUx', 'WaaSMedicAgent')
            Name = 'Windows Update orchestrator'
            Vendor = 'Microsoft Corporation'
            Family = 'Windows servicing'
            Class = 'Servicing'
            Essential = $false
            Description = 'Decides when to scan for, download and install updates, and keeps the update stack itself healthy.'
            Expected = 'Short bursts on a schedule.'
            Guidance = 'Do not disable. Persistent activity means an update is failing repeatedly - look at the update history and fix the failing update rather than the process.'
        }
        @{
            Id = 'win-compattel'
            Match = @('CompatTelRunner', 'DeviceCensus', 'aeinv')
            Name = 'Microsoft Compatibility Telemetry'
            Vendor = 'Microsoft Corporation'
            Family = 'Windows telemetry'
            Class = 'Servicing'
            Essential = $false
            Description = 'Inventories installed software and hardware to judge upgrade compatibility, and sends the result to Microsoft.'
            Expected = 'Occasional bursts. On an older machine it is a well-known cause of a spinning fan and an unusable hour.'
            Guidance = 'Safe to suppress. Disable the Microsoft Compatibility Appraiser scheduled task, or set the telemetry level to Security/Required by policy. It is not needed for updates to work.'
            Command = 'Disable-ScheduledTask -TaskPath "\Microsoft\Windows\Application Experience\" -TaskName "Microsoft Compatibility Appraiser"'
        }
        @{
            Id = 'win-diagtrack'
            Match = @('DiagTrack', 'diagnosticshub.standardcollector.service', 'dwwin', 'WerFault', 'WerFaultSecure')
            Name = 'Diagnostics and error reporting'
            Vendor = 'Microsoft Corporation'
            Family = 'Windows telemetry'
            Class = 'Servicing'
            Essential = $false
            Description = 'Collects diagnostic data, and captures a dump when a program crashes or hangs.'
            Expected = 'Brief. A WerFault sitting at high CPU or memory means it is capturing a dump of something large right now.'
            Guidance = 'Frequent WerFault activity is the signal, not the problem: something is crashing repeatedly. Find it in the Application event log. The telemetry service can be reduced by policy.'
        }
        @{
            Id = 'win-wsappx'
            Match = @('AppXSvc', 'ClipSVC', 'AppVClient', 'wsappx')
            Name = 'Store app deployment services'
            Vendor = 'Microsoft Corporation'
            Family = 'Windows servicing'
            Class = 'Servicing'
            Essential = $false
            Description = 'Installs, updates and licenses Store applications. Runs inside svchost and is usually reported as wsappx.'
            Expected = 'Busy while Store apps install or update, idle otherwise.'
            Guidance = 'Let it finish. If it is permanently busy, a Store app is failing to update - reset the Store cache, or turn off automatic app updates on a managed build.'
            Command = 'wsreset.exe'
        }
        @{
            Id = 'win-defender'
            Match = @('MsMpEng', 'NisSrv', 'MpDefenderCoreService', 'MpCmdRun')
            Name = 'Microsoft Defender Antivirus'
            Vendor = 'Microsoft Corporation'
            Family = 'Microsoft Defender'
            Class = 'Security'
            Essential = $false
            Description = 'The real-time scanning engine built into Windows, plus its network inspection and scheduled scan components.'
            Expected = 'Bursts on file access and during scheduled scans. Sustained high CPU on a developer or build machine is normal and fixable.'
            Guidance = 'Never turn it off to make a machine faster - exclude instead. Add exclusions for build output, package caches, database files and virtual machine disks. Move the scheduled scan out of working hours. If a third-party antivirus is also installed, Defender should already have stepped down; if it has not, that overlap is the real problem.'
            Command = 'Add-MpPreference -ExclusionPath "<the build, package cache or database folder>"'
        }
        @{
            Id = 'win-securityhealth'
            Match = @('SecurityHealthService', 'SecurityHealthSystray', 'SecurityHealthHost', 'SgrmBroker', 'smartscreen')
            Name = 'Windows Security and SmartScreen'
            Vendor = 'Microsoft Corporation'
            Family = 'Microsoft Defender'
            Class = 'Security'
            Essential = $false
            Description = 'The Windows Security app, its tray icon, the system guard runtime broker, and the reputation check applied to downloaded files.'
            Expected = 'Near-idle.'
            Guidance = 'Not worth touching. SmartScreen briefly holds up the first run of a downloaded file, which is not a performance problem.'
        }
        @{
            Id = 'win-mssense'
            Match = @('MsSense', 'SenseIR', 'SenseCE', 'SenseNdr', 'SenseSampleUploader')
            Name = 'Microsoft Defender for Endpoint sensor'
            Vendor = 'Microsoft Corporation'
            Family = 'Microsoft Defender for Endpoint'
            Class = 'Security'
            Essential = $false
            Description = 'The EDR sensor that reports behavioural telemetry to the Defender portal, separate from the antivirus engine.'
            Expected = 'Steady low CPU, a few hundred MB.'
            Guidance = 'Managed centrally - do not disable it locally. If it is consistently expensive, raise it with whoever runs the tenant; there are documented exclusions for build and VDI workloads.'
        }
        @{
            Id = 'win-wudfhost'
            Match = @('WUDFHost', 'dasHost', 'WUDFCompanionHost')
            Name = 'Device driver and pairing hosts'
            Vendor = 'Microsoft Corporation'
            Family = 'Windows drivers'
            Class = 'System'
            Essential = $true
            Description = 'Runs user-mode device drivers and handles device pairing, including Bluetooth and biometrics.'
            Expected = 'Low. Sustained CPU points at one specific device.'
            Guidance = 'Identify the device from the command line and update or disable that one driver. Bluetooth radios and fingerprint readers are the common offenders.'
        }
        @{
            Id = 'win-phone'
            Match = @('PhoneExperienceHost', 'YourPhone', 'CrossDeviceService', 'CrossDeviceResume')
            Name = 'Phone Link'
            Vendor = 'Microsoft Corporation'
            Family = 'Phone Link'
            Class = 'Communication'
            Essential = $false
            Description = 'Mirrors an Android or iPhone - messages, calls, photos and notifications - onto the desktop.'
            Expected = 'Low, but persistent, and it keeps a Bluetooth or Wi-Fi link alive.'
            Guidance = 'Safe to remove on a machine nobody uses it on. Uninstall the Phone Link app rather than killing the process.'
            Command = 'Get-AppxPackage *YourPhone* | Remove-AppxPackage'
        }
        @{
            Id = 'win-widgets'
            Match = @('Widgets', 'WidgetService', 'GameBar', 'GameBarPresenceWriter', 'GameBarFTServer', 'XboxGameBarWidgets')
            Name = 'Widgets and Game Bar'
            Vendor = 'Microsoft Corporation'
            Family = 'Windows shell extras'
            Class = 'Media'
            Essential = $false
            Description = 'The widgets board (news, weather, feeds) and the Xbox Game Bar overlay with its background recording hooks.'
            Expected = 'Should be idle. Widgets in particular has a history of holding memory and network open on machines nobody uses it on.'
            Guidance = 'Both are safe to remove entirely on a business machine, and both are genuinely worth removing on a machine that is short of RAM.'
            Command = 'Get-AppxPackage *WebExperience* | Remove-AppxPackage; Get-AppxPackage *XboxGamingOverlay* | Remove-AppxPackage'
        }
        @{
            Id = 'win-copilot'
            Match = @('Copilot', 'CopilotNative', 'ai.exe', 'AIFabricService')
            Name = 'Microsoft Copilot'
            Vendor = 'Microsoft Corporation'
            Family = 'Microsoft Copilot'
            Class = 'Productivity'
            Essential = $false
            Description = 'The Copilot assistant surface in Windows, hosted in a web view.'
            Expected = 'Idle until opened, but it holds a web view resident.'
            Guidance = 'Removable where policy allows, and worth removing on a machine with 8 GB of RAM or less.'
        }
        #endregion

        #region Browsers and web views ----------------------------------------------------------
        @{
            Id = 'app-chrome'
            Match = @('chrome', 'GoogleCrashHandler', 'GoogleCrashHandler64')
            Name = 'Google Chrome'
            Vendor = 'Google LLC'
            Family = 'Google Chrome'
            Class = 'Browser'
            Essential = $false
            Description = 'Web browser. Runs one process per tab, per extension and per subframe, which is why it appears dozens of times.'
            Expected = 'Each tab is 50-400 MB. The individual numbers are meaningless; the family total is what matters, and on a busy machine it is routinely the single largest consumer of RAM.'
            Guidance = 'Judge it on the family total, not per process. Turn on Memory Saver so background tabs are discarded, audit extensions (they run all the time, not just when the tab is open), and treat a hundred open tabs as the capacity problem it is. Hardware acceleration off can help on a machine with a weak or broken GPU driver.'
        }
        @{
            Id = 'app-edge'
            Match = @('msedge', 'MicrosoftEdge', 'MicrosoftEdgeCP', 'MicrosoftEdgeSH', 'identity_helper')
            Name = 'Microsoft Edge'
            Vendor = 'Microsoft Corporation'
            Family = 'Microsoft Edge'
            Class = 'Browser'
            Essential = $false
            Description = 'Web browser, on the same Chromium engine as Chrome and with the same one-process-per-tab model.'
            Expected = 'As Chrome. Edge also runs startup boost and background extensions, so processes exist even with no window open.'
            Guidance = 'Judge it on the family total. Turn off startup boost and "continue running background extensions" if it is resident with no windows open, and turn on sleeping tabs.'
        }
        @{
            Id = 'app-webview2'
            Match = @('msedgewebview2')
            Name = 'Microsoft Edge WebView2'
            Vendor = 'Microsoft Corporation'
            Family = 'Edge WebView2'
            Class = 'System'
            Essential = $false
            Description = 'Not a browser window. An embedded copy of the Edge engine that other applications use to draw their interface - the new Teams and Outlook, Widgets, many installers and a great deal of line-of-business software.'
            Expected = 'One group of processes per host application, each costing what a browser tab costs. This is the single most common "why is something using 2 GB that I never opened" answer on a modern Windows machine.'
            Guidance = 'The fix is on the host application, not on WebView2. The scan reports the parent where it can read it - close or reconfigure that application. Uninstalling the WebView2 runtime breaks everything that depends on it.'
        }
        @{
            Id = 'app-firefox'
            Match = @('firefox')
            Name = 'Mozilla Firefox'
            Vendor = 'Mozilla Corporation'
            Family = 'Mozilla Firefox'
            Class = 'Browser'
            Essential = $false
            Description = 'Web browser. Uses a smaller fixed pool of content processes rather than one per tab.'
            Expected = 'A handful of processes, each several hundred MB.'
            Guidance = 'Judge it on the family total. Reduce the content process limit on a low-memory machine, and audit extensions.'
        }
        @{
            Id = 'app-otherbrowser'
            Match = @('brave', 'opera', 'opera_gx', 'vivaldi', 'iexplore', 'chromium')
            Name = 'Web browser'
            Vendor = 'Various'
            Family = 'Web browser'
            Class = 'Browser'
            Essential = $false
            Description = 'A Chromium or Internet Explorer based browser, with the same per-tab process model.'
            Expected = 'Several hundred MB per group of tabs.'
            Guidance = 'Judge it on the family total, audit extensions, and consider whether the machine needs three browsers resident at once.'
        }
        #endregion

        #region Cloud sync ----------------------------------------------------------------------
        @{
            Id = 'sync-onedrive'
            Match = @('OneDrive', 'FileSyncHelper', 'Microsoft.SharePoint', 'FileCoAuth')
            Name = 'Microsoft OneDrive'
            Vendor = 'Microsoft Corporation'
            Family = 'OneDrive'
            Class = 'Sync'
            Essential = $false
            Description = 'Syncs OneDrive and SharePoint libraries, and provides Files On-Demand placeholders in Explorer.'
            Expected = 'Low when settled. Heavy CPU, disk and network during the first sync, and again whenever a large library changes.'
            Guidance = 'Sustained load usually means too much is synced. Unsync large SharePoint libraries, make sure Files On-Demand is on so content downloads only when opened, and check for a sync conflict loop. Note that syncing a folder that is also being scanned by antivirus doubles the disk cost of every file.'
        }
        @{
            Id = 'sync-dropbox'
            Match = @('Dropbox', 'DropboxUpdate')
            Name = 'Dropbox'
            Vendor = 'Dropbox, Inc.'
            Family = 'Dropbox'
            Class = 'Sync'
            Essential = $false
            Description = 'Syncs a Dropbox folder, and indexes its contents for search.'
            Expected = 'Several hundred MB resident. Its memory use scales with the number of files in the account, not their size.'
            Guidance = 'Use selective sync or online-only files to cut the file count it tracks. On a machine with a very large account it is a legitimate memory problem with no fix other than syncing less.'
        }
        @{
            Id = 'sync-googledrive'
            Match = @('GoogleDriveFS', 'googledrivesync', 'GoogleUpdate', 'GoogleUpdater')
            Name = 'Google Drive for desktop'
            Vendor = 'Google LLC'
            Family = 'Google Drive'
            Class = 'Sync'
            Essential = $false
            Description = 'Mounts Google Drive as a drive letter and caches opened files locally.'
            Expected = 'Moderate, with disk activity as the cache fills.'
            Guidance = 'Prefer streaming over mirroring, and cap the local cache. Exclude the cache folder from antivirus scanning.'
        }
        @{
            Id = 'sync-box'
            Match = @('Box', 'BoxSync', 'egnyte', 'EgnyteClient', 'ShareFile', 'SyncBackPro', 'Backblaze', 'bzbui', 'bzserv')
            Name = 'File sync or backup client'
            Vendor = 'Various'
            Family = 'Sync and backup'
            Class = 'Sync'
            Essential = $false
            Description = 'A third-party file sync or cloud backup agent that watches the file system and uploads changes.'
            Expected = 'Low when settled; heavy during an initial upload.'
            Guidance = 'Check whether it is still needed, and whether it overlaps another sync client covering the same folders. Two agents watching one tree is a common and avoidable source of constant disk activity.'
        }
        #endregion

        #region Communication and meetings ------------------------------------------------------
        @{
            Id = 'app-teams-new'
            Match = @('ms-teams', 'msteams', 'ms-teamsupdate')
            Name = 'Microsoft Teams'
            Vendor = 'Microsoft Corporation'
            Family = 'Microsoft Teams'
            Class = 'Communication'
            Essential = $false
            Description = 'The current Teams client. It draws its interface in Edge WebView2, so its real cost is spread across msedgewebview2 processes as well as its own.'
            Expected = '400 MB - 1.5 GB across the family when idle, considerably more in a meeting with video.'
            Guidance = 'Count the WebView2 processes belonging to it when judging its cost. Turn off "register Teams as the chat app for Office" and GPU hardware acceleration if the machine struggles, and stop it starting automatically on a machine where it is opened occasionally.'
        }
        @{
            Id = 'app-teams-classic'
            Match = @('Teams')
            Name = 'Microsoft Teams (classic)'
            Vendor = 'Microsoft Corporation'
            Family = 'Microsoft Teams (classic)'
            Class = 'Communication'
            Essential = $false
            Description = 'The retired Electron-based Teams client. Runs a full Chromium instance of its own.'
            Expected = '600 MB - 2 GB across its processes. Comfortably the heaviest chat client ever shipped.'
            Guidance = 'This client is out of support. Moving to the current Teams client is itself a performance improvement and removes a duplicate Chromium runtime from the machine.'
        }
        @{
            Id = 'app-outlook'
            Match = @('OUTLOOK', 'olk', 'HxOutlook', 'HxTsr')
            Name = 'Microsoft Outlook'
            Vendor = 'Microsoft Corporation'
            Family = 'Microsoft Outlook'
            Class = 'Productivity'
            Essential = $false
            Description = 'Mail client. The classic client keeps a local cache (.ost) and add-ins load into it; the new client is a web view.'
            Expected = 'Low CPU, several hundred MB. Sustained high disk with high CPU is usually the cached mailbox or an add-in.'
            Guidance = 'Reduce the offline mail period on a large mailbox, and disable add-ins one at a time - COM add-ins are the most common cause of a slow or hanging Outlook. Exclude the .ost from antivirus scanning. Repeated repairs of the same profile point at a corrupt cache; recreate it.'
        }
        @{
            Id = 'app-office'
            Match = @('EXCEL', 'WINWORD', 'POWERPNT', 'ONENOTE', 'MSACCESS', 'MSPUB', 'VISIO', 'WINPROJ', 'ProtocolHandler')
            Name = 'Microsoft Office application'
            Vendor = 'Microsoft Corporation'
            Family = 'Microsoft Office'
            Class = 'Productivity'
            Essential = $false
            Description = 'An Office desktop application.'
            Expected = 'Scales with the document. A large Excel workbook with volatile formulas or external links can legitimately hold gigabytes and saturate a core.'
            Guidance = 'When Excel is the top consumer, the workbook is the problem, not Office: look for full-column formulas, volatile functions, links to closed workbooks and unbounded conditional formatting. Set calculation to manual while investigating.'
        }
        @{
            Id = 'app-officesvc'
            Match = @('OfficeClickToRun', 'OfficeC2RClient', 'MSOSYNC', 'MSOIDSVC', 'OfficeSvcMgr', 'Microsoft.Office.Companion')
            Name = 'Office servicing components'
            Vendor = 'Microsoft Corporation'
            Family = 'Microsoft Office'
            Class = 'Servicing'
            Essential = $false
            Description = 'Keeps Office up to date and streams its components.'
            Expected = 'Bursts of CPU, disk and network while an Office update is applied.'
            Guidance = 'Let it finish. If it is permanently busy, an Office update is failing - run a repair.'
        }
        @{
            Id = 'app-zoom'
            Match = @('Zoom', 'Zoom_launcher', 'CptHost', 'ZoomOutlookMiddleware', 'aomhost64')
            Name = 'Zoom'
            Vendor = 'Zoom Communications, Inc.'
            Family = 'Zoom'
            Class = 'Communication'
            Essential = $false
            Description = 'Meeting client. Video encoding, virtual backgrounds and screen sharing are all CPU-heavy.'
            Expected = 'Low when idle in the tray; a large fraction of the CPU during a meeting, especially with a virtual background on a machine without hardware encoding.'
            Guidance = 'In a meeting this load is the job. Outside one, stop it starting with Windows. Turning off virtual backgrounds and HD video is the single biggest saving on an older machine.'
        }
        @{
            Id = 'app-slack'
            Match = @('slack')
            Name = 'Slack'
            Vendor = 'Slack Technologies, LLC (Salesforce)'
            Family = 'Slack'
            Class = 'Communication'
            Essential = $false
            Description = 'Chat client built on Electron, so it runs its own Chromium instance with a process per workspace.'
            Expected = '400 MB - 1 GB across its processes, more with many workspaces joined.'
            Guidance = 'Leave fewer workspaces signed in, or use it in a browser tab on a memory-constrained machine.'
        }
        @{
            Id = 'app-discord'
            Match = @('Discord', 'DiscordPTB', 'DiscordCanary', 'DiscordDevelopment')
            Name = 'Discord'
            Vendor = 'Discord Inc.'
            Family = 'Discord'
            Class = 'Communication'
            Essential = $false
            Description = 'Chat and voice client, also Electron-based, with hardware-accelerated overlay hooks into games.'
            Expected = '300 MB - 1 GB. The in-game overlay adds CPU cost to whatever is running.'
            Guidance = 'On a work machine this is usually a personal application that can be removed. Otherwise stop it starting with Windows and turn off the game overlay.'
        }
        @{
            Id = 'app-webex'
            Match = @('CiscoCollabHost', 'webexhost', 'atmgr', 'ptoneclk', 'CiscoWebExStart', 'WebexHost')
            Name = 'Cisco Webex'
            Vendor = 'Cisco Systems, Inc.'
            Family = 'Cisco Webex'
            Class = 'Communication'
            Essential = $false
            Description = 'Meeting client and its always-resident helper components.'
            Expected = 'Low idle, high during a meeting.'
            Guidance = 'The helpers stay resident after a meeting ends. On a machine that only occasionally joins Webex meetings, remove the persistent components and let the browser join instead.'
        }
        #endregion

        #region Security agents -----------------------------------------------------------------
        @{
            Id = 'sec-sentinelone'
            Match = @('SentinelAgent', 'SentinelServiceHost', 'SentinelStaticEngine', 'SentinelStaticEngineScanner', 'SentinelUI', 'SentinelHelperService')
            Name = 'SentinelOne agent'
            Vendor = 'SentinelOne, Inc.'
            Family = 'SentinelOne'
            Class = 'Security'
            Essential = $false
            Description = 'Endpoint detection and response agent. Inspects process behaviour and file activity continuously.'
            Expected = 'Steady low-to-moderate CPU and 300 MB - 1 GB of memory. Deep visibility mode and full disk scans cost considerably more.'
            Guidance = 'Managed centrally - never disable it locally, and tamper protection will usually stop you anyway. If it is genuinely the bottleneck, the answer is exclusions in the console for build trees, database files and VM disks, not removal.'
        }
        @{
            Id = 'sec-crowdstrike'
            Match = @('CSFalconService', 'CSFalconContainer', 'CSFalconController')
            Name = 'CrowdStrike Falcon sensor'
            Vendor = 'CrowdStrike, Inc.'
            Family = 'CrowdStrike Falcon'
            Class = 'Security'
            Essential = $false
            Description = 'Endpoint detection and response sensor, largely kernel-resident, so some of its cost shows up under System rather than under its own name.'
            Expected = 'Low and steady. It is one of the lighter EDR agents.'
            Guidance = 'Managed centrally. Where it does cost real time it is usually a specific workload - a compiler, an installer, a database - and the fix is an exclusion in the Falcon console.'
        }
        @{
            Id = 'sec-huntress'
            Match = @('HuntressAgent', 'HuntressUpdater', 'HuntressRio', 'hUpdate')
            Name = 'Huntress agent'
            Vendor = 'Huntress Labs Incorporated'
            Family = 'Huntress'
            Class = 'Security'
            Essential = $false
            Description = 'Managed detection and response agent, focused on persistence and footholds rather than on real-time file scanning.'
            Expected = 'Very low. It surveys periodically rather than hooking every file operation.'
            Guidance = 'Leave it alone. If it appears in a resource report at all, it is normally mid-survey and will settle.'
        }
        @{
            Id = 'sec-sophos'
            Match = @('SophosHealth', 'SophosFS', 'SophosFileScanner', 'SophosNtpService', 'SophosCleanM', 'SophosUI', 'SophosLiveQueryService', 'McsAgent', 'McsClient', 'SSPService', 'SophosOsquery', 'SEDService')
            Name = 'Sophos endpoint protection'
            Vendor = 'Sophos Ltd'
            Family = 'Sophos'
            Class = 'Security'
            Essential = $false
            Description = 'Antivirus, EDR, device control and web filtering, split across a number of services.'
            Expected = 'Moderate. The file scanner and the on-access scanner are the expensive parts.'
            Guidance = 'Managed centrally through Sophos Central. Add scanning exclusions there for build output, database files and virtual disks. Tamper protection blocks local changes by design.'
        }
        @{
            Id = 'sec-mcafee'
            Match = @('mcshield', 'MfeAVSvc', 'MfeEpeSvc', 'MfeEsp', 'masvc', 'macmnsvc', 'mfemms', 'mfevtps', 'McCSPServiceHost', 'McAPExe', 'ModuleCoreService', 'MMSSHOST')
            Name = 'McAfee / Trellix endpoint security'
            Vendor = 'McAfee, LLC / Trellix'
            Family = 'McAfee'
            Class = 'Security'
            Essential = $false
            Description = 'On-access scanning, threat prevention and its management agent.'
            Expected = 'Historically one of the heavier agents, particularly on file-server and developer workloads.'
            Guidance = 'Tune the on-access scan policy in ePO or the Trellix console rather than locally. If this is the consumer-grade McAfee that shipped with the machine and the organisation runs a different endpoint product, removing it is both a performance and a security improvement - two real-time scanners on one machine is the worst of both.'
        }
        @{
            Id = 'sec-gendigital'
            Match = @('NortonSecurity', 'NortonSecurityUI', 'nsWscSvc', 'NortonUI', 'AvastSvc', 'AvastUI', 'aswidsagent', 'AVGSvc', 'AVGUI', 'avgnt', 'ccSvcHst')
            Name = 'Norton / Avast / AVG security suite'
            Vendor = 'Gen Digital Inc.'
            Family = 'Consumer security suite'
            Class = 'Security'
            Essential = $false
            Description = 'A consumer antivirus suite. These products bundle real-time scanning with a browser extension, a VPN, a password manager, a registry cleaner and an update nag.'
            Expected = 'Moderate to heavy, with a lot of it in components that have nothing to do with scanning.'
            Guidance = 'On a business machine this is nearly always residue from the original build or a personal install, sitting alongside the endpoint product the organisation actually manages. Remove it with the vendor removal tool and let Defender or the managed agent take over. Check first that it really is not the managed product.'
        }
        @{
            Id = 'sec-other'
            Match = @('ekrn', 'egui', 'bdagent', 'vsserv', 'MBAMService', 'mbamtray', 'MalwarebytesEndpointAgent', 'WRSA', 'WRCoreService', 'PccNTMon', 'TmListen', 'coreServiceShell', 'ds_agent', 'CylanceSvc', 'CylanceUI', 'elastic-agent', 'ArcticWolfAgent', 'ThreatLockerService')
            Name = 'Endpoint security agent'
            Vendor = 'Various'
            Family = 'Endpoint security'
            Class = 'Security'
            Essential = $false
            Description = 'A third-party antivirus, EDR or application-control agent.'
            Expected = 'Steady low-to-moderate CPU, with bursts during scans.'
            Guidance = 'Confirm this is the product the organisation manages, and that it is the only real-time scanner on the machine. Overlapping scanners are a frequent and severe performance problem. Tune exclusions in the vendor console, not locally.'
        }
        #endregion

        #region Remote access and management ----------------------------------------------------
        @{
            Id = 'rmm-ninja'
            Match = @('NinjaRMMAgent', 'NinjaRMMAgentPatcher', 'ninjarmm-cli')
            Name = 'NinjaOne agent'
            Vendor = 'NinjaOne, LLC'
            Family = 'NinjaOne'
            Class = 'Remote access'
            Essential = $false
            Description = 'Remote monitoring and management agent - inventory, patching, scripting and remote control.'
            Expected = 'Low, with bursts during a patch cycle or an inventory scan.'
            Guidance = 'This is the management agent; leave it running. Sustained load usually means a patch job or a script is running, or a scheduled task is failing and retrying.'
        }
        @{
            Id = 'rmm-connectwise'
            Match = @('LTSvc', 'LTSvcMon', 'LTTray', 'ScreenConnect.ClientService', 'ScreenConnect.WindowsClient', 'ConnectWiseControl.Client', 'Automate')
            Name = 'ConnectWise Automate / ScreenConnect'
            Vendor = 'ConnectWise, LLC'
            Family = 'ConnectWise'
            Class = 'Remote access'
            Essential = $false
            Description = 'Management agent and remote control client.'
            Expected = 'Low idle. The remote control client only costs real CPU while a session is connected.'
            Guidance = 'Leave the management agent alone. A ScreenConnect client using CPU with nobody connected is worth restarting.'
        }
        @{
            Id = 'rmm-other'
            Match = @('AteraAgent', 'AgentPackageMonitoring', 'CagService', 'Datto.RMM', 'CentraStage', 'AEMAgent', 'KaseyaAgent', 'AgentMon', 'atera')
            Name = 'Remote monitoring agent'
            Vendor = 'Various'
            Family = 'RMM agent'
            Class = 'Remote access'
            Essential = $false
            Description = 'A remote monitoring and management agent used to inventory, patch and script the machine.'
            Expected = 'Low, with bursts during scheduled work.'
            Guidance = 'Leave it running. If more than one RMM agent is present, that is worth resolving - it usually means a previous provider was never removed.'
        }
        @{
            Id = 'remote-teamviewer'
            Match = @('TeamViewer', 'TeamViewer_Service', 'tv_w32', 'tv_x64', 'AnyDesk', 'rutserv', 'SplashtopStreamer', 'SRService', 'LMIGuardianSvc', 'LogMeIn', 'ra_server', 'GoToAssist')
            Name = 'Remote access tool'
            Vendor = 'Various'
            Family = 'Remote access'
            Class = 'Remote access'
            Essential = $false
            Description = 'Unattended remote access software.'
            Expected = 'Low idle, moderate while a session is connected.'
            Guidance = 'Confirm it is a sanctioned tool. Several of these are commonly left behind after a support call, and an unmanaged unattended-access agent is a security problem as well as a resource one. Remove what is not needed; set the rest to start on demand.'
        }
        #endregion

        #region Vendor and driver utilities -----------------------------------------------------
        @{
            Id = 'drv-nvidia'
            Match = @('NVDisplay.Container', 'nvcontainer', 'NVIDIA Web Helper', 'nvsphelper64', 'NvTelemetryContainer', 'nvcplui', 'NVIDIA Share', 'NVIDIA Broadcast')
            Name = 'NVIDIA display driver services'
            Vendor = 'NVIDIA Corporation'
            Family = 'NVIDIA'
            Class = 'Driver utility'
            Essential = $false
            Description = 'The container services behind the NVIDIA control panel, GeForce Experience or the NVIDIA app, telemetry and the ShadowPlay overlay.'
            Expected = 'The display container should be near-idle. The overlay and telemetry components should not be doing anything at all on a machine nobody games on.'
            Guidance = 'Keep the display driver, drop the extras. Uninstall GeForce Experience / the NVIDIA app on a business machine, or install the driver only. The in-game overlay and instant replay are worth turning off regardless - instant replay records continuously.'
        }
        @{
            Id = 'drv-intel'
            Match = @('igfxEM', 'igfxCUIService', 'igfxHK', 'IntelCpHDCPSvc', 'IntelCpHeciSvc', 'esrv_svc', 'DPTFCPLSupport', 'OneApp.IGCC.WinService', 'IntelGraphicsExperience', 'jhi_service', 'PrivacyIconClient', 'ThunderboltService', 'DSAService', 'DSAUpdateService', 'IntelAudioService')
            Name = 'Intel platform and graphics services'
            Vendor = 'Intel Corporation'
            Family = 'Intel'
            Class = 'Driver utility'
            Essential = $false
            Description = 'Intel graphics command centre, thermal framework, management engine interface, Thunderbolt and the Driver & Support Assistant.'
            Expected = 'Near-idle. The Driver & Support Assistant wakes periodically to check for updates.'
            Guidance = 'The graphics and chipset drivers matter; the update assistants and companion apps do not. Removing the Driver & Support Assistant on a managed fleet is safe and removes a scheduled network check.'
        }
        @{
            Id = 'drv-amd'
            Match = @('AMDRSServ', 'AMDRSSrcExt', 'RadeonSoftware', 'atieclxx', 'amdow', 'AMDCleanupUtility', 'cncmd')
            Name = 'AMD graphics services'
            Vendor = 'Advanced Micro Devices, Inc.'
            Family = 'AMD'
            Class = 'Driver utility'
            Essential = $false
            Description = 'Radeon Software, its external events service and the recording/streaming components.'
            Expected = 'Near-idle.'
            Guidance = 'Keep the driver, turn off the recording and streaming features on a machine that does not need them.'
        }
        @{
            Id = 'drv-audio'
            Match = @('RtkAudUService', 'RtkAudUService64', 'RAVBg64', 'RtkNGUI64', 'RtlUpd', 'WavesSvc', 'WavesSysSvc', 'NahimicService', 'NahimicSvc32', 'NahimicSvc64', 'A-Volute', 'SmartAudio', 'DolbyDAX2API', 'DTSAPO4Service', 'SoundBlasterConnect')
            Name = 'Audio driver and enhancement services'
            Vendor = 'Realtek / Waves / SteelSeries / Dolby'
            Family = 'Audio utilities'
            Class = 'Driver utility'
            Essential = $false
            Description = 'The vendor layer on top of the Windows audio driver - equalisers, spatial audio, and per-application effects.'
            Expected = 'Low. Nahimic and Waves in particular have a long history of high CPU, of conflicting with games and capture software, and of leaking.'
            Guidance = 'These are the audio components most worth removing. The plain Realtek driver keeps sound working without them. Turn off audio enhancements for the device first and see whether the machine improves.'
        }
        @{
            Id = 'drv-input'
            Match = @('SynTPEnh', 'SynTPHelper', 'SynTPEnhService', 'ETDCtrl', 'ETDCtrlHelper', 'ETDService', 'ApntEx', 'Apoint', 'ibtsiva', 'HidMonitorSvc')
            Name = 'Touchpad and input driver utilities'
            Vendor = 'Synaptics / ELAN / Alps'
            Family = 'Input utilities'
            Class = 'Driver utility'
            Essential = $false
            Description = 'The gesture and configuration layer for a laptop touchpad.'
            Expected = 'Very low.'
            Guidance = 'Needed for gestures and for the touchpad settings page. Not usually worth touching, but an old Synaptics helper spinning a core is a known problem fixed by updating the driver.'
        }
        @{
            Id = 'oem-dell'
            Match = @('SupportAssistAgent', 'DellSupportAssistRemedationService', 'DellClientManagementService', 'DellTechHub', 'DDVDataCollector', 'DDVCollectorSvcApi', 'DDVRulesProcessor', 'DellUpdate', 'Dell.TechHub', 'DellOptimizer', 'DellOptimizerUI')
            Name = 'Dell SupportAssist / Optimizer'
            Vendor = 'Dell Technologies'
            Family = 'Dell utilities'
            Class = 'Vendor utility'
            Essential = $false
            Description = 'Hardware diagnostics, driver updates and a set of "optimisation" services that profile applications and adjust audio and network settings.'
            Expected = 'Should be near-idle. The data collector and rules processor are frequent offenders for constant low-level CPU and disk activity.'
            Guidance = 'On a managed fleet, driver updates come from the management platform, not from here - SupportAssist and Optimizer can be removed, and Dell Command | Update used on demand instead. Keep them on a machine that relies on Dell warranty diagnostics.'
        }
        @{
            Id = 'oem-hp'
            Match = @('HPSupportSolutionsFrameworkService', 'HPPrintScanDoctorService', 'HotKeyServiceUWP', 'HPAudioSwitch', 'HPSysInfoCap', 'HPNetworkCap', 'HPAppHelperCap', 'hpqwmiex', 'HPWMISVC', 'HPSmartDeviceAgentBase')
            Name = 'HP support and device services'
            Vendor = 'HP Inc.'
            Family = 'HP utilities'
            Class = 'Vendor utility'
            Essential = $false
            Description = 'HP Support Assistant, hotkey handling, and the capability services behind the HP diagnostics and printing apps.'
            Expected = 'Near-idle.'
            Guidance = 'Hotkey and audio switch services are worth keeping on a laptop. Support Assistant and the printer helper agents can go on a managed machine.'
        }
        @{
            Id = 'oem-lenovo'
            Match = @('ImController', 'FnHotkeyUtility', 'LenovoUtilityService', 'CommercialVantage', 'LenovoSystemUpdate')
            NamePattern = '^Lenovo(Vantage|Utility|System)'
            Name = 'Lenovo Vantage and system services'
            Vendor = 'Lenovo'
            Family = 'Lenovo utilities'
            Class = 'Vendor utility'
            Essential = $false
            Description = 'System updates, battery and thermal profiles, hotkeys and the Vantage dashboard. ImController is the intelligent-management plugin host.'
            Expected = 'Near-idle. ImController has a documented history of high CPU and of downloading and running plugins.'
            Guidance = 'Keep hotkeys and power/thermal profile control on a laptop - the thermal profile genuinely affects how fast the machine runs. Commercial Vantage is the managed build to prefer; the consumer Vantage and System Update can be removed on a fleet that patches centrally.'
        }
        @{
            Id = 'oem-other'
            Match = @('ASUSSystemAnalysis', 'ArmouryCrate.Service', 'AsusUpdateHelper', 'AsusOptimization', 'AsusSoftwareManager', 'AcerJumpStartService', 'AcerCloudService', 'MSI.CentralServer', 'MSI_Center_Service', 'GigabyteUpdateService', 'SamsungSettings')
            Name = 'OEM system utility'
            Vendor = 'ASUS / Acer / MSI / Gigabyte / Samsung'
            Family = 'OEM utilities'
            Class = 'Vendor utility'
            Essential = $false
            Description = 'The manufacturer utility suite - fan and lighting control, update checks and a dashboard.'
            Expected = 'Should be near-idle, and often is not.'
            Guidance = 'Consumer OEM suites are among the best return per minute of any cleanup on a business machine: remove what is not needed for fan or thermal control and let Windows Update and the management platform handle drivers.'
        }
        @{
            Id = 'periph-peripherals'
            Match = @('iCUE', 'CorsairService', 'Razer Synapse Service', 'RzSDKService', 'GameManagerService', 'LogiOptions', 'LogiOptionsMgr', 'logioptionsplus_agent', 'LogitechOptions', 'SteelSeriesEngine', 'SteelSeriesGG', 'ROCCAT', 'OpenRGB', 'LightingService', 'MSIAfterburner', 'RTSS')
            Name = 'Peripheral and lighting control software'
            Vendor = 'Corsair / Razer / Logitech / SteelSeries'
            Family = 'Peripheral utilities'
            Class = 'Vendor utility'
            Essential = $false
            Description = 'Keyboard, mouse, headset and RGB lighting control, plus overlay and macro engines.'
            Expected = 'Should be low. iCUE, Synapse and Logitech G Hub are all well known for hundreds of MB of memory and steady CPU while doing nothing visible.'
            Guidance = 'Strong candidates for removal on a work machine. Where the hardware needs it, most of these will apply saved profiles to the device and can then be stopped, or stopped from starting with Windows.'
        }
        #endregion

        #region Development and virtualisation --------------------------------------------------
        @{
            Id = 'dev-vscode'
            Match = @('Code', 'Code - Insiders', 'VSCodium', 'Cursor', 'Windsurf')
            Name = 'Visual Studio Code'
            Vendor = 'Microsoft Corporation'
            Family = 'Visual Studio Code'
            Class = 'Development'
            Essential = $false
            Description = 'Editor built on Electron. Runs a renderer, an extension host, language servers and file watchers - each a separate process.'
            Expected = '500 MB - 3 GB across the family, driven mostly by extensions and by how large the open folder is.'
            Guidance = 'Extensions and file watchers are the cost, not the editor. Exclude node_modules and build output from the watcher, disable extensions per workspace, and close windows holding very large folders. TypeScript and Python language servers are usually the largest single processes.'
        }
        @{
            Id = 'dev-visualstudio'
            Match = @('devenv', 'ServiceHub.Host.dotnet.x64', 'ServiceHub.Host.CLR.x64', 'ServiceHub.RoslynCodeAnalysisService', 'ServiceHub.IdentityHost', 'MSBuild', 'VBCSCompiler', 'PerfWatson2', 'Microsoft.ServiceHub.Controller')
            Name = 'Visual Studio'
            Vendor = 'Microsoft Corporation'
            Family = 'Visual Studio'
            Class = 'Development'
            Essential = $false
            Description = 'The IDE and its out-of-process service hubs - code analysis, IntelliSense, identity and the build engine.'
            Expected = '2-8 GB across the family on a large solution. Roslyn code analysis is normally the largest part.'
            Guidance = 'Real cost for real work. Where it makes the machine unusable, close unused solutions, and add antivirus exclusions for the solution and package folders - antivirus scanning of build output is often half the cost of a build.'
        }
        @{
            Id = 'dev-jetbrains'
            Match = @('idea64', 'pycharm64', 'rider64', 'webstorm64', 'phpstorm64', 'clion64', 'datagrip64', 'fsnotifier', 'jetbrains-toolbox')
            Name = 'JetBrains IDE'
            Vendor = 'JetBrains s.r.o.'
            Family = 'JetBrains'
            Class = 'Development'
            Essential = $false
            Description = 'A JVM-based IDE. Its memory ceiling is set by its own configuration, not by what the machine has spare.'
            Expected = '1-4 GB. Indexing a new project is CPU and disk heavy and then settles.'
            Guidance = 'Cap the heap in the IDE settings on a machine short of RAM, exclude build output from indexing, and let the initial index finish before judging it.'
        }
        @{
            Id = 'dev-runtimes'
            Match = @('node', 'python', 'python3', 'pythonw', 'java', 'javaw', 'ruby', 'php', 'dotnet', 'deno', 'bun', 'perl')
            Name = 'Language runtime'
            Vendor = 'Various'
            Family = 'Language runtimes'
            Class = 'Development'
            Essential = $false
            Description = 'A script or application running under a language runtime. The runtime name says nothing about what it is doing - the command line does.'
            Expected = 'Entirely dependent on the workload. A stray development server or watcher left running from last week is a common find.'
            Guidance = 'Read the command line in the details pane to identify the script. Orphaned watchers, dev servers and test runners are safe to stop and are one of the easiest wins on a developer machine.'
        }
        @{
            Id = 'virt-wsl'
            Match = @('vmmem', 'vmmemWSL', 'vmcompute', 'wslservice', 'wslhost', 'wsl')
            Name = 'WSL / Hyper-V virtual machine memory'
            Vendor = 'Microsoft Corporation'
            Family = 'WSL and Hyper-V'
            Class = 'Virtualisation'
            Essential = $false
            Description = 'Not a program - the memory and CPU assigned to a Linux subsystem or Hyper-V virtual machine, reported as one process on the host.'
            Expected = 'Whatever the guest is using. WSL 2 will by default claim up to half the machine memory, and does not always hand it back.'
            Guidance = 'Cap it in .wslconfig (memory= and processors=) and shut idle distributions down with wsl --shutdown. On a machine with 8-16 GB of RAM an uncapped WSL is a leading cause of everything else being paged out.'
            Command = 'wsl --shutdown'
        }
        @{
            Id = 'virt-docker'
            Match = @('Docker Desktop', 'com.docker.backend', 'com.docker.build', 'com.docker.dev-envs', 'com.docker.extensions', 'dockerd', 'docker')
            Name = 'Docker Desktop'
            Vendor = 'Docker, Inc.'
            Family = 'Docker'
            Class = 'Virtualisation'
            Essential = $false
            Description = 'Container runtime and its desktop interface, backed by a WSL 2 or Hyper-V virtual machine whose cost appears under vmmem.'
            Expected = '1-4 GB with containers running, and a stubborn baseline even with none.'
            Guidance = 'Turn off "start Docker Desktop when you sign in" on a machine that uses it occasionally, and cap the backing VM. Count vmmem when judging what it costs.'
        }
        @{
            Id = 'virt-hypervisor'
            Match = @('vmwp', 'vmms', 'vmware-vmx', 'vmware-authd', 'vmware-tray', 'VirtualBoxVM', 'VBoxSVC', 'VBoxHeadless', 'qemu-system-x86_64', 'prl_vm_app')
            Name = 'Virtual machine host'
            Vendor = 'Microsoft / Broadcom (VMware) / Oracle'
            Family = 'Virtual machines'
            Class = 'Virtualisation'
            Essential = $false
            Description = 'A running virtual machine. Each one holds its assigned memory and competes for the same cores as the host.'
            Expected = 'Its configured allocation.'
            Guidance = 'Shut down or suspend virtual machines that are not in use, and check that the total assigned memory across all running VMs leaves the host enough to work with. Over-committed memory is the usual reason a host with plenty of RAM feels slow.'
        }
        @{
            Id = 'dev-sql'
            Match = @('sqlservr', 'sqlwriter', 'SQLAGENT', 'ReportingServicesService', 'msmdsrv', 'mysqld', 'postgres', 'mongod', 'redis-server', 'oracle')
            Name = 'Database engine'
            Vendor = 'Various'
            Family = 'Database'
            Class = 'Development'
            Essential = $false
            Description = 'A database server. It is designed to take memory and keep it - the buffer pool grows to whatever it is allowed.'
            Expected = 'Large and stable. High memory is correct behaviour, not a leak.'
            Guidance = 'Never "free" its memory by restarting it. On a machine that is also a workstation, set a maximum server memory so the engine leaves room for everything else. Exclude the data and log files from antivirus scanning.'
        }
        @{
            Id = 'dev-iis'
            Match = @('w3wp', 'iisexpress', 'WAS', 'inetinfo', 'php-cgi')
            Name = 'IIS application pool'
            Vendor = 'Microsoft Corporation'
            Family = 'IIS'
            Class = 'Development'
            Essential = $false
            Description = 'A worker process hosting one or more web applications. The pool name in the command line says which.'
            Expected = 'Scales with the application. A pool growing steadily and never releasing is a leak in the hosted code.'
            Guidance = 'Identify the pool from the command line, then look at the application rather than at IIS. A scheduled recycle is a workaround for a leak, not a fix.'
        }
        #endregion

        #region Media, gaming and consumer software ---------------------------------------------
        @{
            Id = 'app-adobe'
            Match = @('Acrobat', 'AcroRd32', 'AcroCEF', 'AdobeARM', 'armsvc', 'CCXProcess', 'CoreSync',
                      'AdobeIPCBroker', 'Creative Cloud', 'Creative Cloud Helper', 'AdobeUpdateService',
                      'AdobeNotificationClient', 'AdobeGCClient', 'AGSService', 'Photoshop', 'Illustrator',
                      'AfterFX', 'Adobe Premiere Pro', 'AdobeCollabSync')
            NamePattern = '^(Acrobat|Adobe|Creative Cloud)'
            Name = 'Adobe application or service'
            Vendor = 'Adobe Inc.'
            Family = 'Adobe'
            Class = 'Media'
            Essential = $false
            Description = 'An Adobe application, or one of the Creative Cloud background services - sync, licensing, notifications and the updater.'
            Expected = 'The creative applications are legitimately heavy. The background services should not be, and frequently are: CoreSync and CCXProcess are common causes of persistent CPU and disk activity on a machine where nothing Adobe is open.'
            Guidance = 'On a machine with only Acrobat Reader installed, remove the Creative Cloud desktop components and turn off the Acrobat updater service. Where Creative Cloud is needed, turn off Creative Cloud file sync if the organisation does not use it, and stop it starting at sign-in.'
        }
        @{
            Id = 'app-media'
            Match = @('Spotify', 'SpotifyWebHelper', 'iTunes', 'AppleMobileDeviceService', 'iTunesHelper', 'iPodService', 'AppleMusic', 'mDNSResponder', 'Bonjour', 'vlc', 'PotPlayerMini64', 'obs64', 'HandBrake', 'HandBrakeCLI', 'ffmpeg')
            Name = 'Media application'
            Vendor = 'Spotify AB / Apple Inc. / various'
            Family = 'Media applications'
            Class = 'Media'
            Essential = $false
            Description = 'A music, video or encoding application. Encoders and streaming software are CPU-bound by design.'
            Expected = 'Players are light; encoders will use every core they are given, correctly.'
            Guidance = 'An encode in progress is the machine doing its job - wait for it. Personal media software on a work machine, and the Apple/Bonjour services left behind by an iTunes install, are safe to remove.'
        }
        @{
            Id = 'app-gaming'
            Match = @('steam', 'steamwebhelper', 'steamservice', 'EpicGamesLauncher', 'EpicWebHelper',
                      'Origin', 'OriginWebHelperService', 'EADesktop', 'EABackgroundService', 'Battle.net',
                      'Battle.net Helper', 'UbisoftConnect', 'UbisoftGameLauncher', 'upc', 'RockstarService',
                      'SocialClubHelper', 'RobloxPlayerBeta', 'GalaxyClient', 'GalaxyClientService')
            Name = 'Game launcher or client'
            Vendor = 'Valve / Epic Games / EA / Blizzard / Ubisoft / Rockstar / Roblox'
            Family = 'Game launchers'
            Class = 'Gaming'
            Essential = $false
            Description = 'A game store and launcher. Each keeps a web helper resident to draw its storefront, and each runs a background update and cloud-save service.'
            Expected = 'Several hundred MB each, plus background downloads.'
            Guidance = 'On a work machine these are personal software and can be removed. Otherwise stop them starting with Windows - a launcher only needs to run when a game is being launched - and turn off automatic updates on a metered or slow connection.'
        }
        @{
            Id = 'app-torrent'
            Match = @('qbittorrent', 'utorrent', 'BitTorrent', 'transmission-qt', 'deluge', 'vuze')
            Name = 'BitTorrent client'
            Vendor = 'Various'
            Family = 'BitTorrent'
            Class = 'Media'
            Essential = $false
            Description = 'A peer-to-peer file transfer client. Holds many connections open and writes continuously to disk.'
            Expected = 'Heavy disk and network whenever it is running, whether or not anyone is watching.'
            Guidance = 'On a business machine this is almost always both a performance problem and a policy one. Where it is legitimate, cap the upload rate and connection count, and stop it starting with Windows - the connection count is usually what makes the network feel broken for everyone else.'
        }
        #endregion

        #region Software that exists to slow machines down --------------------------------------
        @{
            Id = 'pup-optimiser'
            Match = @('CCleaner', 'CCleanerBrowser', 'ccupdate', 'IObitUnlocker', 'Advanced SystemCare', 'ASCTray', 'DriverBooster', 'DriverEasy', 'DriverUpdate', 'PCOptimizer', 'SystemMechanic', 'iolo', 'WinZipDriverUpdater', 'RegClean', 'Restoro', 'Reimage', 'MyPCBackup', 'PCProtect', 'SegurazoUninstaller', 'WebCompanion', 'Wondershare', 'InstallCore')
            Name = 'PC "optimiser" or driver updater'
            Vendor = 'Various'
            Family = 'Optimiser software'
            Class = 'Unwanted'
            Essential = $false
            Description = 'Software that claims to speed up Windows. In practice it adds resident services, scheduled scans, nag screens and browser extensions, and its registry cleaning has no measurable benefit on a supported version of Windows.'
            Expected = 'Any resource use at all is pure loss.'
            Guidance = 'Remove it. This category is the clearest win in any resource report: it costs memory and CPU, it delivers nothing, and driver updaters in particular are a common cause of broken drivers. Windows Update and the management platform handle drivers.'
        }
        @{
            Id = 'pup-toolbar'
            Match = @('SearchProtect', 'Conduit', 'MindSpark', 'ShopperPro', 'PriceFountain', 'DNSUnlocker', 'AdChoices', 'Weatherbug', 'WeatherFace', 'OneLaunch', 'Wave Browser', 'wavesor', 'Bonanza', 'Bytefence', 'MyWebSearch')
            Name = 'Adware or browser hijacker'
            Vendor = 'Unknown'
            Family = 'Adware'
            Class = 'Unwanted'
            Essential = $false
            Description = 'Advertising or search-hijacking software, usually installed as a bundle with something else.'
            Expected = 'Nothing about this is expected.'
            Guidance = 'Remove it, and check the browsers for extensions and changed search providers it left behind. If the machine is managed, treat this as a finding worth reporting rather than just cleaning - it means a bundle installer ran.'
        }
        @{
            Id = 'pup-miner'
            NamePattern = '^(xmrig|nbminer|phoenixminer|t-rex|lolminer|cgminer|ethminer|minerd|cpuminer|nicehash|srbminer)'
            Priority = 5
            Name = 'Cryptocurrency miner'
            Vendor = 'Unknown'
            Family = 'Cryptocurrency mining'
            Class = 'Unwanted'
            Essential = $false
            Description = 'Software that consumes every available cycle to mine cryptocurrency.'
            Expected = 'Nothing. On a business machine this is either a compromise or a serious policy breach.'
            Guidance = 'Treat this as a security incident, not a performance problem. Isolate the machine and hand it to whoever handles incident response before cleaning anything up - how it got there matters more than the CPU it is using.'
        }
        #endregion

        #region Generic fallbacks (patterns, lowest priority) -----------------------------------
        @{
            Id = 'gen-installer'
            NamePattern = '(setup|install(er)?|msiexec|update(r)?|upgrade|patch)'
            Priority = 900
            Name = 'Installer or updater'
            Vendor = ''
            Family = 'Installers and updaters'
            Class = 'Installer'
            Essential = $false
            Description = 'An installation, update or patching process. Identified by its name, so the publisher below comes from the file itself.'
            Expected = 'Heavy CPU and disk while it runs, then gone.'
            Guidance = 'Let it finish and re-measure. An installer that has been running for hours has failed - check whether it is waiting on a prompt on another session. Several updaters resident at once is worth consolidating onto the patching platform.'
        }
        @{
            Id = 'gen-service-host'
            NamePattern = '(service|svc|agent|daemon|host|helper|tray|monitor)'
            Priority = 950
            Name = 'Background service or helper'
            Vendor = ''
            Family = 'Background helpers'
            Class = 'Vendor utility'
            Essential = $false
            Description = 'A background component of some installed application. Its name follows the usual convention for one; the publisher below is read from the file.'
            Expected = 'Low. A helper that is not low is worth naming.'
            Guidance = 'Work out which application it belongs to from the publisher and the path, then decide whether that application needs to be resident at all times. Most tray helpers and update monitors do not.'
        }
        #endregion
    )
}
