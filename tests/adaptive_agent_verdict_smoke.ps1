$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\tools\adaptive-agent-verdict.ps1')

function Assert-Verdict([int]$Exit, [int]$Code, [long]$Bytes, [string]$Transport, [string]$Application, [string]$Reason) {
    $actual = Get-AdaptiveHttpVerdict -CurlExit $Exit -HttpCode $Code -Bytes $Bytes
    if ($actual.transport -ne $Transport -or $actual.application -ne $Application -or $actual.reason -ne $Reason) {
        throw "Unexpected verdict for curl=$Exit HTTP=$Code bytes=${Bytes}: $($actual | ConvertTo-Json -Compress)"
    }
}

Assert-Verdict 0 200 128 OK OK probe_ok
Assert-Verdict 0 204 0 OK UNKNOWN empty_response
Assert-Verdict 0 302 0 OK UNKNOWN http_rejected
Assert-Verdict 0 403 17 OK UNKNOWN http_rejected
Assert-Verdict 0 404 0 OK UNKNOWN http_rejected
Assert-Verdict 0 429 64 OK UNKNOWN rate_limited
Assert-Verdict 0 503 64 OK UNKNOWN server_busy
Assert-Verdict 63 200 65536 OK UNKNOWN response_too_large
Assert-Verdict 28 0 0 UNKNOWN UNKNOWN timeout
Assert-Verdict 7 0 0 UNKNOWN UNKNOWN target_unavailable
$mediaHost = 'rr1---sn-a5mekn6e.googlevideo.com'
$mediaUrl = "https://$mediaHost/videoplayback?expire=2000000000&sig=opaque"
if (-not (Test-AdaptiveMediaUrlShape -Url $mediaUrl -Hostname $mediaHost) -or
    (Test-AdaptiveMediaUrlShape -Url ($mediaUrl + '"&other=1') -Hostname $mediaHost) -or
    (Test-AdaptiveMediaUrlShape -Url ($mediaUrl + '#fragment') -Hostname $mediaHost) -or
    (Test-AdaptiveMediaUrlShape -Url $mediaUrl -Hostname 'other.googlevideo.com')) {
    throw 'Googlevideo media URL shape validation accepted an unsafe or mismatched URL.'
}
if (-not (Test-AdaptiveCurlHardSizeLimit 'curl 8.4.0 (Windows)') -or
    -not (Test-AdaptiveCurlHardSizeLimit 'curl 8.22.0 (Windows)') -or
    (Test-AdaptiveCurlHardSizeLimit 'curl 8.3.9 (Windows)') -or
    (Test-AdaptiveCurlHardSizeLimit 'curl 7.88.1 (Windows)')) {
    throw 'curl media size-limit compatibility check is incorrect.'
}
$h3Features = "curl 8.10.0 (Windows)`nFeatures: AsynchDNS HTTP3 HTTPS-proxy IPv6"
$h3Help = "--http3-only Use HTTP/3 without fallback`n--http3 Attempt HTTP/3 then fallback"
$mediaHeaders = "HTTP/1.1 206 Partial Content`r`nContent-Range: bytes 0-1048575/2097152`r`nContent-Type: video/mp4`r`n"
if (-not (Test-AdaptiveCurlHttp3Support -VersionOutput $h3Features -HelpOutput $h3Help) -or
    (Test-AdaptiveCurlHttp3Support -VersionOutput ($h3Features -replace 'HTTP3', '') -HelpOutput $h3Help) -or
    (Test-AdaptiveCurlHttp3Support -VersionOutput $h3Features -HelpOutput ($h3Help -replace '(?m)^--http3-only.*', ''))) {
    throw 'curl HTTP/3-only feature gate is incorrect.'
}
$quicArgs = New-AdaptiveQuicMediaCurlArguments -ConfigFile 'C:\temp\signed.url' -SourceIp '192.168.1.8' `
    -SourcePort 62011 -Hostname $mediaHost -DestinationIp '142.251.1.1' -ResponseFile 'C:\temp\body' `
    -HeaderFile 'C:\temp\headers' -WriteOut '%{http_code}'
