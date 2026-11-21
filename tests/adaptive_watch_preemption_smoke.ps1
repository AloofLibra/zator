$ErrorActionPreference = 'Stop'
$temp = Join-Path $env:TEMP ('zator-watch-preemption-' + [guid]::NewGuid().ToString('N'))
$fakeProbe = Join-Path $temp 'fake-probe.ps1'
$cancelFile = Join-Path $temp 'cancelled'
$env:ZATOR_ADAPTIVE_FAKE_CANCEL = $cancelFile
$script:PreemptApiCalls = 0
$script:CancelApiCalls = 0
$script:UrgentStatus = 'needs_verify'
try {
    New-Item -ItemType Directory -Path $temp | Out-Null
    @'
param(
    [uri]$Router, [string]$Token, [string]$Hostname, [string]$DestinationIp,
    [int]$ProfileId, [int]$StrategyNumber, [string]$Scope, [string]$ApiPath
)
for ($i = 0; $i -lt 100; $i++) {
    if (Test-Path -LiteralPath $env:ZATOR_ADAPTIVE_FAKE_CANCEL) { 'probe-cancelled'; exit 0 }
    Start-Sleep -Milliseconds 100
}
'timed-out'
'@ | Set-Content -LiteralPath $fakeProbe -Encoding utf8

    $agentPath = Join-Path $PSScriptRoot '..\tools\adaptive-agent.ps1'
    $tokens = $null; $parseErrors = $null
    $agentAst = [System.Management.Automation.Language.Parser]::ParseFile(
        (Resolve-Path $agentPath), [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw ($parseErrors | ForEach-Object Message | Out-String) }
    $functionAst = $agentAst.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Invoke-AdaptiveExplorationProbe'
    }, $true)
    if (-not $functionAst) { throw 'Exploration probe runner was not found.' }
    . ([scriptblock]::Create($functionAst.Extent.Text))

    $Router = [uri]'http://192.168.1.1'
    $Token = 'a' * 64
    $ApiPath = '/cgi-bin/adaptive.cgi'
    $UploadStatistics = $false
    $StatisticsEndpoint = [uri]'https://stats.example/results'
    $AdaptiveStatsStatePath = ''
    function Invoke-AdaptiveApi {
        param([hashtable]$Body)
        if ($Body.action -eq 'events') {
            $script:PreemptApiCalls++
            return [pscustomobject]@{
                schema_version = 1; mode = 'TEST_ONLY'
                events = @([pscustomobject]@{ status = $script:UrgentStatus })
            }
        }
        if ($Body.action -eq 'cancel_probes') {
            $script:CancelApiCalls++
            Set-Content -LiteralPath $env:ZATOR_ADAPTIVE_FAKE_CANCEL -Value 'yes' -Encoding ascii
            return [pscustomobject]@{ schema_version = 1; cancelled = 1 }
        }
        throw "Unexpected API action: $($Body.action)"
    }

    $event = [pscustomobject]@{
        hostname = 'cdn.example.org'; destination_ip = '93.184.216.34'
        profile_id = 1; scope = 'default'
    }
    $output = @(Invoke-AdaptiveExplorationProbe -Event $event -Strategy 2 -ScriptPath $fakeProbe)
    if ($script:PreemptApiCalls -lt 1 -or $script:CancelApiCalls -ne 1 -or
        (($output | ConvertTo-Json -Compress) -notmatch 'cancelled')) {
        throw "Urgent request did not cancel and drain the exploration child: $($output -join '; ')"
    }
    $script:UrgentStatus = 'suspected_failure'
    $script:PreemptApiCalls = 0
    $script:CancelApiCalls = 0
    Remove-Item -LiteralPath $cancelFile -Force
    $output = @(Invoke-AdaptiveExplorationProbe -Event $event -Strategy 2 -ScriptPath $fakeProbe)
    if ($script:PreemptApiCalls -lt 1 -or $script:CancelApiCalls -ne 1 -or
        (($output | ConvertTo-Json -Compress) -notmatch 'cancelled')) {
        throw "Suspected failure did not preempt low-priority exploration: $($output -join '; ')"
    }
    'adaptive watch preemption smoke: ok'
} finally {
    Remove-Item Env:\ZATOR_ADAPTIVE_FAKE_CANCEL -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
