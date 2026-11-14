<#
.SYNOPSIS
    Moves a Windows device from one NinjaOne instance to another. Pushed from the CURRENT
    (source) NinjaOne instance as a SYSTEM script.

.DESCRIPTION
    Two NinjaOne agents cannot coexist, and removing the source agent kills any script it is
    running. So this runs in two phases:

      Stage   (run by the source agent)  Preflight, download and validate the new installer,
                                         then hand off to a one-time SYSTEM scheduled task.
      Execute (run by the scheduled task) Remove the source agent, install the destination
                                         agent, verify the service, roll back on failure.

    Nothing is removed until the destination installer is on disk, signature-checked, and the
    destination instance is reachable.

    Values can be passed as parameters or as NinjaOne script variables (environment variables
    newInstallerUrl, newTokenId, rollbackInstallerUrl, instanceHost, preflightOnly).

.PARAMETER NewInstallerUrl
    HTTPS URL of the DESTINATION instance MSI. Either an org/location-specific installer URL,
    or the generic installer used together with -NewTokenId.

.PARAMETER NewTokenId
    Destination org/location token, when using the generic MSI (passed as TOKENID=).

.PARAMETER RollbackInstallerUrl
    HTTPS URL of the SOURCE instance org/location MSI. If the destination install fails, this
    is reinstalled so the device is not orphaned. Strongly recommended.

.PARAMETER InstanceHost
    Destination instance hostname to test on 443 (e.g. app.ninjarmm.com, eu.ninjarmm.com).
    Defaults to the host in NewInstallerUrl.

.PARAMETER PreflightOnly
    Run every check and download, change nothing. Use this for the pilot pass.

.EXAMPLE
    .\Migrate-NinjaAgent.ps1 -NewInstallerUrl 'https://app.ninjarmm.com/agent/installer/<id>/<name>.msi' -RollbackInstallerUrl 'https://app.ninjarmm.com/agent/installer/<old-id>/<old-name>.msi' -PreflightOnly

.NOTES
    Exit codes (Stage): 0 staged / preflight passed, 1 preflight failed (nothing changed).
    Result of Execute is in C:\ProgramData\NinjaMigration\migration.log and result.json.
    Uninstall prevention must be OFF in the source policy, or the removal step will fail and
    the script will leave the source agent in place.
#>
[CmdletBinding()]
param(
    [string]$NewInstallerUrl,
    [string]$NewTokenId,
    [string]$RollbackInstallerUrl,
    [string]$InstanceHost,
    [switch]$PreflightOnly,
    [switch]$SkipSignatureCheck,
    [switch]$Force,
    [ValidateSet('Stage', 'Execute')]
    [string]$Phase = 'Stage'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$WorkDir     = Join-Path $env:ProgramData 'NinjaMigration'
$LogFile     = Join-Path $WorkDir 'migration.log'
$ConfigFile  = Join-Path $WorkDir 'config.json'
$ResultFile  = Join-Path $WorkDir 'result.json'
$NewMsi      = Join-Path $WorkDir 'destination-agent.msi'
$RollbackMsi = Join-Path $WorkDir 'rollback-agent.msi'
$TaskName    = 'NinjaAgentMigration'
$ServiceName = 'NinjaRMMAgent'

# NinjaOne script variables arrive as environment variables.
if (-not $NewInstallerUrl      -and $env:newInstallerUrl)      { $NewInstallerUrl      = $env:newInstallerUrl }
if (-not $NewTokenId           -and $env:newTokenId)           { $NewTokenId           = $env:newTokenId }
if (-not $RollbackInstallerUrl -and $env:rollbackInstallerUrl) { $RollbackInstallerUrl = $env:rollbackInstallerUrl }
if (-not $InstanceHost         -and $env:instanceHost)         { $InstanceHost         = $env:instanceHost }
if ($env:preflightOnly -eq 'true') { $PreflightOnly = $true }

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] [{2}] {3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Phase, $Level, $Message
    Write-Output $line
    try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 } catch { }
}

