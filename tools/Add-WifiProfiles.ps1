<#
.SYNOPSIS
    Pre-loads one or more Wi-Fi profiles on a Windows device so it joins the client's SSIDs
    automatically, for every user, the first time it is in range. Built to run from NinjaOne
    as SYSTEM during a new computer deployment.

.DESCRIPTION
    Each profile is installed machine-wide (all users) with connection mode "auto", so the
    device connects at the logon screen without anyone typing a key.

    The SSID list is JSON - an array of objects:

        [
          { "ssid": "Client-Corp",  "auth": "WPA2PSK", "key": "<passphrase>" },
          { "ssid": "Client-Site2", "auth": "WPA3SAE", "key": "<passphrase>", "hidden": true },
          { "ssid": "Client-Guest", "auth": "open",    "autoConnect": false }
        ]

        ssid         required. Case-sensitive, 1-32 bytes.
        auth         WPA2PSK (default), WPA3SAE or open. For a WPA2/WPA3 mixed-mode SSID use
                     WPA2PSK. WPA3SAE needs Windows 10 2004 or later and a capable adapter.
        key          required unless auth is open. 8-63 character passphrase, or 64 hex digits.
        hidden       true if the SSID does not broadcast. Default false.
        autoConnect  false to install the profile without auto-joining. Default true.

    Array order is preference order: the first SSID is tried first when several are in range.

    The JSON is taken from the first of these that is supplied:

        1. -CustomField   a NinjaOne custom field read on the device with Ninja-Property-Get.
                          Use a SECURE field at organisation or location level so one script
                          serves every client and the keys never sit in the script or the repo.
        2. -ConfigJson    the JSON as a string (e.g. a NinjaOne script variable).
        3. -ConfigPath    a JSON file on the device.
        4. the wifiProfilesJson environment variable (NinjaOne script variable of that name).

    Keys are never written to the output. The temporary profile XML holds the key in clear
    text for the moment netsh needs it; it is written to a folder only SYSTEM and
    Administrators can read and is deleted before the script ends.

    802.1X / WPA2-Enterprise SSIDs are deliberately not handled - those need certificates or
    credentials and belong in Intune or Group Policy, not a script.

    Exit codes:

        0  every profile is installed (or the device has no Wi-Fi adapter - nothing to do)
        1  at least one profile failed to install
        2  the configuration was missing or invalid; nothing was changed

.PARAMETER CustomField
    Name of the NinjaOne custom field that holds the JSON.

.PARAMETER ConfigJson
    The JSON as a string.

.PARAMETER ConfigPath
    Path to a JSON file.

.PARAMETER ValidateOnly
    Parse and validate the configuration and list what would be installed. Changes nothing.

.EXAMPLE
    .\Add-WifiProfiles.ps1 -CustomField wifiProfiles

.EXAMPLE
    .\Add-WifiProfiles.ps1 -ConfigPath C:\Deploy\wifi.json -ValidateOnly
#>
[CmdletBinding()]
param(
    [string]$CustomField,
    [string]$ConfigJson,
    [string]$ConfigPath,
    [switch]$ValidateOnly
)

$ErrorActionPreference = 'Stop'

function Get-WifiConfigJson {
    if ($CustomField) {
        if (-not (Get-Command Ninja-Property-Get -ErrorAction SilentlyContinue)) {
            throw "Ninja-Property-Get is not available. -CustomField only works when run by the NinjaOne agent."
        }
        $value = (Ninja-Property-Get $CustomField) -join "`n"
        if ([string]::IsNullOrWhiteSpace($value)) {
            throw "NinjaOne custom field '$CustomField' is empty or not readable by automations."
        }
        return $value
    }
    if ($ConfigJson) { return $ConfigJson }
    if ($ConfigPath) {
        if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Config file not found: $ConfigPath" }
        return Get-Content -LiteralPath $ConfigPath -Raw
    }
    if ($env:wifiProfilesJson) { return $env:wifiProfilesJson }
    throw 'No configuration supplied. Use -CustomField, -ConfigJson, -ConfigPath or the wifiProfilesJson variable.'
}

