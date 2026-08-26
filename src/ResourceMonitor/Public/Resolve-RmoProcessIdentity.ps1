function Resolve-RmoProcessIdentity {
    <#
        .SYNOPSIS
            Answers "what is this and who makes it" for one process.

        .DESCRIPTION
            Combines the curated catalogue with what the executable says about itself:

              Catalogue   a name a person wrote, a normalised publisher, what normal looks like,
                          and what to do when this process is the problem.
              The file    CompanyName, FileDescription and ProductName from the version resource,
                          and - on a complete scan - the name on the Authenticode signature.

            The catalogue is preferred for the description and the guidance, because it is the
            only source that knows what to *do*. The publisher is chosen differently: a verified
            signature beats the catalogue when the catalogue is only holding a placeholder such as
            'Various', because at that point the file knows the specific answer and the catalogue
            does not.

            Anything the catalogue has never heard of still gets a name and a manufacturer, from
            the file. Only a process whose executable cannot be read at all comes back unknown -
            which on an unelevated scan mostly means it belongs to another user.

        .PARAMETER Name
            Process name, without the .exe.

        .PARAMETER Path
            Full path to the executable, when it could be read.

        .PARAMETER Identifier
            A compiled identifier from New-RmoIdentifier.

        .PARAMETER VerifySignature
            Read the Authenticode signature as well as the version resource. Slower.

        .PARAMETER ErrorSink
            Optional list for files that could not be read.

        .EXAMPLE
            Resolve-RmoProcessIdentity -Name svchost -Path C:\Windows\System32\svchost.exe -Identifier $id
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory, Position = 0)] [AllowEmptyString()] [string] $Name,
        [Parameter(Position = 1)] [AllowEmptyString()] [AllowNull()] [string] $Path,
        [Parameter(Mandatory)] [psobject] $Identifier,
        [switch] $VerifySignature,
        [System.Collections.IList] $ErrorSink
    )

    $normalizedPath = ConvertTo-RmoNormalizedPath $Path
    $entry = $null

    # Exact process name first. A PathPattern on the entry acts as a guard: two unrelated
    # programs shipping the same generic executable name should not inherit each other's advice.
    if ($Name -and $Identifier.Exact.ContainsKey($Name)) {
        $candidate = $Identifier.Exact[$Name]
        if ($null -eq $candidate.PathRegex -or
            ($normalizedPath -and $candidate.PathRegex.IsMatch($normalizedPath))) {
            $entry = $candidate.Entry
        }
    }

    if ($null -eq $entry) {
        foreach ($pattern in $Identifier.Patterns) {
            if (-not $pattern.NameRegex.IsMatch($Name)) { continue }
            if ($null -ne $pattern.PathRegex) {
                if (-not $normalizedPath -or -not $pattern.PathRegex.IsMatch($normalizedPath)) { continue }
            }
            $entry = $pattern.Entry
            break
        }
    }

    $publisher = Get-RmoPublisherInfo -Path $Path -VerifySignature:$VerifySignature.IsPresent -ErrorSink $ErrorSink

    # 'Various' and a slash-separated list are placeholders on entries that cover a family of
    # products from different vendors. Where the file can name the actual publisher, it wins.
    $catalogVendor = if ($null -ne $entry) { $entry.Vendor } else { '' }
    $catalogVendorIsPlaceholder = (-not $catalogVendor) -or
                                  $catalogVendor -eq 'Various' -or
                                  $catalogVendor -eq 'Unknown' -or
                                  $catalogVendor.Contains(' / ')

    $fileVendor = ''
    $vendorSource = 'None'
    if ($publisher.SignerName) {
        $fileVendor = $publisher.SignerName
        $vendorSource = 'Authenticode signature'
    } elseif ($publisher.Company) {
        $fileVendor = $publisher.Company
        $vendorSource = 'File version information'
    }

    if ($catalogVendorIsPlaceholder -and $fileVendor) {
        $vendor = $fileVendor
    } elseif ($catalogVendor) {
        $vendor = $catalogVendor
        $vendorSource = 'Catalogue'
    } elseif ($fileVendor) {
        $vendor = $fileVendor
    } else {
        $vendor = 'Unknown'
        $vendorSource = 'None'
    }

    if ($null -ne $entry) {
        $displayName = $entry.Name
        $description = $entry.Description
        # A generic entry matched by pattern gets whatever specific name the file carries.
        if ($entry.Priority -ge 900 -and $publisher.FileDescription) {
            $displayName = $publisher.FileDescription
        }
        [pscustomobject]@{
            PSTypeName      = 'Rmo.ProcessIdentity'
            ProcessName     = $Name
            Name            = $displayName
            Vendor          = $vendor
            VendorSource    = $vendorSource
            Family          = $entry.Family
            Class           = $entry.Class
            Essential       = $entry.Essential
            Description     = $description
            Expected        = $entry.Expected
            Guidance        = $entry.Guidance
            Command         = $entry.Command
            CatalogId       = $entry.Id
            Confidence      = $(if ($entry.Priority -ge 900) { 'Generic' } else { 'Catalogued' })
            Signed          = $publisher.Signed
            SignatureStatus = $publisher.SignatureStatus
            ProductName     = $publisher.ProductName
            FileVersion     = $publisher.FileVersion
            ExecutablePath  = $Path
        }
        return
    }

    # Nothing in the catalogue. Build the best description the file itself supports.
    $displayName = $Name
    if ($publisher.FileDescription) {
        $displayName = $publisher.FileDescription
    } elseif ($publisher.ProductName) {
        $displayName = $publisher.ProductName
    }

    $descriptionParts = [System.Collections.Generic.List[string]]::new()
    if ($publisher.FileDescription) { $descriptionParts.Add($publisher.FileDescription + '.') }
    if ($publisher.ProductName -and $publisher.ProductName -ne $publisher.FileDescription) {
        $descriptionParts.Add("Part of $($publisher.ProductName).")
    }
    if ($vendor -ne 'Unknown') { $descriptionParts.Add("Published by $vendor.") }
    if ($descriptionParts.Count -eq 0) {
        $descriptionParts.Add('Not in the catalogue, and the executable carries no version information to describe itself.')
        if (-not $Path) {
            $descriptionParts.Add('Its path could not be read, which usually means it belongs to another user or to the system - run the scan elevated to see it.')
        }
    }

    $confidence = if ($publisher.Readable) { 'File metadata' } else { 'Unknown' }
    $guidance = if ($vendor -eq 'Unknown' -and (Test-RmoUserWritablePath $Path)) {
        'Unidentified, unsigned, and running from a location any user can write to. Worth confirming what it is before deciding anything else about it.'
    } else {
        'Not in the catalogue. Identify it from the publisher, the product name and the command line, then decide whether it needs to be resident.'
    }

    [pscustomobject]@{
        PSTypeName      = 'Rmo.ProcessIdentity'
        ProcessName     = $Name
        Name            = $displayName
        Vendor          = $vendor
        VendorSource    = $vendorSource
        Family          = $(if ($publisher.ProductName) { $publisher.ProductName } else { $Name })
        Class           = 'Unknown'
        Essential       = $false
        Description     = ($descriptionParts -join ' ')
        Expected        = ''
        Guidance        = $guidance
        Command         = ''
        CatalogId       = ''
        Confidence      = $confidence
        Signed          = $publisher.Signed
        SignatureStatus = $publisher.SignatureStatus
        ProductName     = $publisher.ProductName
        FileVersion     = $publisher.FileVersion
        ExecutablePath  = $Path
    }
}