function Get-AgentInfo {
    $info = [ordered]@{ Installed = $false; Location = $null; ProductCode = $null; Version = $null }
    foreach ($key in 'HKLM:\SOFTWARE\WOW6432Node\NinjaRMM LLC\NinjaRMMAgent', 'HKLM:\SOFTWARE\NinjaRMM LLC\NinjaRMMAgent') {
        $loc = (Get-ItemProperty -Path $key -ErrorAction SilentlyContinue).Location
        if ($loc) { $info.Location = $loc.Trim('"'); break }
    }
    if (-not $info.Location) {
        $svc = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" -ErrorAction SilentlyContinue
        if ($svc.PathName -match '^"?(.+?)\\NinjaRMMAgent\.exe') { $info.Location = $Matches[1] }
    }
    $uninstallRoots = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                      'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    $entry = Get-ItemProperty -Path $uninstallRoots -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like 'NinjaRMMAgent*' -or $_.DisplayName -like 'NinjaOne Agent*' } |
        Select-Object -First 1
    if ($entry) {
        $info.Version = $entry.DisplayVersion
        if ($entry.PSChildName -match '^\{[0-9A-Fa-f-]{36}\}$') { $info.ProductCode = $entry.PSChildName }
    }
    $info.Installed = [bool](Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) -or [bool]$entry
    [pscustomobject]$info
}

function Get-Installer {
    param([string]$Url, [string]$Path, [switch]$NoSignatureCheck)
    $label = Split-Path $Path -Leaf
    if ($Url -notmatch '^https://') { throw "[$label] Installer URL must be HTTPS." }
    $uri = [uri]$Url
    # Log host and path only. The full URL can carry a token.
    $safeUrl = '{0}{1}' -f $uri.Host, ($uri.AbsolutePath -replace '/installer/[^/]+/', '/installer/<id>/')
    if ($uri.Query -match 'X-Amz-|Signature=|Expires=|sig=') {
        throw "[$label] URL is a short-lived signed download link (copied from browser downloads?), not the NinjaOne installer link. Use Copy Link from the Add Device / installer screen in the console."
    }
    if (Test-Path $Path) { Remove-Item $Path -Force }
    try {
        Invoke-WebRequest -Uri $Url -OutFile $Path -UseBasicParsing -UserAgent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
    } catch {
        $status = $null
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        $hint = switch ($status) {
            403     { 'Link rejected: installer link expired, regenerated, or disabled in the console, or a web filter on this network blocked it. Open the same URL in a private browser window off this network to tell which.' }
            404     { 'Installer not found: wrong or truncated URL, or the org/location was changed.' }
            default { 'Check the URL and any proxy or web filter on this device.' }
        }
        throw "[$label] Download from $safeUrl failed (HTTP $status). $hint"
    }
    $size = (Get-Item $Path).Length
    if ($size -lt 1MB) { throw "[$label] Download from $safeUrl is only $size bytes. Not a valid agent MSI (expired or wrong link?)." }
    if (-not $NoSignatureCheck) {
        $sig = Get-AuthenticodeSignature -FilePath $Path
        if ($sig.Status -ne 'Valid') { throw "Signature on $Path is '$($sig.Status)'. Refusing to use it." }
        if ($sig.SignerCertificate.Subject -notmatch 'NinjaOne|NinjaRMM') {
            throw "Installer is signed by '$($sig.SignerCertificate.Subject)', not NinjaOne. Refusing to use it."
        }
    }
    Write-Log "Downloaded and validated $(Split-Path $Path -Leaf) ($([math]::Round($size / 1MB, 1)) MB)."
}

function Invoke-Msi {
    param([string]$Arguments)
    $p = Start-Process -FilePath "$env:SystemRoot\System32\msiexec.exe" -ArgumentList $Arguments -Wait -PassThru -WindowStyle Hidden
    $p.ExitCode
}

