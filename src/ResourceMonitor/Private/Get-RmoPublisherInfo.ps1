function Get-RmoSignerName {
    <#
        .SYNOPSIS
            Pulls the organisation name out of a certificate subject.
        .DESCRIPTION
            A subject looks like 'CN=Google LLC, O=Google LLC, L=Mountain View, S=California, C=US'.
            The CN of a code-signing certificate is the legal name of the publisher, which is the
            most trustworthy manufacturer attribution available on the machine - it is checked by
            a certificate authority, unlike the company name compiled into the file.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)] [AllowEmptyString()] [AllowNull()] [string] $Subject)

    if ([string]::IsNullOrWhiteSpace($Subject)) { return '' }

    # CN values containing a comma are quoted, so take everything up to an unquoted comma.
    $match = [regex]::Match($Subject, '(?:^|,)\s*CN=(?<cn>"[^"]*"|[^,]*)')
    if (-not $match.Success) { return '' }
    $value = $match.Groups['cn'].Value.Trim().Trim('"')
    $value.Trim()
}

function Get-RmoPublisherInfo {
    <#
        .SYNOPSIS
            Works out who made an executable, from the file itself.

        .DESCRIPTION
            Two independent sources, in decreasing order of trustworthiness:

              1. the Authenticode signature - a name a certificate authority verified;
              2. the version resource compiled into the file - CompanyName, FileDescription and
                 ProductName, which anyone can write anything into.

            Reading the version resource is cheap. Verifying a signature is not - it can touch
            the network for revocation checking - so it only happens on a complete scan.

            Results are cached per path for the life of the session; a scan sees the same
            executable dozens of times.

        .PARAMETER Path
            Full path to the executable.

        .PARAMETER VerifySignature
            Also read and validate the Authenticode signature.

        .PARAMETER ErrorSink
            Optional list; unreadable files are recorded here rather than thrown.

        .EXAMPLE
            Get-RmoPublisherInfo -Path C:\Windows\explorer.exe -VerifySignature
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Position = 0)] [AllowEmptyString()] [AllowNull()] [string] $Path,
        [switch] $VerifySignature,
        [System.Collections.IList] $ErrorSink
    )

    $empty = [pscustomobject]@{
        Path            = $Path
        Company         = ''
        FileDescription = ''
        ProductName     = ''
        FileVersion     = ''
        Signed          = $false
        SignatureStatus = 'NotChecked'
        SignerName      = ''
        Readable        = $false
    }

    if ([string]::IsNullOrWhiteSpace($Path)) { return $empty }

    $cacheKey = "$($Path.ToLowerInvariant())|$([int] $VerifySignature.IsPresent)"
    if ($null -eq $script:RmoPublisherCache) { $script:RmoPublisherCache = @{} }
    if ($script:RmoPublisherCache.ContainsKey($cacheKey)) {
        return $script:RmoPublisherCache[$cacheKey]
    }

    # A signature check on a path that does not exist is a slow way to learn nothing.
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $script:RmoPublisherCache[$cacheKey] = $empty
        return $empty
    }

    $company = ''
    $description = ''
    $product = ''
    $version = ''
    $readable = $false

    try {
        $info = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
        if ($null -ne $info) {
            $readable = $true
            if ($info.CompanyName) { $company = $info.CompanyName.Trim() }
            if ($info.FileDescription) { $description = $info.FileDescription.Trim() }
            if ($info.ProductName) { $product = $info.ProductName.Trim() }
            if ($info.FileVersion) { $version = $info.FileVersion.Trim() }
        }
    } catch {
        $message = "Could not read version information from '$Path': $($_.Exception.Message)"
        Write-Verbose $message
        if ($null -ne $ErrorSink) { $null = $ErrorSink.Add($message) }
    }

    $signed = $false
    $status = 'NotChecked'
    $signer = ''
    if ($VerifySignature) {
        try {
            $signature = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
            $status = [string] $signature.Status
            $signed = ($status -eq 'Valid')
            if ($signature.SignerCertificate) {
                $signer = Get-RmoSignerName $signature.SignerCertificate.Subject
            }
        } catch {
            $status = 'Unavailable'
            Write-Verbose "Could not verify the signature on '$Path': $($_.Exception.Message)"
        }
    }

    $result = [pscustomobject]@{
        Path            = $Path
        Company         = $company
        FileDescription = $description
        ProductName     = $product
        FileVersion     = $version
        Signed          = $signed
        SignatureStatus = $status
        SignerName      = $signer
        Readable        = $readable
    }

    $script:RmoPublisherCache[$cacheKey] = $result
    $result
}
