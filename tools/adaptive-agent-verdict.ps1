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