function Install-Agent {
    param([string]$MsiPath, [string]$TokenId, [string]$Label)
    $log  = Join-Path $WorkDir "install-$Label.log"
    $msiArgs = "/i `"$MsiPath`" /qn /norestart /L*v `"$log`""
    if ($TokenId) { $msiArgs += " TOKENID=`"$TokenId`"" }
    $code = Invoke-Msi $msiArgs
    Write-Log "msiexec install ($Label) exit code $code."
    if ($code -notin 0, 3010, 1641) { return $false }
    # Service present and running within 5 minutes.
    $deadline = (Get-Date).AddMinutes(5)
    while ((Get-Date) -lt $deadline) {
        $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') { return $true }
        if ($svc -and $svc.Status -eq 'Stopped') { Start-Service -Name $ServiceName -ErrorAction SilentlyContinue }
        Start-Sleep -Seconds 10
    }
    $false
}

function Remove-Agent {
    $agent = Get-AgentInfo
    if (-not $agent.Installed) { Write-Log 'No existing agent found. Nothing to remove.'; return $true }
    Write-Log "Removing agent $($agent.Version) at '$($agent.Location)'."

    $exe = if ($agent.Location) { Join-Path $agent.Location 'NinjaRMMAgent.exe' }
    if ($exe -and (Test-Path $exe)) {
        Start-Process -FilePath $exe -ArgumentList '-disableUninstallPrevention', 'NOUI' -Wait -WindowStyle Hidden -ErrorAction SilentlyContinue
    }
    if ($agent.ProductCode) {
        $code = Invoke-Msi "/x $($agent.ProductCode) /qn /norestart /L*v `"$(Join-Path $WorkDir 'uninstall.log')`""
        Write-Log "msiexec uninstall exit code $code."
    }
    $uninstaller = if ($agent.Location) { Join-Path $agent.Location 'uninstall.exe' }
    if ($uninstaller -and (Test-Path $uninstaller)) {
        Start-Process -FilePath $uninstaller -ArgumentList '--mode', 'unattended' -Wait -WindowStyle Hidden -ErrorAction SilentlyContinue
        Write-Log 'Ran uninstall.exe fallback.'
    }

    $deadline = (Get-Date).AddMinutes(3)
    while ((Get-Date) -lt $deadline -and (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue)) { Start-Sleep -Seconds 5 }
    if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
        Write-Log 'Agent service still present after uninstall. Uninstall prevention is probably still on in the source policy.' 'ERROR'
        return $false
    }

    # Clear leftovers so the destination agent registers as a new node, not with stale identity.
    Get-Process -Name 'NinjaRMMAgent*', 'NinjaRMMProxyProcess*' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    $leftovers = @((Join-Path $env:ProgramData 'NinjaRMMAgent'), $agent.Location,
                   'HKLM:\SOFTWARE\WOW6432Node\NinjaRMM LLC', 'HKLM:\SOFTWARE\NinjaRMM LLC') | Where-Object { $_ }
    foreach ($item in $leftovers) {
        if (Test-Path $item) { Remove-Item -Path $item -Recurse -Force -ErrorAction SilentlyContinue }
    }
    Write-Log 'Source agent removed.'
    $true
}

function Save-Result {
    param([string]$Status, [string]$Detail)
    [pscustomobject]@{ Status = $Status; Detail = $Detail; Computer = $env:COMPUTERNAME; Time = (Get-Date).ToString('s') } |
        ConvertTo-Json | Set-Content -Path $ResultFile -Encoding UTF8
    Write-Log "RESULT: $Status. $Detail" $(if ($Status -eq 'Migrated') { 'INFO' } else { 'ERROR' })
}

# ---------------------------------------------------------------------------------------------
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
if (-not (Test-Path $WorkDir)) { New-Item -Path $WorkDir -ItemType Directory -Force | Out-Null }

