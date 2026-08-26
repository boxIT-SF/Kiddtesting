#Requires -Version 5.1
Set-StrictMode -Version Latest

$script:DsaModuleRoot = $PSScriptRoot
$script:DsaRuleCache = @{}
$script:DsaModuleVersion = '1.0.0'

foreach ($folder in 'Private', 'Public') {
    $dir = Join-Path $PSScriptRoot $folder
    if (-not (Test-Path -LiteralPath $dir)) { continue }
    foreach ($file in Get-ChildItem -LiteralPath $dir -Filter '*.ps1' -File | Sort-Object Name) {
        try {
            . $file.FullName
        } catch {
            throw "Failed to load '$($file.FullName)': $($_.Exception.Message)"
        }
    }
}

$public = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'Public') -Filter '*.ps1' -File |
    ForEach-Object { $_.BaseName })

Export-ModuleMember -Function $public
