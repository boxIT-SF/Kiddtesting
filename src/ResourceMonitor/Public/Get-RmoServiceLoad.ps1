function Get-RmoServiceLoad {
    <#
        .SYNOPSIS
            Lists Windows services with the process each running one lives in.

        .DESCRIPTION
            This is what makes svchost.exe mean something. A report that says
            'svchost.exe - 31% CPU' is useless; 'svchost.exe hosting Windows Update (wuauserv),
            BITS and Delivery Optimization - 31% CPU' is a diagnosis.

            Also reports how many services are set to start automatically, which is the number
            that decides how long the machine takes to become usable after a restart.

        .PARAMETER ErrorSink
            Optional list; a failed query is recorded rather than thrown.

        .EXAMPLE
            Get-RmoServiceLoad | Where-Object State -eq 'Running' | Group-Object ProcessId
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([System.Collections.IList] $ErrorSink)

    $services = Invoke-RmoCim -ClassName 'Win32_Service' -ErrorSink $ErrorSink -Property @(
        'Name', 'DisplayName', 'State', 'StartMode', 'ProcessId', 'PathName', 'Description', 'DelayedAutoStart')

    foreach ($service in $services) {
        [pscustomobject]@{
            PSTypeName       = 'Rmo.Service'
            Name             = [string] (Get-RmoObjectValue $service 'Name' '')
            DisplayName      = [string] (Get-RmoObjectValue $service 'DisplayName' '')
            State            = [string] (Get-RmoObjectValue $service 'State' 'Unknown')
            StartMode        = [string] (Get-RmoObjectValue $service 'StartMode' 'Unknown')
            DelayedAutoStart = [bool] (Get-RmoObjectValue $service 'DelayedAutoStart' $false)
            ProcessId        = [int] (Get-RmoObjectValue $service 'ProcessId' 0)
            PathName         = [string] (Get-RmoObjectValue $service 'PathName' '')
            Description      = [string] (Get-RmoObjectValue $service 'Description' '')
        }
    }
}

function New-RmoServiceMap {
    <#
        .SYNOPSIS
            Builds a process-id to running-services lookup for the sampler.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Position = 0)] [AllowEmptyCollection()] [object[]] $Service)

    $map = @{}
    foreach ($item in $Service) {
        if ($item.State -ne 'Running' -or $item.ProcessId -le 0) { continue }
        $key = [int] $item.ProcessId
        if (-not $map.ContainsKey($key)) { $map[$key] = [System.Collections.Generic.List[object]]::new() }
        $map[$key].Add($item)
    }
    $map
}