if ($Phase -eq 'Stage') {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        if (-not ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            throw 'Must run elevated (run as SYSTEM from NinjaOne).'
        }
        # The work folder holds the installer token. SYSTEM and Administrators only.
        & icacls.exe $WorkDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null

        if (-not $NewInstallerUrl) { throw 'NewInstallerUrl is required.' }
        if ((Test-Path $ResultFile) -and -not $Force) {
            $prior = Get-Content $ResultFile -Raw | ConvertFrom-Json
            if ($prior.Status -eq 'Migrated') { Write-Log "Already migrated on $($prior.Time). Use -Force to run again."; exit 0 }
        }
        if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
            if (-not $Force) { throw "Scheduled task '$TaskName' already exists. A migration is in flight. Use -Force to restage." }
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        }

        $agent = Get-AgentInfo
        Write-Log "Source agent: installed=$($agent.Installed) version=$($agent.Version) location='$($agent.Location)' productCode=$($agent.ProductCode)"
        if (-not $agent.Installed) { Write-Log 'No source agent detected. Will install the destination agent only.' 'WARN' }

        $pending = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
                   (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
        if ($pending) { Write-Log 'Reboot pending on this device. MSI operations can fail with 1618. Reboot first if the pilot shows failures.' 'WARN' }

        if (-not $InstanceHost) { $InstanceHost = ([uri]$NewInstallerUrl).Host }
        $tcp = New-Object Net.Sockets.TcpClient
        try {
            if (-not $tcp.ConnectAsync($InstanceHost, 443).Wait(10000)) { throw "Cannot reach $InstanceHost on 443." }
        } finally { $tcp.Close() }
        Write-Log "Destination instance $InstanceHost reachable on 443."

        Get-Installer -Url $NewInstallerUrl -Path $NewMsi -NoSignatureCheck:$SkipSignatureCheck
        if ($RollbackInstallerUrl) {
            Get-Installer -Url $RollbackInstallerUrl -Path $RollbackMsi -NoSignatureCheck:$SkipSignatureCheck
        } else {
            Write-Log 'No RollbackInstallerUrl supplied. If the destination install fails, this device will have NO RMM agent.' 'WARN'
        }

        if ($PreflightOnly) {
            Remove-Item $NewMsi, $RollbackMsi -Force -ErrorAction SilentlyContinue
            Write-Log 'PREFLIGHT PASSED. No changes made.'
            exit 0
        }

        $staged = Join-Path $WorkDir 'Migrate-NinjaAgent.ps1'
        if ($PSCommandPath -ne $staged) { Copy-Item -Path $PSCommandPath -Destination $staged -Force }
        [pscustomobject]@{ NewTokenId = $NewTokenId; HasRollback = [bool]$RollbackInstallerUrl } |
            ConvertTo-Json | Set-Content -Path $ConfigFile -Encoding UTF8

        $action    = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
                         -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$staged`" -Phase Execute"
        $trigger   = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2)
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
                         -ExecutionTimeLimit (New-TimeSpan -Hours 1)
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null

        Write-Log "STAGED. Cutover runs in 2 minutes via scheduled task '$TaskName'. This device will drop from the source instance."
        exit 0
    } catch {
        Write-Log "PREFLIGHT FAILED. Nothing was changed. $($_.Exception.Message)" 'ERROR'
        exit 1
    }
}

# ------------------------------------- Execute phase -----------------------------------------
$exitCode = 1
try {
    $config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
    if (-not (Test-Path $NewMsi)) { throw 'Destination installer missing from work folder. Aborting before removal.' }

    if (-not (Remove-Agent)) {
        Save-Result 'Failed-SourceIntact' 'Source agent could not be removed. Device is still in the source instance. Turn off uninstall prevention in the source policy and rerun.'
    } elseif (Install-Agent -MsiPath $NewMsi -TokenId $config.NewTokenId -Label 'destination') {
        Save-Result 'Migrated' 'Destination agent installed and service running. Confirm check-in in the destination console.'
        $exitCode = 0
    } elseif ($config.HasRollback -and (Test-Path $RollbackMsi)) {
        Write-Log 'Destination install failed. Rolling back to the source instance.' 'ERROR'
        Remove-Agent | Out-Null
        if (Install-Agent -MsiPath $RollbackMsi -Label 'rollback') {
            Save-Result 'RolledBack' 'Destination install failed. Source agent reinstalled. See install-destination.log.'
        } else {
            Save-Result 'Failed-Orphaned' 'Destination install AND rollback failed. Device has no RMM agent. Needs hands-on recovery.'
        }
    } else {
        Save-Result 'Failed-Orphaned' 'Destination install failed and no rollback installer was staged. Device has no RMM agent.'
    }
} catch {
    Save-Result 'Failed-Error' $_.Exception.Message
} finally {
    # Remove the token and installers. Keep logs and result.json for audit.
    Remove-Item $ConfigFile, $NewMsi, $RollbackMsi -Force -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
}
exit $exitCode
