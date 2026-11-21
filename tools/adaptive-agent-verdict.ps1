function Invoke-AdaptiveCurlNative {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $previousErrorAction = $ErrorActionPreference
    try {
        # Windows PowerShell promotes native stderr to NativeCommandError. A
        # curl nonzero exit is probe data and must not skip API completion.
        $ErrorActionPreference = 'Continue'
        $output = & $Executable @Arguments 2>$null
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorAction
    }
    return [pscustomobject]@{ Output = $output; ExitCode = $exitCode }
}

function Test-AdaptiveMediaUrlShape {
    param([string]$Url, [string]$Hostname)
    if ($Url -notmatch '^[\x21-\x7E]+$' -or $Url.Contains('"') -or $Url.Contains('\')) { return $false }
    $parsed = $null
    [uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$parsed) -and
        $parsed.Scheme -eq 'https' -and $parsed.Host -eq $Hostname -and
        $parsed.AbsolutePath -eq '/videoplayback' -and [string]::IsNullOrEmpty($parsed.Fragment)
}

function Test-AdaptiveCurlHardSizeLimit {
    param([string]$VersionLine)
    if ($VersionLine -notmatch '^curl ([0-9]+)\.([0-9]+)\.([0-9]+)\b') { return $false }
    $major = [int]$Matches[1]; $minor = [int]$Matches[2]
    return ($major -gt 8 -or ($major -eq 8 -and $minor -ge 4))
}

function Test-AdaptiveCurlHttp3Support {
    param([string]$VersionOutput, [string]$HelpOutput)
    return ($VersionOutput -match '(?im)^Features:.*\bHTTP3\b' -and $HelpOutput -match '(?m)^\s*--http3-only(?:\s|$)')
}

function New-AdaptiveQuicMediaCurlArguments {
    param(
        [string]$ConfigFile, [string]$SourceIp, [int]$SourcePort,
        [string]$Hostname, [string]$DestinationIp, [string]$ResponseFile,
        [string]$HeaderFile, [string]$WriteOut
    )
    if ($SourcePort -lt 62000 -or $SourcePort -gt 62999) { throw 'QUIC probe source port is outside the lease range.' }
    return @(
        '-q', '--config', $ConfigFile, '--silent', '--show-error', '--noproxy', '*',
        '--interface', $SourceIp, '--local-port', [string]$SourcePort,
        '--resolve', "$Hostname`:443`:$DestinationIp", '--http3-only',
        '--connect-timeout', '8', '--max-time', '25', '--range', '0-1048575',
        '--max-filesize', '1048576', '--limit-rate', '2M', '--output', $ResponseFile,
        '--dump-header', $HeaderFile, '--write-out', $WriteOut
    )
}

function Get-AdaptiveQuicMediaVerdict {
    param(
        [string]$HttpVersion, [int]$CurlExit, [int]$HttpCode, [long]$Bytes,
        [string]$RemoteIp, [string]$DestinationIp, [string]$Headers,
        [long]$ContentLength, [string]$MimeType, [long]$SpeedBps
    )
    if ($HttpVersion -ne '3') {
        return @{ transport = 'UNKNOWN'; application = 'UNKNOWN'; reason = 'quic_unavailable' }
    }
    return Get-AdaptiveMediaVerdict -CurlExit $CurlExit -HttpCode $HttpCode -Bytes $Bytes `
        -RemoteIp $RemoteIp -DestinationIp $DestinationIp -Headers $Headers `
        -ContentLength $ContentLength -MimeType $MimeType -SpeedBps $SpeedBps
}

function Get-AdaptiveMediaVerdict {
    param(
        [int]$CurlExit, [int]$HttpCode, [long]$Bytes, [string]$RemoteIp, [string]$DestinationIp,
        [string]$Headers, [long]$ContentLength, [string]$MimeType, [long]$SpeedBps
    )
    if ($RemoteIp -and $RemoteIp -ne $DestinationIp) {
        return @{ transport = 'UNKNOWN'; application = 'UNKNOWN'; reason = 'route_unverified' }
    }
    if ($HttpCode -eq 403 -or $HttpCode -eq 404) {
        return @{ transport = 'OK'; application = 'UNKNOWN'; reason = 'signed_url_expired' }
    }
    if ($HttpCode -eq 429) { return @{ transport = 'OK'; application = 'UNKNOWN'; reason = 'rate_limited' } }
    if ($HttpCode -ge 500 -and $HttpCode -le 599) { return @{ transport = 'OK'; application = 'UNKNOWN'; reason = 'origin_unavailable' } }
    if ($CurlExit -eq 28) { return @{ transport = 'UNKNOWN'; application = 'UNKNOWN'; reason = 'transport_timeout' } }
    if ($HttpCode -eq 206 -and $CurlExit -eq 0 -and $Bytes -eq 1048576 -and $SpeedBps -gt 0) {
        $expectedRange = "(?im)^Content-Range:\s*bytes 0-1048575/$ContentLength\s*$"
        $expectedType = '(?im)^Content-Type:\s*' + [regex]::Escape($MimeType) + '(?:;[^\r\n]*)?\s*$'
        if ($Headers -match $expectedRange -and $Headers -match $expectedType) {
            return @{ transport = 'OK'; application = 'OK'; reason = 'media_ok' }
        }
    }
    if ($HttpCode -ge 100 -and $HttpCode -le 599) {
        return @{ transport = 'OK'; application = 'UNKNOWN'; reason = 'media_insufficient' }
    }
    return @{ transport = 'UNKNOWN'; application = 'UNKNOWN'; reason = 'target_unavailable' }
}

function Get-AdaptiveHttpVerdict {
    param(
        [Parameter(Mandatory = $true)][int]$CurlExit,
        [Parameter(Mandatory = $true)][int]$HttpCode,
        [Parameter(Mandatory = $true)][long]$Bytes
    )

    if ($CurlExit -eq 28) {
        return @{ transport = 'UNKNOWN'; application = 'UNKNOWN'; reason = 'timeout' }
    }
    if ($CurlExit -eq 63 -and $HttpCode -ge 100 -and $HttpCode -le 599) {
        return @{ transport = 'OK'; application = 'UNKNOWN'; reason = 'response_too_large' }
    }
    if ($HttpCode -ge 200 -and $HttpCode -lt 300) {
        if ($CurlExit -eq 0 -and $Bytes -gt 0) {
            return @{ transport = 'OK'; application = 'OK'; reason = 'probe_ok' }
        }
        return @{ transport = 'OK'; application = 'UNKNOWN'; reason = 'empty_response' }
    }
    if ($HttpCode -eq 429) {
        return @{ transport = 'OK'; application = 'UNKNOWN'; reason = 'rate_limited' }
    }
    if ($HttpCode -ge 500 -and $HttpCode -le 599) {
        return @{ transport = 'OK'; application = 'UNKNOWN'; reason = 'server_busy' }
    }
    if ($HttpCode -ge 100 -and $HttpCode -le 599) {
        return @{ transport = 'OK'; application = 'UNKNOWN'; reason = 'http_rejected' }
    }
    return @{ transport = 'UNKNOWN'; application = 'UNKNOWN'; reason = 'target_unavailable' }
}
