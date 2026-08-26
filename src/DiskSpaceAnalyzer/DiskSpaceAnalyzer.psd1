@{
    RootModule        = 'DiskSpaceAnalyzer.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '4b1d9f1e-7c2a-4a45-9a0e-6f9c3d2b8e71'
    Author            = 'boxIT'
    CompanyName       = 'boxIT'
    Copyright         = '(c) boxIT. All rights reserved.'
    Description       = 'Scans Windows volumes, identifies what the oldest and largest data actually is, rates whether each class of data is safe to delete, and builds a remediation plan sized to keep the volume healthy for a chosen number of months.'
    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'Export-DsaReport'
        'Get-DsaClassificationRule'
        'Get-DsaFileInventory'
        'Get-DsaSystemReclaimOpportunity'
        'Get-DsaVolumeInfo'
        'Invoke-DiskSpaceAnalysis'
        'Measure-DsaGrowthRate'
        'Measure-DsaInventory'
        'New-DsaClassifier'
        'New-DsaRemediationScript'
        'New-DsaSpacePlan'
        'Remove-DsaClassifiedFile'
        'Resolve-DsaFileCategory'
        'Show-DiskSpaceAnalyzer'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags         = @('Disk', 'Storage', 'Cleanup', 'Windows', 'Capacity', 'MSP')
            ReleaseNotes = 'Initial release: scanner, classification rule set, age profiling, growth estimation, six-month capacity plan, HTML/JSON/CSV reporting, remediation script generation and a WinForms UI.'
        }
    }
}