function ConvertTo-WifiProfileSpec {
    # Validates the raw JSON and returns normalised profile objects. Throws on the first problem
    # so a bad config never results in a half-configured device.
    param([Parameter(Mandatory)][string]$Json)

    try { $items = @($Json | ConvertFrom-Json) }
    catch { throw "Configuration is not valid JSON: $($_.Exception.Message)" }
    if ($items.Count -eq 0) { throw 'Configuration contains no SSIDs.' }

    $seen = @{}
    $index = 0
    foreach ($item in $items) {
        $index++
        $ssid = [string]$item.ssid
        if ([string]::IsNullOrEmpty($ssid)) { throw "Entry ${index}: ssid is missing." }
        $ssidBytes = [System.Text.Encoding]::UTF8.GetBytes($ssid)
        if ($ssidBytes.Length -gt 32) { throw "Entry $index ('$ssid'): SSID is longer than 32 bytes." }
        if ($seen.ContainsKey($ssid)) { throw "Entry $index ('$ssid'): SSID is listed more than once." }
        $seen[$ssid] = $true

        $auth = if ($item.auth) { ([string]$item.auth).ToUpperInvariant() } else { 'WPA2PSK' }
        if ($auth -notin 'WPA2PSK', 'WPA3SAE', 'OPEN') {
            throw "Entry $index ('$ssid'): auth '$($item.auth)' is not supported. Use WPA2PSK, WPA3SAE or open."
        }

        $key = [string]$item.key
        $keyType = $null
        if ($auth -eq 'OPEN') {
            if ($key) { throw "Entry $index ('$ssid'): auth is open but a key was supplied." }
        }
        elseif ($key -match '^[0-9A-Fa-f]{64}$' -and $auth -eq 'WPA2PSK') {
            $keyType = 'networkKey'
        }
        elseif ($key.Length -ge 8 -and $key.Length -le 63) {
            $keyType = 'passPhrase'
        }
        else {
            throw "Entry $index ('$ssid'): key must be an 8-63 character passphrase."
        }

        [pscustomobject]@{
            Ssid        = $ssid
            SsidHex     = -join ($ssidBytes | ForEach-Object { $_.ToString('X2') })
            Auth        = $auth
            Key         = $key
            KeyType     = $keyType
            Hidden      = ($item.hidden -eq $true)
            AutoConnect = ($item.autoConnect -ne $false)
        }
    }
}

function New-WifiProfileXml {
    param([Parameter(Mandatory)]$Spec)

    $esc = { param($s) [System.Security.SecurityElement]::Escape($s) }
    $name = & $esc $Spec.Ssid
    $mode = if ($Spec.AutoConnect) { 'auto' } else { 'manual' }
    $nonBroadcast = if ($Spec.Hidden) { 'true' } else { 'false' }

    if ($Spec.Auth -eq 'OPEN') {
        $security = @"
            <authEncryption>
                <authentication>open</authentication>
                <encryption>none</encryption>
                <useOneX>false</useOneX>
            </authEncryption>
"@
    }
    else {
        $security = @"
            <authEncryption>
                <authentication>$($Spec.Auth)</authentication>
                <encryption>AES</encryption>
                <useOneX>false</useOneX>
            </authEncryption>
            <sharedKey>
                <keyType>$($Spec.KeyType)</keyType>
                <protected>false</protected>
                <keyMaterial>$(& $esc $Spec.Key)</keyMaterial>
            </sharedKey>
"@
    }

    @"
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
    <name>$name</name>
    <SSIDConfig>
        <SSID>
            <hex>$($Spec.SsidHex)</hex>
            <name>$name</name>
        </SSID>
        <nonBroadcast>$nonBroadcast</nonBroadcast>
    </SSIDConfig>
    <connectionType>ESS</connectionType>
    <connectionMode>$mode</connectionMode>
    <MSM>
        <security>
$security
        </security>
    </MSM>
</WLANProfile>
"@
}

