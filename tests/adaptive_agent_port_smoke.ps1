$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\tools\adaptive-agent-port.ps1')
$port = Get-AdaptiveAvailableSourcePort
if ($port -lt 62000 -or $port -gt 62999) { throw "Port outside adaptive range: $port" }
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Any, $port)
try { $listener.Start() }
finally { $listener.Stop() }
Write-Output "adaptive agent port smoke: ok ($port)"