if ($quicArgs -notcontains '--http3-only' -or $quicArgs -contains '--http1.1' -or $quicArgs -contains '--http3' -or
    $quicArgs[$quicArgs.IndexOf('--local-port') + 1] -ne '62011' -or
    $quicArgs[$quicArgs.IndexOf('--resolve') + 1] -ne "$mediaHost`:443`:142.251.1.1") {
    throw "QUIC curl argv did not pin HTTP/3 and the exact leased tuple: $($quicArgs -join ' ')"
}
$badPortRejected = $false
try {
    [void](New-AdaptiveQuicMediaCurlArguments -ConfigFile x -SourceIp x -SourcePort 61999 -Hostname $mediaHost `
        -DestinationIp x -ResponseFile x -HeaderFile x -WriteOut x)
} catch { if ($_.Exception.Message -match 'outside the lease range') { $badPortRejected = $true } else { throw } }
if (-not $badPortRejected) { throw 'QUIC argument builder accepted a source port outside the lease range.' }
$quicGood = Get-AdaptiveQuicMediaVerdict -HttpVersion '3' -CurlExit 0 -HttpCode 206 -Bytes 1048576 `
    -RemoteIp '142.251.1.1' -DestinationIp '142.251.1.1' -Headers $mediaHeaders `
    -ContentLength 2097152 -MimeType 'video/mp4' -SpeedBps 1000000
$quicFallback = Get-AdaptiveQuicMediaVerdict -HttpVersion '2' -CurlExit 0 -HttpCode 206 -Bytes 1048576 `
    -RemoteIp '142.251.1.1' -DestinationIp '142.251.1.1' -Headers $mediaHeaders `
    -ContentLength 2097152 -MimeType 'video/mp4' -SpeedBps 1000000
if ($quicGood.application -ne 'OK' -or $quicGood.reason -ne 'media_ok' -or
    $quicFallback.application -ne 'UNKNOWN' -or $quicFallback.reason -ne 'quic_unavailable') {
    throw 'QUIC media verdict accepted a non-H3 result or rejected valid H3 media.'
}
$mediaCases = @(
    @(@{ CurlExit = 0; HttpCode = 206; Bytes = 1048576; RemoteIp = '142.251.1.1'; DestinationIp = '142.251.1.1'; Headers = $mediaHeaders; ContentLength = 2097152; MimeType = 'video/mp4'; SpeedBps = 1000000 }, 'OK', 'OK', 'media_ok'),
    @(@{ CurlExit = 0; HttpCode = 200; Bytes = 1048576; RemoteIp = '142.251.1.1'; DestinationIp = '142.251.1.1'; Headers = $mediaHeaders; ContentLength = 2097152; MimeType = 'video/mp4'; SpeedBps = 1000000 }, 'OK', 'UNKNOWN', 'media_insufficient'),
    @(@{ CurlExit = 0; HttpCode = 206; Bytes = 1048576; RemoteIp = '142.251.1.1'; DestinationIp = '142.251.1.1'; Headers = ($mediaHeaders -replace '2097152', '4194304'); ContentLength = 2097152; MimeType = 'video/mp4'; SpeedBps = 1000000 }, 'OK', 'UNKNOWN', 'media_insufficient'),
    @(@{ CurlExit = 0; HttpCode = 206; Bytes = 1048576; RemoteIp = '142.251.1.1'; DestinationIp = '142.251.1.1'; Headers = $mediaHeaders; ContentLength = 2097152; MimeType = 'video/webm'; SpeedBps = 1000000 }, 'OK', 'UNKNOWN', 'media_insufficient'),
    @(@{ CurlExit = 0; HttpCode = 206; Bytes = 1048576; RemoteIp = '142.251.1.2'; DestinationIp = '142.251.1.1'; Headers = $mediaHeaders; ContentLength = 2097152; MimeType = 'video/mp4'; SpeedBps = 1000000 }, 'UNKNOWN', 'UNKNOWN', 'route_unverified'),
    @(@{ CurlExit = 0; HttpCode = 403; Bytes = 0; RemoteIp = '142.251.1.1'; DestinationIp = '142.251.1.1'; Headers = ''; ContentLength = 2097152; MimeType = 'video/mp4'; SpeedBps = 0 }, 'OK', 'UNKNOWN', 'signed_url_expired'),
    @(@{ CurlExit = 0; HttpCode = 429; Bytes = 0; RemoteIp = '142.251.1.1'; DestinationIp = '142.251.1.1'; Headers = ''; ContentLength = 2097152; MimeType = 'video/mp4'; SpeedBps = 0 }, 'OK', 'UNKNOWN', 'rate_limited'),
    @(@{ CurlExit = 0; HttpCode = 503; Bytes = 0; RemoteIp = '142.251.1.1'; DestinationIp = '142.251.1.1'; Headers = ''; ContentLength = 2097152; MimeType = 'video/mp4'; SpeedBps = 0 }, 'OK', 'UNKNOWN', 'origin_unavailable'),
    @(@{ CurlExit = 28; HttpCode = 0; Bytes = 0; RemoteIp = '142.251.1.1'; DestinationIp = '142.251.1.1'; Headers = ''; ContentLength = 2097152; MimeType = 'video/mp4'; SpeedBps = 0 }, 'UNKNOWN', 'UNKNOWN', 'transport_timeout'),
    @(@{ CurlExit = 28; HttpCode = 0; Bytes = 0; RemoteIp = ''; DestinationIp = '142.251.1.1'; Headers = ''; ContentLength = 2097152; MimeType = 'video/mp4'; SpeedBps = 0 }, 'UNKNOWN', 'UNKNOWN', 'transport_timeout')
)
foreach ($case in $mediaCases) {
    $inputCase = $case[0]
    $actual = Get-AdaptiveMediaVerdict -CurlExit $inputCase.CurlExit -HttpCode $inputCase.HttpCode `
        -Bytes $inputCase.Bytes -RemoteIp $inputCase.RemoteIp -DestinationIp $inputCase.DestinationIp `
        -Headers $inputCase.Headers -ContentLength $inputCase.ContentLength -MimeType $inputCase.MimeType -SpeedBps $inputCase.SpeedBps
    if ($actual.transport -ne $case[1] -or $actual.application -ne $case[2] -or $actual.reason -ne $case[3]) {
        throw "Unexpected media verdict: $($actual | ConvertTo-Json -Compress) expected=$($case[1..3] -join '/')"
    }
}
$cmd = Get-Command cmd.exe -ErrorAction SilentlyContinue
if ($null -ne $cmd) {
    $native = Invoke-AdaptiveCurlNative -Executable $cmd.Source -Arguments @('/d', '/c', 'echo simulated curl error 1>&2 & exit /b 63')
} else {
    $sh = Get-Command sh -ErrorAction Stop
    $native = Invoke-AdaptiveCurlNative -Executable $sh.Source -Arguments @('-c', 'printf "simulated curl error\\n" >&2; exit 63')
}
if ($native.ExitCode -ne 63) { throw "Native nonzero exit was lost: $($native | ConvertTo-Json -Compress)" }
Write-Output 'adaptive agent verdict smoke: ok'