function Get-WlanInterfaceName {
    # Names of the wireless interfaces as netsh knows them. Empty when there is no adapter
    # or the WLAN AutoConfig service is not running.
    $lines = & netsh.exe wlan show interfaces 2>$null
    if ($LASTEXITCODE -ne 0) { return @() }
    @($lines | Where-Object { $_ -match '^\s+Name\s+:\s+(.+?)\s*$' } | ForEach-Object { $Matches[1] })
}

# ---------------------------------------------------------------------------------------------

try {
    $specs = @(ConvertTo-WifiProfileSpec -Json (Get-WifiConfigJson))
}
catch {
    Write-Output "CONFIG ERROR: $($_.Exception.Message)"
    exit 2
}

Write-Output "Wi-Fi profiles requested: $($specs.Count)"
foreach ($s in $specs) {
    Write-Output ("  {0}  auth={1}  hidden={2}  autoConnect={3}" -f $s.Ssid, $s.Auth, $s.Hidden, $s.AutoConnect)
}
if ($ValidateOnly) {
    Write-Output 'ValidateOnly: configuration is valid. Nothing was changed.'
    exit 0
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Output 'ERROR: must run elevated (SYSTEM or Administrator) to install all-user profiles.'
    exit 1
}

$wlanSvc = Get-Service -Name WlanSvc -ErrorAction SilentlyContinue
if ($wlanSvc -and $wlanSvc.Status -ne 'Running') {
    try { Start-Service -Name WlanSvc; Start-Sleep -Seconds 3 } catch { }
}
$interfaces = @(Get-WlanInterfaceName)
if ($interfaces.Count -eq 0) {
    Write-Output 'No Wi-Fi adapter found (or WLAN AutoConfig is not running). Nothing to do.'
    exit 0
}
Write-Output "Wi-Fi interfaces: $($interfaces -join ', ')"

# Working folder readable only by SYSTEM and Administrators - the XML holds keys in clear text.
$workDir = Join-Path $env:ProgramData ("boxIT-wifi-" + [guid]::NewGuid().ToString('N'))
$failed = @()
try {
    New-Item -ItemType Directory -Path $workDir -Force | Out-Null
    & icacls.exe $workDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not secure working folder $workDir." }

    $n = 0
    foreach ($s in $specs) {
        $n++
        $xmlPath = Join-Path $workDir "profile$n.xml"
        # UTF-8 without BOM; netsh rejects some encodings.
        [System.IO.File]::WriteAllText($xmlPath, (New-WifiProfileXml -Spec $s), (New-Object System.Text.UTF8Encoding($false)))

        $out = & netsh.exe wlan add profile "filename=$xmlPath" user=all 2>&1
        $code = $LASTEXITCODE
        Remove-Item -LiteralPath $xmlPath -Force -ErrorAction SilentlyContinue

        if ($code -eq 0) {
            Write-Output "OK      $($s.Ssid)"
        }
        else {
            Write-Output "FAILED  $($s.Ssid): $(($out | Out-String).Trim())"
            $failed += $s.Ssid
        }
    }
}
finally {
    Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
}

# Preference order = config order. Best effort: a failure here does not stop auto-connect.
$installed = @($specs | Where-Object { $_.Ssid -notin $failed })
foreach ($iface in $interfaces) {
    $priority = 0
    foreach ($s in $installed) {
        $priority++
        & netsh.exe wlan set profileorder "name=$($s.Ssid)" "interface=$iface" "priority=$priority" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Output "WARN    could not set priority for $($s.Ssid) on $iface" }
    }
}

if ($failed.Count -gt 0) {
    Write-Output "RESULT: $($failed.Count) of $($specs.Count) profile(s) failed: $($failed -join ', ')"
    exit 1
}
Write-Output "RESULT: all $($specs.Count) profile(s) installed for all users."
exit 0
