@{
    RootModule        = 'ResourceMonitor.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'c7a1f3d2-58b4-4e19-9d6c-2a7e51b8f043'
    Author            = 'boxIT'
    CompanyName       = 'boxIT'
    Copyright         = '(c) boxIT. All rights reserved.'
    Description       = 'Samples what a Windows machine is actually spending its CPU, memory, disk and network on, names every process and its manufacturer, works out which resource is the bottleneck, and builds an ordered plan to make the machine usable again.'
    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'Export-RmoReport'
        'Get-RmoProcessCatalogEntry'
        'Get-RmoProcessSample'
        'Get-RmoResourceHog'
        'Get-RmoServiceLoad'
        'Get-RmoStartupItem'
        'Get-RmoSystemHealthCheck'
        'Get-RmoSystemSnapshot'
        'Invoke-ResourceAnalysis'
        'Measure-RmoResourcePressure'
        'New-RmoIdentifier'
        'New-RmoRemediationPlan'
        'New-RmoRemediationScript'
        'Resolve-RmoProcessIdentity'
        'Show-ResourceMonitor'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags         = @('Performance', 'Processes', 'Memory', 'CPU', 'Windows', 'Triage', 'MSP')
            ReleaseNotes = 'Initial release: quick and complete resource scans, per-process CPU/memory/disk sampling, a catalogue of known processes with publishers, live publisher resolution from file metadata and Authenticode signatures, bottleneck determination, environment health checks, an ordered remediation plan, HTML/JSON/CSV reporting, a generated tuning script and a WinForms UI.'
        }
    }
}
