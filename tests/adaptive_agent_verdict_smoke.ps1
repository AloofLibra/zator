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
$cmd = Get-Command cmd.exe -ErrorAction SilentlyContinue
if ($null -ne $cmd) {
    $native = Invoke-AdaptiveCurlNative -Executable $cmd.Source -Arguments @('/d', '/c', 'echo simulated curl error 1>&2 & exit /b 63')
} else {
    $sh = Get-Command sh -ErrorAction Stop
    $native = Invoke-AdaptiveCurlNative -Executable $sh.Source -Arguments @('-c', 'printf "simulated curl error\\n" >&2; exit 63')
}
if ($native.ExitCode -ne 63) { throw "Native nonzero exit was lost: $($native | ConvertTo-Json -Compress)" }
Write-Output 'adaptive agent verdict smoke: ok'
