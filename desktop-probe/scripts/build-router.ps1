param([string]$Go = 'go')
$ErrorActionPreference = 'Stop'
$probeSource = (Resolve-Path (Join-Path $PSScriptRoot '../router')).Path
$probeOut = Join-Path $PSScriptRoot '../dist'
New-Item -ItemType Directory -Force -Path $probeOut | Out-Null
$probePreviousEnv = @{}
foreach ($probeEnvName in @('GOOS','GOARCH','GOMIPS','GOARM','CGO_ENABLED')) { $probePreviousEnv[$probeEnvName] = [Environment]::GetEnvironmentVariable($probeEnvName) }
Push-Location $probeSource
try {
    & $Go test ./...
    if ($LASTEXITCODE -ne 0) { throw 'Router tests failed' }
    $env:CGO_ENABLED = '0'
    $env:GOOS = 'linux'
    foreach ($probeArch in @('arm64', 'arm', 'mipsle', 'mips', 'amd64')) {
        $env:GOARCH = $probeArch
        $env:GOMIPS = 'softfloat'
        $env:GOARM = '7'
        & $Go build -trimpath -ldflags '-s -w' -o (Join-Path $probeOut "zator-desktop-probe-linux-$probeArch") .
        if ($LASTEXITCODE -ne 0) { throw "Build failed: $probeArch" }
    }
    $probeGoRoot = & $Go env GOROOT
    Copy-Item -LiteralPath (Join-Path $probeGoRoot 'LICENSE') -Destination (Join-Path $probeOut 'GO-LICENSE.txt')
} finally {
    foreach ($probeEnvName in $probePreviousEnv.Keys) { [Environment]::SetEnvironmentVariable($probeEnvName, $probePreviousEnv[$probeEnvName]) }
    Pop-Location
}
