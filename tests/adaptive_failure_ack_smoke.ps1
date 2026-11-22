$ErrorActionPreference = 'Stop'
$agentPath = Join-Path $PSScriptRoot '..\tools\adaptive-agent.ps1'
$tokens = $null; $parseErrors = $null
$agentAst = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $agentPath), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | ForEach-Object Message | Out-String) }
$functionAst = $agentAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Test-AdaptiveFailureEventAckEligible'
}, $true)
if (-not $functionAst) { throw 'Failure-event acknowledgment policy function was not found.' }
. ([scriptblock]::Create($functionAst.Extent.Text))

foreach ($status in @('direct', 'found', 'deep_scheduled', 'all_exhausted', 'limit_reached')) {
    $json = @{ schema_version = 1; status = $status } | ConvertTo-Json -Compress
    if (-not (Test-AdaptiveFailureEventAckEligible -SearchOutput $json)) {
        throw "Completed or durably scheduled search status '$status' was not ack-eligible."
    }
}
foreach ($output in @(
    '', 'not-json',
    (@{ schema_version = 1; status = 'stopped_infra' } | ConvertTo-Json -Compress),
    (@{ schema_version = 1; status = 'inconclusive' } | ConvertTo-Json -Compress),
    (@{ schema_version = 1; status = 'cancelled' } | ConvertTo-Json -Compress),
    (@{ schema_version = 1; status = 'stopped_rate_limit' } | ConvertTo-Json -Compress),
    (@{ schema_version = 2; status = 'found' } | ConvertTo-Json -Compress)
)) {
    if (Test-AdaptiveFailureEventAckEligible -SearchOutput $output) {
        throw "Incomplete, failed, or incompatible search output became ack-eligible: $output"
    }
}

$source = Get-Content -LiteralPath $agentPath -Raw
if ($source -notmatch '-and \$eventAckEligible\)\s*\{') {
    throw 'Watch does not gate persisted event acknowledgment on the failure retry policy.'
}
if ($source -notmatch "event\.status -in @\('needs_verify', 'suspected_failure', 'active_rule_degraded'\)\)\s*\{\s*\`$eventAckEligible = Test-AdaptiveFailureEventAckEligible" -or
    $source -notmatch "if \(\`$event\.request_id -match .*?-and \`$eventAckEligible\)\s*\{") {
    throw 'Watch can acknowledge a verification request without a completed search result.'
}
$retrySelection = "if (`$_.status -in @('needs_verify', 'suspected_failure', 'active_rule_degraded')) {"
if (-not $source.Contains($retrySelection)) { throw 'Manual verification requests do not honor their persisted retry deadline.' }

$statePath = Join-Path ([IO.Path]::GetTempPath()) ('zator-revalidation-' + [guid]::NewGuid().ToString('N') + '.tsv')
$AdaptiveRetryStatePath = $statePath
. (Join-Path $PSScriptRoot '..\tools\adaptive-agent-state.ps1')
$event = [pscustomobject]@{ hostname = 'cdn.example.org'; destination_ip = '93.184.216.34'; profile_id = 2; scope = 'mark:4'; protocol = 'tls'; status = 'needs_verify' }
$retryKey = Get-AdaptiveFailureRetryKey -Event $event
$retryState = Read-AdaptiveFailureRetryState
$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
if (-not (Test-AdaptiveFailureRetryDue -State $retryState -Key $retryKey -Now $now)) {
    throw 'A target with no retry history was not immediately eligible.'
}
Save-AdaptiveFailureRetry -State $retryState -Event $event -Now $now
$retryState = Read-AdaptiveFailureRetryState
if ((Test-AdaptiveFailureRetryDue -State $retryState -Key $retryKey -Now ($now + 59)) -or
    (-not (Test-AdaptiveFailureRetryDue -State $retryState -Key $retryKey -Now ($now + 60)))) {
    throw 'The first persisted revalidation retry did not observe its 60-second delay.'
}
if (-not (Test-AdaptiveWatchCooldownPending -State $retryState -Events @($event) -Now ($now + 59)) -or
    (Test-AdaptiveWatchCooldownPending -State $retryState -Events @($event) -Now ($now + 60))) {
    throw 'A transiently busy manual request was not held until its persisted retry became due.'
}
Save-AdaptiveFailureRetry -State $retryState -Event $event -Now ($now + 60)
$retryState = Read-AdaptiveFailureRetryState
if ($retryState.Rows.Count -ne 1 -or $retryState.Rows[0].Attempts -ne 2 -or
    $retryState.Rows[0].NextAt -ne ($now + 180)) {
    throw 'Revalidation retry backoff did not persist and increase to 120 seconds.'
}
$stateText = Get-Content -LiteralPath $statePath -Raw
if ($stateText.Contains($event.hostname) -or $stateText.Contains($event.destination_ip) -or $stateText.Contains($event.scope)) {
    throw 'Private target identity leaked into the retry state.'
}
Clear-AdaptiveFailureRetry -State $retryState -Key $retryKey
if ((Read-AdaptiveFailureRetryState).Rows.Count -ne 0) { throw 'Completed revalidation did not clear its retry backoff.' }
Save-AdaptiveFailureRetry -State (Read-AdaptiveFailureRetryState) -Event $event -Now $now -DelayBaseSeconds 900
$retryState = Read-AdaptiveFailureRetryState
if ($retryState.Rows[0].NextAt -ne ($now + 900)) { throw 'Rate limiting did not persist its 15-minute retry delay.' }
Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
'adaptive failure-event acknowledgment smoke: ok'
