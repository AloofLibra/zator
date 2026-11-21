$ErrorActionPreference = 'Stop'
$agent = Join-Path (Split-Path $PSScriptRoot -Parent) 'tools\adaptive-agent.ps1'
if (-not (Test-Path -LiteralPath $agent)) { throw "Agent not found: $agent" }

$probe = [System.Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$probe.Start()
$port = ([Net.IPEndPoint]$probe.LocalEndpoint).Port
$probe.Stop()
$prefix = "http://127.0.0.1:$port/"
$listener = [Net.HttpListener]::new()
$listener.Prefixes.Add($prefix)
$listener.Start()
$token = 'a' * 64
$temp = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
$stdout = Join-Path $temp 'stdout.txt'
$stderr = Join-Path $temp 'stderr.txt'
$hostExe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$agentArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $agent + '"'),
    '-Router', $prefix, '-Token', $token, '-ApiPath', '/cgi-bin/adaptive.cgi', '-ListEvents') -join ' '
$process = $null
try {
    $start = @{
        FilePath = $hostExe; ArgumentList = $agentArgs
        RedirectStandardOutput = $stdout; RedirectStandardError = $stderr; PassThru = $true
    }
    if ($env:OS -eq 'Windows_NT') { $start.WindowStyle = 'Hidden' }
    $process = Start-Process @start
    $pendingRequest = $listener.BeginGetContext($null, $null)
    if (-not $pendingRequest.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds(15))) {
        throw 'Agent did not connect to the local HTTP server.'
    }
    $context = $listener.EndGetContext($pendingRequest)
    $reader = [IO.StreamReader]::new($context.Request.InputStream, [Text.Encoding]::UTF8)
    $body = $reader.ReadToEnd()
    $reader.Dispose()
    $request = [pscustomobject]@{
        Method = $context.Request.HttpMethod
        Path = $context.Request.Url.AbsolutePath
        Authorization = $context.Request.Headers['Authorization']
        ContentType = $context.Request.ContentType
        Body = $body
    }
    $response = [Text.Encoding]::UTF8.GetBytes('{"schema_version":1,"mode":"OBSERVE","events":[]}')
    $context.Response.StatusCode = 200
    $context.Response.ContentType = 'application/json; charset=utf-8'
    $context.Response.ContentLength64 = $response.Length
    $context.Response.OutputStream.Write($response, 0, $response.Length)
    $context.Response.Close()
    if (-not $process.WaitForExit(15000)) { Stop-Process -Id $process.Id -Force; throw 'Agent did not finish.' }
    $process.Refresh()
    $raw = Get-Content -LiteralPath $stdout -Raw
    $errors = Get-Content -LiteralPath $stderr -Raw -ErrorAction SilentlyContinue
    if (-not [string]::IsNullOrWhiteSpace($errors)) { throw "Agent process reported an error: $errors" }
    $result = $raw | ConvertFrom-Json
    if ($request.Method -ne 'POST' -or $request.Path -ne '/cgi-bin/adaptive.cgi' -or
        $request.Authorization -ne "Bearer $token" -or
        $request.ContentType -notlike 'application/x-www-form-urlencoded*' -or
        $request.Body -ne 'action=events' -or
        $result.schema_version -ne 1 -or $result.mode -ne 'OBSERVE' -or $null -eq $result.events) {
        throw "Unexpected agent HTTP contract: $($request | ConvertTo-Json -Compress); response=$raw"
    }
    'adaptive agent HTTP smoke: ok'
} finally {
    if ($null -ne $process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
    $listener.Stop()
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
