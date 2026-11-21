$ErrorActionPreference = 'Stop'
$temp = Join-Path $env:TEMP ('zator-explore-failure-' + [guid]::NewGuid().ToString('N'))
$fakeProbe = Join-Path $temp 'fake-probe.ps1'
$script:ApiCalls = 0
try {
    New-Item -ItemType Directory -Path $temp | Out-Null
    $AdaptiveStatsStatePath = Join-Path $temp 'stats.json'
    $env:ZATOR_ADAPTIVE_TEST_PROBE_LOG = Join-Path $temp 'probe-order.txt'
    @'
param(
    [uri]$Router, [string]$Token, [string]$Hostname, [string]$DestinationIp,
    [int]$ProfileId, [int]$StrategyNumber, [string]$Scope, [string]$ApiPath,
    [switch]$UploadStatistics, [uri]$StatisticsEndpoint, [string]$AdaptiveStatsStatePath
)
Add-Content -LiteralPath $env:ZATOR_ADAPTIVE_TEST_PROBE_LOG -Value $StrategyNumber
$target = @{ hostname = $Hostname; destination_ip = $DestinationIp; profile_id = $ProfileId; protocol = 'tcp'; port = 443; scope = $Scope }
if ($StrategyNumber -eq 0) {
    @{ overall = 'SUCCESS'; route_verified = $true; transport = 'OK'; application = 'OK'; reason = 'probe_ok'; recipe_id = 'tls-http1-v1'; client_profile = 'curl-windows-v1'
       target = $target; strategy = @{ local_number = 0; fingerprint = 'sha256:' + ('0' * 64) } } | ConvertTo-Json -Compress -Depth 5
} else {
    @{ overall = 'INCONCLUSIVE'; route_verified = $true; transport = 'UNKNOWN'; application = 'UNKNOWN'; reason = 'timeout'; recipe_id = 'tls-http1-v1'; client_profile = 'curl-windows-v1'
       target = $target; strategy = @{ local_number = $StrategyNumber; fingerprint = 'sha256:' + ('a' * 64) } } | ConvertTo-Json -Compress -Depth 5
}
'@ | Set-Content -LiteralPath $fakeProbe -Encoding utf8

    . (Join-Path $PSScriptRoot '..\tools\adaptive-agent-stats.ps1')
    $agentPath = Join-Path $PSScriptRoot '..\tools\adaptive-agent.ps1'
    $tokens = $null; $parseErrors = $null
    $agentAst = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $agentPath), [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw ($parseErrors | ForEach-Object Message | Out-String) }
    $functionAst = $agentAst.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-AdaptiveExplorationProbe' }, $true)
    if (-not $functionAst) { throw 'Exploration runner function was not found.' }
    . ([scriptblock]::Create($functionAst.Extent.Text))
    function Get-AdaptiveAvailableSourcePort { 62017 }

    $Router = [uri]'http://192.168.1.1'; $Token = 'a' * 64; $ApiPath = '/cgi-bin/adaptive.cgi'
    $UploadStatistics = $true; $StatisticsToken = 'test-client-token'
    $StatisticsEndpoint = [uri]'https://stats.example/results'; $AdaptiveStatsStatePath = $AdaptiveStatsStatePath
    function Invoke-AdaptiveApi {
        param([hashtable]$Body)
        $script:ApiCalls++
        if ($Body.action -eq 'events') { return [pscustomobject]@{ schema_version = 1; mode = 'TEST_ONLY'; events = @() } }
        if ($Body.action -eq 'stats_identity') { return [pscustomobject]@{ schema_version = 1; provider = 'Example ISP' } }
        throw "Unexpected API action: $($Body.action)"
    }
    $event = [pscustomobject]@{ hostname = 'cdn.example.org'; destination_ip = '93.184.216.34'; profile_id = 1; scope = 'default' }
    $output = @(Invoke-AdaptiveExplorationProbe -Event $event -Strategy 7 -ScriptPath $fakeProbe)
    $order = @(Get-Content -LiteralPath $env:ZATOR_ADAPTIVE_TEST_PROBE_LOG)
    $state = Read-AdaptiveStatsState
    if ($output.Count -ne 1 -or $output[0].status -ne 'failure-confirmed' -or
        ($order -join ',') -ne '0,7,7,0' -or $state.Pending.Count -ne 1 -or
        $state.Pending[0].verdict -ne 'FAIL' -or $state.Pending[0].failure_confirmations -ne 2 -or
        $state.Pending[0].provider -ne 'Example ISP' -or $script:ApiCalls -lt 1) {
        throw "Repeated strategy failure was not bracketed by DIRECT controls and queued: status=$($output[0].status) calls=$script:ApiCalls order=$($order -join ',') state=$($state.Pending | ConvertTo-Json -Compress)"
    }
    $saved = Get-Content -LiteralPath $AdaptiveStatsStatePath -Raw
    foreach ($privateValue in @('cdn.example.org', '93.184.216.34', 'default')) {
        if ($saved.Contains($privateValue)) { throw "Private target leaked into stats spool: $privateValue" }
    }
    'adaptive explore failure evidence smoke: ok'
} finally {
    Remove-Item Env:\ZATOR_ADAPTIVE_TEST_PROBE_LOG -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
