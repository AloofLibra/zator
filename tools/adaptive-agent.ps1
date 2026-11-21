# This repository, including its original source code and implementation, is licensed under GNU GPL v3.0; see LICENSE for the full terms. Redistribution, modification, and reuse must comply with that license and preserve applicable copyright and license notices. Unauthorized copying, including verbatim code copying or presenting this repository implementation or operating logic as your own, may be reported to the relevant hosting platforms.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][uri]$Router,
    [Parameter(Mandatory = $true)][string]$Token,
    [string]$Hostname,
    [string]$DestinationIp,
    [ValidateRange(1, 5)][int]$ProfileId = 1,
    [ValidateRange(0, 999)][int]$StrategyNumber = 1,
    [ValidatePattern('^(default|mark:[1-9][0-9]{0,4})$')][string]$Scope = 'default',
    [switch]$ListEvents,
    [switch]$FastSearch,
    [switch]$DeepSearch,
    [ValidateRange(1, 100)][int]$DeepSearchMaxCandidates = 20,
    [switch]$Watch,
    [switch]$Explore,
    [switch]$RampAudit,
    [switch]$UploadStatistics,
    [uri]$StatisticsEndpoint = 'https://alooflibra.fun/z4r/adaptive-v2/results',
    [string]$AdaptiveStatsStatePath,
    [switch]$UseSharedRankings,
    [uri]$AdaptiveRankingEndpoint = 'https://alooflibra.fun/z4r/adaptive-v2/rankings',
    [string]$AdaptiveRankingCachePath,
    [ValidateRange(10, 300)][int]$WatchIntervalSeconds = 30,
    [ValidateRange(120, 3600)][int]$ExploreIntervalSeconds = 120,
    [ValidateRange(0, 300)][int]$ExploreJitterSeconds = 30,
    [ValidateRange(1, 100)][int]$ExploreMaxCpuPercent = 70,
    [ValidateRange(1, 1073741824)][long]$ExploreMaxNetworkBytesPerSecond = 1048576,
    [ValidateRange(0.1, 16)][double]$ExploreMaxRouterLoadPerCore = 0.8,
    [ValidateRange(8, 1024)][int]$ExploreMinRouterMemoryMiB = 32,
    [string]$ExploreStatePath,
    [string]$AdaptiveRampAuditStatePath,
    [ValidateRange(0, 128)][int]$EventIndex = 0,
    [ValidateRange(1, 10)][int]$MaxCandidates = 10,
    [ValidateRange(0, 60)][int]$CandidatePauseSeconds = 15,
    [switch]$ResumeDeepSearch,
    [switch]$ForceRevalidate,
    [string]$DeepSearchStatePath,
    [string]$AdaptiveRetryStatePath,
    [string]$AdaptiveAgentMetricsStatePath,
    [ValidateRange(0, 65535)][int]$ProbeSourcePort = 0,
    [ValidatePattern('^([a-f0-9]{32})?$')][string]$ProbeOwner,
    [string]$CancellationFile,
    [string]$TreatmentVariant = 'standard',
    [string]$ApiPath = '/cgi-bin/adaptive.cgi'
)

$ErrorActionPreference = 'Stop'
$StatisticsToken = [Environment]::GetEnvironmentVariable('Z4R_ADAPTIVE_V2_CLIENT_TOKEN')
Add-Type -AssemblyName System.Net.Http
. (Join-Path $PSScriptRoot 'adaptive-agent-verdict.ps1')
. (Join-Path $PSScriptRoot 'adaptive-agent-state.ps1')
. (Join-Path $PSScriptRoot 'adaptive-agent-stats.ps1')
. (Join-Path $PSScriptRoot 'adaptive-agent-port.ps1')
$handler = [System.Net.Http.HttpClientHandler]::new()
$handler.UseProxy = $false
$http = [System.Net.Http.HttpClient]::new($handler)
$http.Timeout = [TimeSpan]::FromSeconds(10)

function Invoke-AdaptiveApi {
    param([hashtable]$Body)
    $form = [System.Collections.Generic.List[System.Collections.Generic.KeyValuePair[string,string]]]::new()
    foreach ($key in $Body.Keys) {
        $value = $Body[$key]
        if ($value -is [bool]) { $value = $value.ToString().ToLowerInvariant() }
        $form.Add([System.Collections.Generic.KeyValuePair[string,string]]::new([string]$key, [string]$value))
    }
    $request = [System.Net.Http.HttpRequestMessage]::new(
        [System.Net.Http.HttpMethod]::Post,
        ($Router.AbsoluteUri.TrimEnd('/') + $ApiPath)
    )
    $request.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $Token)
    $request.Content = [System.Net.Http.FormUrlEncodedContent]::new($form)
    $response = $http.SendAsync($request).GetAwaiter().GetResult()
    $json = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    if (-not $response.IsSuccessStatusCode) {
        $status = [int]$response.StatusCode
        $response.Dispose()
        $request.Dispose()
        throw [System.Net.Http.HttpRequestException]::new("Adaptive API HTTP $status.")
    }
    $response.Dispose()
    $request.Dispose()
    $json | ConvertFrom-Json
}

function Send-AdaptiveAgentStatus {
    param(
        [ValidateSet('idle', 'fast_search', 'deep_search', 'explore', 'ramp_audit')][string]$Stage,
        [string]$Outcome = 'none', [int]$CandidatesChecked = 0, [int]$FastCandidates = 0,
        [int]$DeepCandidates = 0, [long]$DurationMs = 0, [long]$TimeToFirstSuccessMs = 0,
        [int]$CpuPercent = -1, [long]$FreeMemoryBytes = -1, [long]$NetworkBytesPerSecond = -1,
        [int]$RouterLoadMilli = -1, [long]$RouterMemoryAvailableKiB = -1, [int]$RouterActiveProbes = -1
    )
    if ($null -eq $script:AdaptiveLastSearchMetrics) {
        $script:AdaptiveLastSearchMetrics = @{ Outcome = 'none'; Checked = 0; Fast = 0; Deep = 0; Duration = 0; First = 0 }
    }
    if ($Outcome -ne 'none') {
        $script:AdaptiveLastSearchMetrics = @{ Outcome = $Outcome; Checked = $CandidatesChecked; Fast = $FastCandidates
            Deep = $DeepCandidates; Duration = $DurationMs; First = $TimeToFirstSuccessMs }
    }
    $metrics = $script:AdaptiveLastSearchMetrics
    if ($null -eq $script:AdaptiveRuntimeMetrics) {
        $script:AdaptiveRuntimeMetrics = @{ Cpu = -1; PcMemory = -1L; PcNetwork = -1L; RouterLoad = -1; RouterMemory = -1L; RouterActive = -1 }
    }
    if ($null -eq $script:AdaptiveRevalidationMetrics) {
        $script:AdaptiveRevalidationMetrics = @{ RevalidationRecoveries = 0; RevalidationFailures = 0 }
    }
    if ($null -eq $script:AdaptiveFailureRetryCooldownTargets) { $script:AdaptiveFailureRetryCooldownTargets = 0 }
    if ($null -ne $script:AdaptiveFailureRetryState) {
        $script:AdaptiveFailureRetryCooldownTargets = Get-AdaptiveFailureRetryCooldownCount -State $script:AdaptiveFailureRetryState
    }
    if ($CpuPercent -ge 0) { $script:AdaptiveRuntimeMetrics.Cpu = $CpuPercent }
    if ($FreeMemoryBytes -ge 0) { $script:AdaptiveRuntimeMetrics.PcMemory = $FreeMemoryBytes }
    if ($NetworkBytesPerSecond -ge 0) { $script:AdaptiveRuntimeMetrics.PcNetwork = $NetworkBytesPerSecond }
    if ($RouterLoadMilli -ge 0) { $script:AdaptiveRuntimeMetrics.RouterLoad = $RouterLoadMilli }
    if ($RouterMemoryAvailableKiB -ge 0) { $script:AdaptiveRuntimeMetrics.RouterMemory = $RouterMemoryAvailableKiB }
    if ($RouterActiveProbes -ge 0) { $script:AdaptiveRuntimeMetrics.RouterActive = $RouterActiveProbes }
    $runtime = $script:AdaptiveRuntimeMetrics
    try {
        Invoke-AdaptiveApi @{
            action = 'agent_status'; stage = $Stage
            statistics_enabled = [bool]$UploadStatistics; rankings_enabled = [bool]$UseSharedRankings
            search_outcome = [string]$metrics.Outcome; candidates_checked = [int]$metrics.Checked
            fast_candidates = [int]$metrics.Fast; deep_candidates = [int]$metrics.Deep
            search_duration_ms = [long]$metrics.Duration; time_to_first_success_ms = [long]$metrics.First
            pc_cpu_percent = [int]$runtime.Cpu; pc_free_memory_bytes = [long]$runtime.PcMemory
            pc_network_bytes_per_second = [long]$runtime.PcNetwork; router_load_milli = [int]$runtime.RouterLoad
            router_memory_available_kib = [long]$runtime.RouterMemory; router_active_probes = [int]$runtime.RouterActive
            revalidation_recoveries = [int]$script:AdaptiveRevalidationMetrics.RevalidationRecoveries
            revalidation_failures = [int]$script:AdaptiveRevalidationMetrics.RevalidationFailures
            cooldown_targets = [int]$script:AdaptiveFailureRetryCooldownTargets
        } | Out-Null
    } catch { [Console]::Error.WriteLine("Adaptive status update: $($_.Exception.Message)") }
}

function Test-AdaptiveFailureEventAckEligible {
    param([AllowEmptyString()][string]$SearchOutput)
    if ([string]::IsNullOrWhiteSpace($SearchOutput)) { return $false }
    try {
        $summary = $SearchOutput | ConvertFrom-Json -ErrorAction Stop
        return $summary.schema_version -eq 1 -and $summary.status -in @(
            'direct', 'found', 'deep_scheduled', 'all_exhausted', 'limit_reached'
        )
    } catch { return $false }
}

function Invoke-AdaptiveExplorationProbe {
    param(
        [Parameter(Mandatory = $true)]$Event,
        [Parameter(Mandatory = $true)][int]$Strategy,
        [ValidateSet('standard', 'gv_tcp_plain', 'gv_tcp_ramp', 'gv_tcp_ramp_syndata')][string]$ProbeTreatmentVariant = 'standard',
        [string]$ScriptPath = $PSCommandPath
    )
    $cancelPath = Join-Path ([IO.Path]::GetTempPath()) ('zator-adaptive-explore-cancel-' + [guid]::NewGuid().ToString('N'))
    $sourcePort = Get-AdaptiveAvailableSourcePort
    $probeOwner = [guid]::NewGuid().ToString('N')
    $job = Start-Job -ArgumentList @(
        $ScriptPath, $Router.AbsoluteUri, $Token, [string]$Event.hostname,
        [string]$Event.destination_ip, [int]$Event.profile_id, [string]$Event.scope,
        [string]$ApiPath, [bool]$UploadStatistics, [string]$StatisticsEndpoint,
        [string]$AdaptiveStatsStatePath, $Strategy, $cancelPath, $sourcePort, $probeOwner, $ProbeTreatmentVariant
    ) -ScriptBlock {
        param($ScriptPath, $RouterUri, $PairToken, $HostName, $Destination, $Profile, $ClientScope,
              $EndpointPath, $Upload, $StatsEndpoint, $StatsStatePath, $Candidate, $CancelPath, $ProbePort, $ProbeOwner, $Treatment)
        function Invoke-ExploreProbe([int]$Number) {
            if (Test-Path -LiteralPath $CancelPath) { return $null }
            $arguments = @{
                Router = [uri]$RouterUri; Token = $PairToken; Hostname = $HostName
                DestinationIp = $Destination; ProfileId = [int]$Profile
                StrategyNumber = $Number; Scope = $ClientScope; ApiPath = $EndpointPath
                ProbeSourcePort = [int]$ProbePort; ProbeOwner = [string]$ProbeOwner; CancellationFile = $CancelPath
            }
            if ($Treatment -ne 'standard') { $arguments.TreatmentVariant = [string]$Treatment }
            if ($Upload -and $Treatment -eq 'standard') {
                $arguments.UploadStatistics = $true
                $arguments.StatisticsEndpoint = [uri]$StatsEndpoint
                if (-not [string]::IsNullOrWhiteSpace($StatsStatePath)) {
                    $arguments.AdaptiveStatsStatePath = $StatsStatePath
                }
            }
            try {
                $output = & $ScriptPath @arguments 2>$null
                $raw = ($output | Out-String).Trim()
                if (-not $raw) { return $null }
                return $raw | ConvertFrom-Json -ErrorAction Stop
            } catch { return $null }
        }
        $directBefore = $null
        $candidateResults = @()
        $directAfter = $null
        if ($Upload -and $Treatment -eq 'standard') { $directBefore = Invoke-ExploreProbe 0 }
        $candidateResult = Invoke-ExploreProbe $Candidate
        if ($candidateResult) { $candidateResults += $candidateResult }
        if ($Upload -and $directBefore -and $directBefore.overall -eq 'SUCCESS' -and
            $candidateResult -and $candidateResult.route_verified -eq $true -and
            $candidateResult.overall -eq 'INCONCLUSIVE' -and $candidateResult.reason -in @('timeout', 'http_rejected')) {
            $repeat = Invoke-ExploreProbe $Candidate
            if ($repeat) { $candidateResults += $repeat }
            if ($repeat -and $repeat.route_verified -eq $true -and $repeat.overall -eq 'INCONCLUSIVE' -and
                $repeat.reason -eq $candidateResult.reason) {
                $directAfter = Invoke-ExploreProbe 0
            }
        }
        [pscustomobject]@{
            direct_before = $directBefore
            candidates = $candidateResults
            direct_after = $directAfter
            cancelled = Test-Path -LiteralPath $CancelPath
        } | ConvertTo-Json -Depth 8 -Compress
    }
    $preempted = $false
    try {
        while ($job.State -in @('NotStarted', 'Running')) {
            [void](Wait-Job -Job $job -Timeout 2)
            if ($job.State -notin @('NotStarted', 'Running') -or $preempted) { continue }
            try {
                $queue = Invoke-AdaptiveApi @{ action = 'events' }
                $urgent = @($queue.events | Where-Object { $_.status -in @('needs_verify', 'suspected_failure', 'active_rule_degraded') }).Count -gt 0
                if ($urgent) {
                    [IO.File]::WriteAllText($cancelPath, 'urgent')
                    $preempted = $true
                    $cancel = Invoke-AdaptiveApi @{ action = 'cancel_probes'; source_port = $sourcePort; probe_owner = $probeOwner }
                    if ($cancel.schema_version -eq 1 -and [int]$cancel.cancelled -gt 0) {
                        Write-Host 'Urgent verification arrived; cancelling the low-priority probe.'
                    }
                }
            } catch {
                [Console]::Error.WriteLine("Adaptive exploration preemption check: $($_.Exception.Message)")
            }
        }
        $jobOutput = Receive-Job -Job $job -Wait -ErrorAction SilentlyContinue | Out-String
        if (-not $preempted -and $jobOutput.Trim()) {
            try {
                $summary = $jobOutput.Trim() | ConvertFrom-Json -ErrorAction Stop
                $evidence = $null
                if (-not $summary.cancelled -and $UploadStatistics -and $ProbeTreatmentVariant -eq 'standard') {
                    $evidence = Test-AdaptiveFailureEvidence -DirectBefore $summary.direct_before `
                        -CandidateResults @($summary.candidates) -DirectAfter $summary.direct_after
                    if ($evidence) {
                        $identity = Invoke-AdaptiveApi @{ action = 'stats_identity' }
                        if ($identity.schema_version -eq 1 -and -not [string]::IsNullOrWhiteSpace([string]$identity.provider)) {
                            $statsState = Read-AdaptiveStatsState
                            if (Add-AdaptiveStatsResult -State $statsState -Result $evidence -Provider ([string]$identity.provider)) {
                                [void](Invoke-AdaptiveStatsUpload -State $statsState -Token $StatisticsToken -Endpoint $StatisticsEndpoint)
                            }
                        }
                    }
                }
                $probeResult = if ($summary.candidates.Count -gt 0) { $summary.candidates[-1] } else { $null }
                if ($preempted -or $summary.cancelled) { return [pscustomobject]@{ status = 'cancelled'; probe_result = $probeResult } }
                if ($evidence) { return [pscustomobject]@{ status = 'failure-confirmed'; probe_result = $probeResult } }
                return [pscustomobject]@{ status = 'complete'; probe_result = $probeResult }
            } catch {
                [Console]::Error.WriteLine("Adaptive exploration result: $($_.Exception.Message)")
            }
        }
        if ($preempted) { return [pscustomobject]@{ status = 'cancelled' } }
    } finally {
        if ($job.State -eq 'Running') {
            try { Invoke-AdaptiveApi @{ action = 'cancel_probes'; source_port = $sourcePort; probe_owner = $probeOwner } | Out-Null } catch { }
            [void](Wait-Job -Job $job -Timeout 15)
        }
        if ($job.State -in @('Running', 'NotStarted')) { Stop-Job -Job $job -ErrorAction SilentlyContinue }
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $cancelPath -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-AdaptiveWatchSearch {
    param([Parameter(Mandatory = $true)]$Event, [switch]$Deep, [string]$ScriptPath = $PSCommandPath)
    $sourcePort = Get-AdaptiveAvailableSourcePort
    $probeOwner = [guid]::NewGuid().ToString('N')
    $cancelPath = Join-Path ([IO.Path]::GetTempPath()) ('zator-adaptive-search-cancel-' + [guid]::NewGuid().ToString('N'))
    $arguments = @{
        Router = $Router; Token = $Token; Hostname = [string]$Event.hostname
        DestinationIp = [string]$Event.destination_ip; ProfileId = [int]$Event.profile_id
        Scope = [string]$Event.scope; FastSearch = $true; MaxCandidates = $MaxCandidates
        CandidatePauseSeconds = $CandidatePauseSeconds; ApiPath = $ApiPath
        ProbeSourcePort = $sourcePort; CancellationFile = $cancelPath
        ProbeOwner = $probeOwner
        ForceRevalidate = ([string]$Event.status -in @('suspected_failure', 'active_rule_degraded'))
        DeepSearchStatePath = $DeepSearchStatePath
        UploadStatistics = $UploadStatistics; StatisticsEndpoint = $StatisticsEndpoint
        AdaptiveStatsStatePath = $AdaptiveStatsStatePath; UseSharedRankings = $UseSharedRankings
        AdaptiveRankingEndpoint = $AdaptiveRankingEndpoint; AdaptiveRankingCachePath = $AdaptiveRankingCachePath
    }
    if ($Deep) {
        $arguments.ResumeDeepSearch = $true
        $arguments.DeepSearchMaxCandidates = 1
        $arguments.CandidatePauseSeconds = 0
    }
    $job = Start-Job -ArgumentList $ScriptPath, $arguments, $cancelPath -ScriptBlock {
        param($ScriptPath, $ProbeArguments, $CancelPath)
        if (Test-Path -LiteralPath $CancelPath) { return }
        & $ScriptPath @ProbeArguments | Out-String
    }
    $preempted = $false
    try {
        while ($job.State -in @('NotStarted', 'Running')) {
            [void](Wait-Job -Job $job -Timeout 2)
            if ($job.State -notin @('NotStarted', 'Running')) { continue }
            if (-not $preempted) {
                try {
                    $queue = Invoke-AdaptiveApi @{ action = 'events' }
                    $urgent = @($queue.events | Where-Object {
                        if ($_.status -notin @('needs_verify', 'suspected_failure', 'active_rule_degraded')) { return $false }
                        if ($Event.request_id -and $_.request_id -eq $Event.request_id) { return $false }
                        $sameTarget = $_.hostname -eq $Event.hostname -and $_.destination_ip -eq $Event.destination_ip -and
                            [int]$_.profile_id -eq [int]$Event.profile_id -and $_.scope -eq $Event.scope
                        if ($sameTarget -and [long]$_.observed_at -le [long]$Event.observed_at) { return $false }
                        return $true
                    }).Count -gt 0
                    if ($urgent) {
                        [IO.File]::WriteAllText($cancelPath, 'urgent')
                        $preempted = $true
                        $cancel = Invoke-AdaptiveApi @{ action = 'cancel_probes'; source_port = $sourcePort; probe_owner = $probeOwner }
                        if ($cancel.schema_version -eq 1 -and [int]$cancel.cancelled -gt 0) {
                            Write-Host 'Urgent verification arrived; cancelling the lower-priority search.'
                        }
                    }
                } catch { [Console]::Error.WriteLine("Adaptive search preemption check: $($_.Exception.Message)") }
            } else {
                try { Invoke-AdaptiveApi @{ action = 'cancel_probes'; source_port = $sourcePort; probe_owner = $probeOwner } | Out-Null } catch { }
            }
        }
        $output = Receive-Job -Job $job -Wait -ErrorAction SilentlyContinue | Out-String
        [pscustomobject]@{ preempted = $preempted; output = $output.Trim(); source_port = $sourcePort }
    } finally {
        if ($job.State -in @('NotStarted', 'Running')) {
            [IO.File]::WriteAllText($cancelPath, 'cleanup')
            try { Invoke-AdaptiveApi @{ action = 'cancel_probes'; source_port = $sourcePort; probe_owner = $probeOwner } | Out-Null } catch { }
            [void](Wait-Job -Job $job -Timeout 15)
        }
        if ($job.State -in @('Running', 'NotStarted')) { Stop-Job -Job $job -ErrorAction SilentlyContinue }
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $cancelPath -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-AdaptiveStrategyCandidate {
    param([int]$Candidate)
    if (-not [string]::IsNullOrWhiteSpace($CancellationFile) -and (Test-Path -LiteralPath $CancellationFile)) {
        return [pscustomobject]@{ strategy = $Candidate; overall = 'INCONCLUSIVE'; reason = 'cancelled' }
    }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        $rawResult = & $PSCommandPath -Router $Router -Token $Token -Hostname $Hostname `
            -DestinationIp $DestinationIp -ProfileId $ProfileId -StrategyNumber $Candidate `
            -Scope $Scope -ApiPath $ApiPath -UploadStatistics:$UploadStatistics `
            -ForceRevalidate:$ForceRevalidate `
            -ProbeSourcePort $ProbeSourcePort -ProbeOwner $ProbeOwner -CancellationFile $CancellationFile `
            -TreatmentVariant $TreatmentVariant `
            -StatisticsEndpoint $StatisticsEndpoint -AdaptiveStatsStatePath $AdaptiveStatsStatePath `
            -UseSharedRankings:$UseSharedRankings -AdaptiveRankingEndpoint $AdaptiveRankingEndpoint `
            -AdaptiveRankingCachePath $AdaptiveRankingCachePath | Out-String
        $result = $rawResult.Trim() | ConvertFrom-Json
        $timer.Stop()
        $result | Add-Member -NotePropertyName duration_ms -NotePropertyValue $timer.ElapsedMilliseconds -Force
        return $result
    } catch {
        $timer.Stop()
        $reason = if (-not [string]::IsNullOrWhiteSpace($CancellationFile) -and (Test-Path -LiteralPath $CancellationFile)) { 'cancelled' } else { 'probe_error' }
        [pscustomobject]@{ strategy = $Candidate; overall = 'INCONCLUSIVE'; reason = $reason; duration_ms = $timer.ElapsedMilliseconds }
    }
}

if ($Router.Scheme -ne 'http') {
    throw 'Router must be an HTTP LAN endpoint.'
}
if ($UploadStatistics -and ([string]::IsNullOrWhiteSpace($StatisticsToken) -or $StatisticsEndpoint.Scheme -ne 'https')) {
    throw 'Statistics upload needs Z4R_ADAPTIVE_V2_CLIENT_TOKEN (an issued per-install token) and an HTTPS endpoint.'
}
if ($DeepSearch -and -not $FastSearch) {
    throw '-DeepSearch requires -FastSearch.'
}
if ($Explore -and -not $Watch) { throw '-Explore requires -Watch.' }
if ($RampAudit -and -not $Watch) { throw '-RampAudit requires -Watch.' }
if ($Watch) {
    if ($ListEvents -or $FastSearch -or $DeepSearch -or $EventIndex -gt 0 -or
        -not [string]::IsNullOrWhiteSpace($Hostname) -or -not [string]::IsNullOrWhiteSpace($DestinationIp)) {
        throw '-Watch cannot be combined with a one-shot action or explicit target.'
    }
    $processed = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $failureRetryState = Read-AdaptiveFailureRetryState
    $script:AdaptiveFailureRetryState = $failureRetryState
    $script:AdaptiveFailureRetryCooldownTargets = Get-AdaptiveFailureRetryCooldownCount -State $failureRetryState
    try { $script:AdaptiveRevalidationMetrics = Read-AdaptiveAgentMetrics }
    catch {
        [Console]::Error.WriteLine("Adaptive revalidation metrics were reset after a state read error: $($_.Exception.Message)")
        $script:AdaptiveRevalidationMetrics = @{ Path = Get-AdaptiveAgentMetricsPath; RevalidationRecoveries = 0; RevalidationFailures = 0 }
    }
    if ($Explore) { $exploreState = Read-ExploreState }
    $exploreLoadWarningShown = $false
    $rampUnsupportedWarningShown = $false
    Write-Output (if ($RampAudit) { "Watching with low-priority Googlevideo Ramp audit enabled; Ctrl+C stops." } elseif ($Explore) { "Watching with low-priority exploration every $ExploreIntervalSeconds seconds; Ctrl+C stops." } else { "Watching adaptive observations every $WatchIntervalSeconds seconds; Ctrl+C stops." })
    while ($true) {
        try {
            $queue = Invoke-AdaptiveApi @{ action = 'events' }
            if ($queue.schema_version -ne 1 -or $queue.mode -notin @('OFF', 'OBSERVE', 'TEST_ONLY', 'AGENT_BETA') -or $null -eq $queue.events) {
                throw 'Router returned an invalid observation response.'
            }
            Send-AdaptiveAgentStatus -Stage 'idle'
            if ($queue.mode -in @('TEST_ONLY', 'AGENT_BETA')) {
                $exploreInterval = if ($UploadStatistics) { [Math]::Max(240, $ExploreIntervalSeconds) } else { $ExploreIntervalSeconds }
                $exploreDue = -not $Explore -or ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $exploreState.Last -ge ($exploreInterval + $exploreState.Jitter))
                $hasUrgentRequest = @($queue.events | Where-Object { $_.status -in @('needs_verify', 'suspected_failure', 'active_rule_degraded') }).Count -gt 0
                $hasPassiveTarget = @($queue.events | Where-Object status -eq 'seen').Count -gt 0
                if ($Explore -and $exploreDue -and -not $hasUrgentRequest -and $hasPassiveTarget) {
                    try {
                        $load = Get-ExploreMachineLoad
                        Send-AdaptiveAgentStatus -Stage 'idle' -CpuPercent $load.CpuPercent `
                            -FreeMemoryBytes $load.FreeMemoryBytes -NetworkBytesPerSecond $load.NetworkBytesPerSecond
                        $exploreDue = Test-ExploreBudget -CpuPercent $load.CpuPercent -NetworkBytesPerSecond $load.NetworkBytesPerSecond `
                            -MaxCpuPercent $ExploreMaxCpuPercent -MaxNetworkBytesPerSecond $ExploreMaxNetworkBytesPerSecond
                        if ($exploreDue) {
                            $router = Invoke-AdaptiveApi @{ action = 'resources' }
                            if ($null -eq $router.load1_per_core -or $null -eq $router.mem_available_kib -or
                                $null -eq $router.active_probes) { throw 'Router resource counters are incomplete.' }
                            $routerLoad = [double]$router.load1_per_core
                            $routerMemory = [long]$router.mem_available_kib
                            $routerProbes = [int]$router.active_probes
                            if ($router.schema_version -ne 1 -or $routerLoad -lt 0 -or $routerLoad -gt 1024 -or
                                $routerMemory -lt 0 -or $routerProbes -lt 0) {
                                throw 'Router returned invalid resource counters.'
                            }
                            Send-AdaptiveAgentStatus -Stage 'idle' -RouterLoadMilli ([int][Math]::Round($routerLoad * 1000)) `
                                -RouterMemoryAvailableKiB $routerMemory -RouterActiveProbes $routerProbes
                            $exploreDue = Test-ExploreRouterBudget -Load1PerCore $routerLoad `
                                -MemoryAvailableKiB $routerMemory -ActiveProbes $routerProbes `
                                -MaxLoadPerCore $ExploreMaxRouterLoadPerCore -MinMemoryMiB $ExploreMinRouterMemoryMiB
                        }
                    } catch {
                        $exploreDue = $false
                        if (-not $exploreLoadWarningShown) {
                            [Console]::Error.WriteLine('Adaptive exploration is paused because PC or router resource counters are unavailable.')
                            $exploreLoadWarningShown = $true
                        }
                    }
                }
                $next = @($queue.events | Sort-Object @{ Expression = { if ($_.request_id) { 0 } elseif ($_.status -in @('suspected_failure', 'active_rule_degraded')) { 1 } else { 2 } } }, { [long]$_.observed_at } | Where-Object {
                    $_.protocol -eq 'tls' -and $_.status -in @('seen', 'needs_verify', 'suspected_failure', 'active_rule_degraded') -and
                    $_.hostname -match '^(?=.{1,253}$)([a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)(\.([a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?))*$' -and
                    $_.destination_ip -match '^([0-9]{1,3}\.){3}[0-9]{1,3}$' -and
                    [int]$_.profile_id -ge 1 -and [int]$_.profile_id -le 4 -and
                    $_.scope -match '^(default|mark:[1-9][0-9]{0,4})$'
                } | Where-Object {
                    -not $Explore -or $_.status -in @('needs_verify', 'suspected_failure', 'active_rule_degraded') -or $exploreDue
                } | Where-Object {
                    if ($_.request_id -match '^[a-f0-9]{32}$') {
                        $key = 'request|{0}' -f $_.request_id
                    } else {
                        $key = 'event|{0}|{1}|{2}|{3}|{4}' -f $_.hostname, $_.destination_ip, $_.profile_id, $_.scope, $_.observed_at
                    }
                    if ($_.status -in @('suspected_failure', 'active_rule_degraded')) {
                        $retryKey = Get-AdaptiveFailureRetryKey -Event $_
                        if (-not (Test-AdaptiveFailureRetryDue -State $failureRetryState -Key $retryKey)) { return $false }
                        [void]$processed.Remove($key)
                    }
                    -not $processed.Contains($key)
                } | Select-Object -First 1)
                if ($next.Count -eq 0) {
                    $deepState = Read-AdaptiveDeepSearchState
                    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                    $dueDeep = Get-AdaptiveDueDeepSearchJob -State $deepState -Now $now
                    if ($null -ne $dueDeep) {
                        $dueDeep.NextAt = $now + 120
                        Save-AdaptiveDeepSearchJob -State $deepState -Job $dueDeep
                        $next = @([pscustomobject]@{
                            status = 'deep_search'; hostname = $dueDeep.Hostname; destination_ip = $dueDeep.DestinationIp
                            profile_id = $dueDeep.ProfileId; scope = $dueDeep.Scope; observed_at = $dueDeep.NextAt
                        })
                    }
                }
                if ($RampAudit -and $queue.mode -eq 'AGENT_BETA' -and -not $hasUrgentRequest -and $next.Count -eq 0) {
                    try {
                        $rampLoad = Get-ExploreMachineLoad
                        Send-AdaptiveAgentStatus -Stage 'idle' -CpuPercent $rampLoad.CpuPercent `
                            -FreeMemoryBytes $rampLoad.FreeMemoryBytes -NetworkBytesPerSecond $rampLoad.NetworkBytesPerSecond
                        $rampBudget = Test-ExploreBudget -CpuPercent $rampLoad.CpuPercent -NetworkBytesPerSecond $rampLoad.NetworkBytesPerSecond `
                            -MaxCpuPercent $ExploreMaxCpuPercent -MaxNetworkBytesPerSecond $ExploreMaxNetworkBytesPerSecond
                        if ($rampBudget) {
                            $rampResources = Invoke-AdaptiveApi @{ action = 'resources' }
                            if ($rampResources.schema_version -eq 1 -and $null -ne $rampResources.load1_per_core -and
                                $null -ne $rampResources.mem_available_kib -and $null -ne $rampResources.active_probes) {
                                Send-AdaptiveAgentStatus -Stage 'idle' -RouterLoadMilli ([int][Math]::Round([double]$rampResources.load1_per_core * 1000)) `
                                    -RouterMemoryAvailableKiB ([long]$rampResources.mem_available_kib) -RouterActiveProbes ([int]$rampResources.active_probes)
                            }
                            if ($rampResources.schema_version -eq 1 -and $null -ne $rampResources.load1_per_core -and
                                $null -ne $rampResources.mem_available_kib -and $null -ne $rampResources.active_probes -and
                                (Test-ExploreRouterBudget -Load1PerCore ([double]$rampResources.load1_per_core) `
                                    -MemoryAvailableKiB ([long]$rampResources.mem_available_kib) -ActiveProbes ([int]$rampResources.active_probes) `
                                    -MaxLoadPerCore $ExploreMaxRouterLoadPerCore -MinMemoryMiB $ExploreMinRouterMemoryMiB)) {
                                $rampTargetsResponse = Invoke-AdaptiveApi @{ action = 'ramp_targets' }
                                if ($rampTargetsResponse.schema_version -eq 1 -and $rampTargetsResponse.supported -eq $false) {
                                    if (-not $rampUnsupportedWarningShown) {
                                        [Console]::Error.WriteLine('Adaptive Ramp audit is unsupported on this Keenetic hardware until its late-ACK gate passes.')
                                        $rampUnsupportedWarningShown = $true
                                    }
                                } elseif ($rampTargetsResponse.schema_version -eq 1 -and $null -ne $rampTargetsResponse.targets) {
                                    $rampState = Read-AdaptiveRampAuditState
                                    $rampDue = Get-AdaptiveDueRampAuditTarget -Targets @($rampTargetsResponse.targets) -State $rampState
                                    if ($null -ne $rampDue) {
                                        $rampCatalog = Invoke-AdaptiveApi @{
                                            action = 'candidates'; hostname = [string]$rampDue.Target.hostname
                                            destination_ip = [string]$rampDue.Target.destination_ip; profile_id = 2; scope = [string]$rampDue.Target.scope
                                        }
                                        $rampNumbers = @($rampCatalog.candidate_numbers)
                                        $rampCatalogVersion = [string]$rampCatalog.candidate_set_version
                                        if ($rampCatalog.status -eq 'already_confirmed') {
                                            $rampCatalogVersion = [string]$rampCatalog.catalog_version
                                            $rampNumbers = @([string]$rampCatalog.strategy_number)
                                        }
                                        $catalogValid = $rampCatalog.schema_version -eq 1 -and $rampCatalog.profile_id -eq 2 -and
                                            $rampCatalog.scope -eq [string]$rampDue.Target.scope -and
                                            $rampCatalogVersion -match '^sha256:[a-f0-9]{64}$' -and
                                            $rampCatalog.status -in @('ready', 'already_confirmed') -and $rampNumbers.Count -gt 0 -and
                                            @($rampNumbers | Where-Object { $_ -notmatch '^[1-9][0-9]{0,2}$' }).Count -eq 0
                                        if ($catalogValid -and $rampDue.Step -gt 0 -and
                                            ($rampDue.CandidateSetVersion -ne $rampCatalogVersion -or
                                             $rampDue.StrategyNumber -notin @($rampNumbers | ForEach-Object { [int]$_ }))) {
                                            Save-AdaptiveRampAuditAttempt -State $rampState -Key $rampDue.Key -GroupId $rampDue.GroupKey `
                                                -Outcome pending -CooldownSeconds 300
                                            Write-Output ("Ramp audit cursor reset for {0}: strategy catalog changed." -f $rampDue.Target.hostname)
                                            $catalogValid = $false
                                        }
                                        if ($catalogValid) {
                                            $strategyNumber = if ($rampDue.Step -gt 0) { [int]$rampDue.StrategyNumber } else { [int]$rampNumbers[0] }
                                            if ($strategyNumber -ge 1 -and $strategyNumber -le 999) {
                                                $rampDue.CandidateSetVersion = $rampCatalogVersion
                                                $rampDue.StrategyNumber = $strategyNumber
                                                $next = @([pscustomobject]@{
                                                    status = 'ramp_audit'; hostname = [string]$rampDue.Target.hostname
                                                    destination_ip = [string]$rampDue.Target.destination_ip; profile_id = 2
                                                    scope = [string]$rampDue.Target.scope; observed_at = [long]$rampDue.Target.observed_at
                                                    ramp_audit = $rampDue
                                                })
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    } catch {
                        [Console]::Error.WriteLine("Adaptive Ramp audit is paused: $($_.Exception.Message)")
                    }
                } elseif ($RampAudit -and $queue.mode -ne 'AGENT_BETA' -and -not $exploreLoadWarningShown) {
                    [Console]::Error.WriteLine('Adaptive Ramp audit requires router mode AGENT_BETA and an explicitly enabled Ramp pool.')
                    $exploreLoadWarningShown = $true
                }
                if ($next.Count -gt 0) {
                    $event = $next[0]
                    if ($event.request_id -match '^[a-f0-9]{32}$') {
                        $key = 'request|{0}' -f $event.request_id
                        foreach ($observed in $queue.events) {
                            if ($observed.status -in @('seen', 'suspected_failure', 'active_rule_degraded') -and $observed.hostname -eq $event.hostname -and
                                $observed.destination_ip -eq $event.destination_ip -and $observed.profile_id -eq $event.profile_id -and $observed.scope -eq $event.scope) {
                                [void]$processed.Add(('event|{0}|{1}|{2}|{3}|{4}' -f $observed.hostname, $observed.destination_ip, $observed.profile_id, $observed.scope, $observed.observed_at))
                            }
                        }
                    } else {
                        $key = 'event|{0}|{1}|{2}|{3}|{4}' -f $event.hostname, $event.destination_ip, $event.profile_id, $event.scope, $event.observed_at
                    }
                    if ($event.status -ne 'ramp_audit' -and (-not $Explore -or $event.status -ne 'seen')) { [void]$processed.Add($key) }
                    if ($processed.Count -gt 512) { $processed.Clear() }
                    $eventAckEligible = $event.status -notin @('suspected_failure', 'active_rule_degraded')
                    $eventRetryDelay = 60
                    if ($event.status -eq 'ramp_audit') {
                        Send-AdaptiveAgentStatus -Stage 'ramp_audit'
                        Write-Output ("Starting low-priority Ramp comparison {0} for {1} ({2})." -f $event.ramp_audit.TreatmentVariant, $event.hostname, $event.destination_ip)
                    } else {
                        Write-Output ("Starting FastSearch for {0} ({1}, profile {2}, {3})." -f $event.hostname, $event.destination_ip, $event.profile_id, $event.scope)
                    }
                    $eventPreempted = $false
                    try {
                        if ($event.status -eq 'ramp_audit') {
                            $audit = $event.ramp_audit
                            $rampProbe = Invoke-AdaptiveExplorationProbe -Event $event -Strategy ([int]$audit.StrategyNumber) `
                                -ProbeTreatmentVariant ([string]$audit.TreatmentVariant)
                            $result = $rampProbe.probe_result
                            $transition = Get-AdaptiveRampAuditTransition -Audit $audit -Result $result -ProbeStatus ([string]$rampProbe.status)
                            try {
                                Save-AdaptiveRampAuditAttempt -State (Read-AdaptiveRampAuditState) -Key $audit.Key -GroupId $audit.GroupKey `
                                    -Outcome $transition.Outcome -PlainSuccesses $transition.PlainSuccesses -RampSuccesses $transition.RampSuccesses -Step $transition.Step `
                                    -CandidateSetVersion $(if ($transition.Step -gt 0) { $audit.CandidateSetVersion } else { '' }) `
                                    -MediaUrlHash $(if ($transition.Step -gt 0) { $transition.MediaUrlHash } else { '' }) `
                                    -ProofTestIds $(if ($transition.Step -gt 0) { $audit.ProofTestIds } else { '' }) `
                                    -ProofTestId $(if ($transition.Step -gt 0) { [string]$result.test_id } else { '' }) `
                                    -StrategyNumber $(if ($transition.Step -gt 0) { [int]$audit.StrategyNumber } else { 0 }) `
                                    -CooldownSeconds $(if ($transition.Outcome -eq 'plain_confirmed') { 18000 } else { 300 })
                            } catch { [Console]::Error.WriteLine("Adaptive Ramp audit cursor could not be saved: $($_.Exception.Message)") }
                            if ($transition.Outcome -eq 'plain_confirmed') {
                                $proofIds = @()
                                if (-not [string]::IsNullOrWhiteSpace([string]$audit.ProofTestIds)) {
                                    $proofIds = @([string]$audit.ProofTestIds -split ',')
                                }
                                $proofIds += [string]$result.test_id
                                try {
                                    if ($proofIds.Count -ne 4 -or $proofIds -contains '') { throw 'Ramp controller proof set is incomplete.' }
                                    $exemption = Invoke-AdaptiveApi @{
                                        action = 'ramp_exempt_apply'; hostname = [string]$event.hostname
                                        destination_ip = [string]$event.destination_ip; scope = [string]$event.scope
                                        test_ids = ($proofIds -join ',')
                                    }
                                    if ($exemption.status -ne 'ramp_exempt' -or $exemption.destination_ip -ne [string]$event.destination_ip) {
                                        throw 'Router did not confirm the exact Ramp exemption.'
                                    }
                                    Write-Output ("Ramp was temporarily exempted for {0} ({1}); it expires at {2}." -f $event.hostname, $event.destination_ip, $exemption.expires)
                                } catch {
                                    Write-Output ("Ramp/plain comparison confirmed for {0}, but no exception was applied: {1}" -f $event.hostname, $_.Exception.Message)
                                }
                            } elseif ($transition.Outcome -eq 'plain_degraded_confirmed') {
                                $proofIds = @()
                                if (-not [string]::IsNullOrWhiteSpace([string]$audit.ProofTestIds)) {
                                    $proofIds = @([string]$audit.ProofTestIds -split ',')
                                }
                                $proofIds += [string]$result.test_id
                                try {
                                    if ($proofIds.Count -ne 3 -or $proofIds -contains '') { throw 'Ramp degradation proof set is incomplete.' }
                                    $revocation = Invoke-AdaptiveApi @{
                                        action = 'ramp_exempt_revoke'; hostname = [string]$event.hostname
                                        destination_ip = [string]$event.destination_ip; scope = [string]$event.scope
                                        test_ids = ($proofIds -join ',')
                                    }
                                    if ($revocation.status -ne 'ramp_default' -or $revocation.destination_ip -ne [string]$event.destination_ip) {
                                        throw 'Router did not confirm removal of the exact Ramp exemption.'
                                    }
                                    Write-Output ("Ramp was restored for {0} ({1}) after a verified Ramp/plain/Ramp comparison." -f $event.hostname, $event.destination_ip)
                                } catch {
                                    Write-Output ("Ramp degradation was confirmed for {0}, but the exception could not be revoked: {1}" -f $event.hostname, $_.Exception.Message)
                                }
                            } elseif ($transition.Outcome -eq 'plain_suspect') {
                                Write-Output ("Plain media degraded for {0}; running a Ramp control before any exception change." -f $event.hostname)
                            } elseif ($transition.Outcome -eq 'plain_failed') {
                                Write-Output ("Plain control failed for {0}; no Ramp exception was created." -f $event.hostname)
                            } elseif ($transition.Outcome -eq 'inconclusive') {
                                Write-Output ("Ramp comparison for {0} was inconclusive; the comparison sequence will restart after cooldown." -f $event.hostname)
                            }
                        } elseif ($Explore -and $event.status -eq 'seen') {
                            $targetKey = Get-ExploreTargetKey -TargetHost ([string]$event.hostname) -TargetIp ([string]$event.destination_ip) `
                                -TargetProfile ([int]$event.profile_id) -TargetScope ([string]$event.scope)
                            $cursorRows = @($exploreState.Rows | Where-Object Key -eq $targetKey | Select-Object -First 1)
                            $cursor = if ($cursorRows.Count -gt 0) { $cursorRows[0] } else { $null }
                            $candidateRequest = @{
                                action = 'candidates'; hostname = [string]$event.hostname; destination_ip = [string]$event.destination_ip
                                profile_id = [string]$event.profile_id; scope = [string]$event.scope; order = 'exploration'; offset = 0; limit = 1
                            }
                            $catalog = Invoke-AdaptiveApi $candidateRequest
                            if ($catalog.schema_version -ne 1 -or $catalog.status -notin @('ready', 'complete') -or
                                $catalog.profile_id -ne [int]$event.profile_id -or $catalog.scope -ne [string]$event.scope -or
                            $catalog.candidate_set_version -notmatch '^sha256:[a-f0-9]{64}$' -or
                            $catalog.profile_strategy_count -notmatch '^[1-9][0-9]{0,2}$' -or
                            $catalog.candidate_count -ne $catalog.profile_strategy_count) { throw 'Invalid exploration catalog response.' }
                            $count = [int]$catalog.profile_strategy_count
                            $candidateSetVersion = [string]$catalog.candidate_set_version
                            $offset = if ($null -ne $cursor -and $cursor.Count -eq $count -and
                                $cursor.CandidateSetVersion -eq $candidateSetVersion) { $cursor.Offset } else { 0 }
                            if ($offset -ge $count) { $offset = 0 }
                            $candidateRequest.offset = $offset
                            $candidate = Invoke-AdaptiveApi $candidateRequest
                            $numbers = @($candidate.candidate_numbers)
                            if ($candidate.schema_version -ne 1 -or $candidate.status -ne 'ready' -or $candidate.source -ne 'family-diverse-local-order' -or
                                $candidate.candidate_set_version -ne $candidateSetVersion -or
                                $candidate.candidate_offset -ne $offset -or $candidate.profile_strategy_count -ne $count -or
                                $candidate.candidate_count -ne $count -or $numbers.Count -ne 1 -or
                                $numbers[0] -notmatch '^[1-9][0-9]{0,2}$' -or [int]$numbers[0] -gt $count) { throw 'Invalid exploration candidate response.' }
                            Write-Output ("Exploring strategy {0}/{1} for {2}." -f $numbers[0], $count, $event.hostname)
                            Send-AdaptiveAgentStatus -Stage 'explore'
                            $nextJitter = if ($ExploreJitterSeconds -gt 0) { Get-Random -Minimum 0 -Maximum ($ExploreJitterSeconds + 1) } else { 0 }
                            Save-ExploreState -State $exploreState -TargetKey $targetKey -NextOffset (($offset + 1) % $count) `
                                -Count $count -JitterSeconds $nextJitter -CandidateSetVersion $candidateSetVersion
                            $exploreState = Read-ExploreState
                            $exploreResult = Invoke-AdaptiveExplorationProbe -Event $event -Strategy ([int]$numbers[0])
                            if ($exploreResult.status -eq 'failure-confirmed') {
                                # The evidence sequence ran four isolated probes; pause long enough to retain the low-priority budget.
                                Save-ExploreState -State $exploreState -TargetKey '' -NextOffset 0 -Count 0 -JitterSeconds 480
                                $exploreState = Read-ExploreState
                            }
                        } else {
                            Send-AdaptiveAgentStatus -Stage $(if ($event.status -eq 'deep_search') { 'deep_search' } else { 'fast_search' })
                            $searchRun = if ($event.status -eq 'deep_search') {
                                Invoke-AdaptiveWatchSearch -Event $event -Deep
                            } else {
                                Invoke-AdaptiveWatchSearch -Event $event
                            }
                            if ($searchRun.preempted) {
                                $eventPreempted = $true
                                [void]$processed.Remove($key)
                                Write-Output ("Search for {0} was preempted by an urgent check." -f $event.hostname)
                            } elseif ($searchRun.output) {
                                Write-Output $searchRun.output
                                try {
                                    $searchSummary = [string]$searchRun.output | ConvertFrom-Json -ErrorAction Stop
                                    if ($searchSummary.schema_version -eq 1) {
                                        if ($event.status -in @('suspected_failure', 'active_rule_degraded') -and $searchSummary.status -in @('found', 'direct', 'all_exhausted')) {
                                            $metricKind = if ($searchSummary.status -in @('found', 'direct')) { 'revalidation_recovery' } else { 'revalidation_failure' }
                                            Add-AdaptiveAgentMetric -Metrics $script:AdaptiveRevalidationMetrics -Kind $metricKind
                                        }
                                        Send-AdaptiveAgentStatus -Stage 'idle' -Outcome ([string]$searchSummary.status) `
                                            -CandidatesChecked ([int]$searchSummary.fast_candidate_count + [int]$searchSummary.deep_candidate_count) `
                                            -FastCandidates ([int]$searchSummary.fast_candidate_count) -DeepCandidates ([int]$searchSummary.deep_candidate_count) `
                                            -DurationMs ([long]$searchSummary.duration_ms) -TimeToFirstSuccessMs ([long]$searchSummary.time_to_first_success_ms)
                                    }
                                } catch { }
                                if ($event.status -in @('suspected_failure', 'active_rule_degraded')) {
                                    $eventAckEligible = Test-AdaptiveFailureEventAckEligible -SearchOutput ([string]$searchRun.output)
                                    try {
                                        $searchSummary = [string]$searchRun.output | ConvertFrom-Json -ErrorAction Stop
                                        if ($searchSummary.schema_version -eq 1 -and $searchSummary.status -eq 'stopped_rate_limit') {
                                            $eventRetryDelay = 900
                                        }
                                    } catch { }
                                }
                            }
                        }
                    } finally {
                        if ($event.status -in @('suspected_failure', 'active_rule_degraded') -and -not $eventPreempted) {
                            try {
                                if ($eventAckEligible) {
                                    Clear-AdaptiveFailureRetry -State $failureRetryState -Key (Get-AdaptiveFailureRetryKey -Event $event)
                                    $failureRetryState = Read-AdaptiveFailureRetryState
                                    $script:AdaptiveFailureRetryState = $failureRetryState
                                    $script:AdaptiveFailureRetryCooldownTargets = Get-AdaptiveFailureRetryCooldownCount -State $failureRetryState
                                } else {
                                    Save-AdaptiveFailureRetry -State $failureRetryState -Event $event -DelayBaseSeconds $eventRetryDelay
                                    $failureRetryState = Read-AdaptiveFailureRetryState
                                    $script:AdaptiveFailureRetryState = $failureRetryState
                                    $script:AdaptiveFailureRetryCooldownTargets = Get-AdaptiveFailureRetryCooldownCount -State $failureRetryState
                                }
                            } catch {
                                $eventAckEligible = $false
                                [Console]::Error.WriteLine("Adaptive revalidation retry state could not be saved: $($_.Exception.Message)")
                            }
                        }
                        if ($Explore -and $event.status -in @('needs_verify', 'suspected_failure', 'active_rule_degraded')) {
                            try {
                                $nextJitter = if ($ExploreJitterSeconds -gt 0) { Get-Random -Minimum 0 -Maximum ($ExploreJitterSeconds + 1) } else { 0 }
                                Save-ExploreState -State $exploreState -TargetKey '' -NextOffset 0 -Count 0 -JitterSeconds $nextJitter
                                $exploreState = Read-ExploreState
                            }
                            catch { [Console]::Error.WriteLine("Adaptive exploration: could not persist priority cooldown: $($_.Exception.Message)") }
                        }
                        if ($event.request_id -match '^[a-f0-9]{32}$' -and $event.status -ne 'ramp_audit' -and -not $eventPreempted) {
                            try { Invoke-AdaptiveApi @{ action = 'ack_request'; request_id = [string]$event.request_id } | Out-Null }
                            catch { [Console]::Error.WriteLine("Adaptive watch: could not acknowledge request: $($_.Exception.Message)") }
                        }
                        if ($event.status -ne 'ramp_audit' -and -not ($Explore -and $event.status -eq 'seen') -and $event.status -ne 'deep_search' -and -not $eventPreempted -and $eventAckEligible) {
                            try {
                                Invoke-AdaptiveApi @{
                                    action = 'ack_event'; hostname = [string]$event.hostname
                                    destination_ip = [string]$event.destination_ip; profile_id = [string]$event.profile_id
                                    scope = [string]$event.scope
                                } | Out-Null
                            } catch { [Console]::Error.WriteLine("Adaptive watch: could not record event cooldown: $($_.Exception.Message)") }
                        }
                    }
                }
            }
        } catch {
            [Console]::Error.WriteLine("Adaptive watch: $($_.Exception.Message)")
        }
        if ($UploadStatistics) {
            try {
                $statsState = Read-AdaptiveStatsState
                [void](Invoke-AdaptiveStatsUpload -State $statsState -Token $StatisticsToken -Endpoint $StatisticsEndpoint)
            } catch { [Console]::Error.WriteLine("Adaptive statistics: $($_.Exception.Message)") }
        }
        Start-Sleep -Seconds $WatchIntervalSeconds
    }
}
if ($ListEvents) {
    if ($EventIndex -gt 0 -or $FastSearch -or $DeepSearch) { throw '-ListEvents cannot be combined with a probe action.' }
    (Invoke-AdaptiveApi @{ action = 'events' }) | ConvertTo-Json -Compress -Depth 6
    return
}
if ($EventIndex -gt 0) {
    if (-not [string]::IsNullOrWhiteSpace($Hostname) -or -not [string]::IsNullOrWhiteSpace($DestinationIp)) {
        throw 'Use either -EventIndex or an explicit hostname and destination IPv4.'
    }
    $queue = Invoke-AdaptiveApi @{ action = 'events' }
    $eventList = @($queue.events)
    if ($EventIndex -gt $eventList.Count) {
        throw "Observation index $EventIndex is not present in the current queue."
    }
    $event = $eventList[$EventIndex - 1]
    $Hostname = [string]$event.hostname
    $DestinationIp = [string]$event.destination_ip
    $ProfileId = [int]$event.profile_id
    $Scope = [string]$event.scope
}
if ([string]::IsNullOrWhiteSpace($Hostname) -or [string]::IsNullOrWhiteSpace($DestinationIp) -or
    $Hostname.Length -gt 253 -or $Hostname -notmatch '^(?=.{1,253}$)([a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)(\.([a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?))*$') {
    throw 'Specify a DNS hostname and destination IPv4, or use -ListEvents.'
}
$adaptiveGroupId = Get-AdaptiveGooglevideoGroupId -Hostname $Hostname
$isGooglevideoHost = $Hostname -match '(?i)^(?:[a-z0-9-]+\.)+googlevideo\.com$'
$recipeId = if ($ProfileId -eq 5 -and $isGooglevideoHost) { 'googlevideo-quic-h3-media-v1' }
    elseif ($ProfileId -eq 2 -and $isGooglevideoHost) { 'googlevideo-tcp-media-v1' } else { 'tls-http1-v1' }
if ($ProfileId -eq 5 -and $recipeId -ne 'googlevideo-quic-h3-media-v1') {
    throw 'Profile 5 adaptive probes require an exact Googlevideo hostname and use HTTP/3 only.'
}
$treatmentVariant = $TreatmentVariant
if ($recipeId -eq 'googlevideo-tcp-media-v1') {
    if ($treatmentVariant -notin @('standard', 'gv_tcp_plain', 'gv_tcp_ramp', 'gv_tcp_ramp_syndata')) {
        throw 'Invalid Googlevideo TCP treatment variant.'
    }
} elseif ($treatmentVariant -ne 'standard') {
    throw 'Googlevideo treatment variants require profile 2 and a Googlevideo hostname.'
}
if ($treatmentVariant -ne 'standard' -and ($FastSearch -or $DeepSearch -or $Watch -or $Explore)) {
    throw 'Ramp treatment variants are single-probe experiments; FastSearch, Watch, and Explore use standard treatment.'
}

if ($FastSearch) {
    $searchStartedAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $timeToFirstSuccess = $null
    $deepState = Read-AdaptiveDeepSearchState
    $deepKey = Get-AdaptiveDeepSearchKey -Hostname $Hostname -DestinationIp $DestinationIp -ProfileId $ProfileId -Scope $Scope -RecipeId $recipeId
    $rankedFingerprints = @()
    $rankedFingerprints = @(Get-AdaptiveRankingHint -Enabled:$UseSharedRankings -ProfileId $ProfileId `
        -Endpoint $AdaptiveRankingEndpoint -RecipeId $recipeId -TreatmentVariant $treatmentVariant `
        -IdentityRequest { Invoke-AdaptiveApi @{ action = 'stats_identity' } })
    $rankedFingerprintCsv = $rankedFingerprints -join ','
    $candidateSet = Invoke-AdaptiveApi @{
        action = 'candidates'; hostname = $Hostname.ToLowerInvariant(); destination_ip = $DestinationIp
        profile_id = $ProfileId; scope = $Scope; ranked_fingerprints = $rankedFingerprintCsv
        force_revalidate = [int]$ForceRevalidate.IsPresent
    }
    if ($candidateSet.schema_version -ne 1 -or $candidateSet.profile_id -ne $ProfileId -or
        $candidateSet.scope -ne $Scope -or $candidateSet.protocol -ne $(if ($recipeId -eq 'googlevideo-quic-h3-media-v1') { 'udp' } elseif ($recipeId -eq 'googlevideo-tcp-media-v1') { 'googlevideo-tcp' } else { 'tls' }) -or
        $candidateSet.recipe_id -ne $recipeId) {
        throw 'Router returned an invalid local candidate response.'
    }
    if ($candidateSet.status -eq 'already_confirmed') {
        if ($candidateSet.strategy_number -notmatch '^(0|[1-9][0-9]{0,2})$' -or
            $candidateSet.winner_kind -ne $(if ([int]$candidateSet.strategy_number -eq 0) { 'DIRECT' } else { 'STRATEGY' }) -or
            $candidateSet.strategy_fingerprint -notmatch '^sha256:[0-9a-f]{64}$' -or
            $candidateSet.catalog_version -notmatch '^sha256:[0-9a-f]{64}$' -or
            $candidateSet.expires -le [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) {
            throw 'Router returned an invalid or expired local confirmation.'
        }
        Remove-AdaptiveDeepSearchJob -State $deepState -Key $deepKey
        [pscustomobject]@{
            schema_version = 1
            status = 'already_confirmed'
            target = @{ hostname = $Hostname.ToLowerInvariant(); destination_ip = $DestinationIp; profile_id = $ProfileId; scope = $Scope; group_id = $adaptiveGroupId }
            winner_strategy = [int]$candidateSet.strategy_number
            winner_kind = [string]$candidateSet.winner_kind
            strategy_fingerprint = [string]$candidateSet.strategy_fingerprint
            attempts = @()
        } | ConvertTo-Json -Compress -Depth 8
        return
    }
    $candidateNumbers = @($candidateSet.candidate_numbers)
    $profileStrategyCount = [int]$candidateSet.profile_strategy_count
    $candidateCount = [int]$candidateSet.candidate_count
    $candidateSetVersion = [string]$candidateSet.candidate_set_version
    $expectedCandidateCount = [Math]::Min(10, $candidateCount)
    $expectedStatus = if ($expectedCandidateCount -gt 0) { 'ready' } else { 'complete' }
    if ($candidateSet.status -ne $expectedStatus -or $candidateSet.source -notin @('local-profile-order', 'local-confirmations-first', 'remote-rankings-first', 'active-rule-revalidation') -or
        $candidateSet.candidate_offset -ne 0 -or
        $candidateSetVersion -notmatch '^sha256:[0-9a-f]{64}$' -or
        $candidateSet.profile_strategy_count -notmatch '^[1-9][0-9]{0,2}$' -or
        $candidateSet.candidate_count -notmatch '^(0|[1-9][0-9]{0,2})$' -or $candidateCount -gt $profileStrategyCount -or
        $candidateNumbers.Count -ne $expectedCandidateCount -or
        @($candidateNumbers | Where-Object { $_ -notmatch '^[1-9][0-9]{0,2}$' }).Count -gt 0 -or
        @($candidateNumbers | Select-Object -Unique).Count -ne $candidateNumbers.Count -or
        @($candidateNumbers | Where-Object { [int]$_ -gt [int]$profileStrategyCount }).Count -gt 0) {
        throw 'Router returned an invalid or conflicting local candidate list.'
    }
    $candidateNumbers = @($candidateNumbers | Select-Object -First $MaxCandidates)
    $savedDeepRows = @($deepState.Jobs | Where-Object Key -eq $deepKey | Select-Object -First 1)
    $resumeDeep = $false
    $resumeOffset = $candidateNumbers.Count
    if ($ResumeDeepSearch -and $savedDeepRows.Count -eq 1 -and
        $savedDeepRows[0].CandidateSetVersion -eq $candidateSetVersion -and
        $savedDeepRows[0].CandidateCount -eq $candidateCount -and
        $savedDeepRows[0].Offset -lt $candidateCount) {
        $resumeDeep = $true
        $resumeOffset = $savedDeepRows[0].Offset
    } elseif ($ResumeDeepSearch -and $savedDeepRows.Count -eq 1) {
        Remove-AdaptiveDeepSearchJob -State $deepState -Key $deepKey
    }
    $attempts = [System.Collections.Generic.List[object]]::new()
    $winner = $null
    $winnerKind = $null
    $searchStopped = $false
    $searchStopReason = $null
    $searchStopStatus = $null
    if ($resumeDeep) {
        $directResult = [pscustomobject]@{ overall = 'SKIPPED'; reason = 'deep_resume' }
    } else {
        $directResult = Invoke-AdaptiveStrategyCandidate -Candidate 0
        $attempts.Add($directResult)
        $directTransition = Get-AdaptiveSearchTransition -Result $directResult
        if ($directTransition -eq 'success') {
            $winner = 0
            $winnerKind = 'DIRECT'
            $timeToFirstSuccess = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $searchStartedAt
        } elseif ($directTransition -in @('stop_infra', 'cooldown')) {
            $searchStopped = $true
            $searchStopReason = "direct_$($directResult.reason)"
            $searchStopStatus = if ($directTransition -eq 'cooldown') { 'stopped_rate_limit' }
                elseif ($directResult.reason -eq 'cancelled') { 'cancelled' } else { 'stopped_infra' }
        }
        if ($null -eq $winner -and -not $searchStopped) {
            if ($CandidatePauseSeconds -gt 0) { Start-Sleep -Seconds $CandidatePauseSeconds }
            foreach ($candidate in $candidateNumbers) {
                $probeResult = Invoke-AdaptiveStrategyCandidate -Candidate ([int]$candidate)
                $attempts.Add($probeResult)
                $transition = Get-AdaptiveSearchTransition -Result $probeResult
                if ($transition -eq 'success') {
                    $winner = [int]$candidate
                    $winnerKind = 'STRATEGY'
                    $timeToFirstSuccess = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $searchStartedAt
                    break
                }
                if ($transition -in @('stop_infra', 'cooldown')) {
                    $searchStopped = $true
                    $searchStopReason = "candidate_$($probeResult.reason)"
                    $searchStopStatus = if ($transition -eq 'cooldown') { 'stopped_rate_limit' }
                        elseif ($probeResult.reason -eq 'cancelled') { 'cancelled' } else { 'stopped_infra' }
                    break
                }
                if ($candidate -ne $candidateNumbers[-1] -and $CandidatePauseSeconds -gt 0) {
                    Start-Sleep -Seconds $CandidatePauseSeconds
                }
            }
        }
    }
    $fastAttemptCount = if ($resumeDeep) { 0 } else { $attempts.Count - 1 }
    $fastComplete = $resumeDeep -or (-not $searchStopped -and $fastAttemptCount -eq $candidateNumbers.Count)
    $deepCount = 0
    $deepOffset = if ($resumeDeep) { $resumeOffset } else { $candidateNumbers.Count }
    $searchedCandidates = [System.Collections.Generic.HashSet[int]]::new()
    if (-not $resumeDeep) { foreach ($candidate in $candidateNumbers) { [void]$searchedCandidates.Add([int]$candidate) } }
    if (($DeepSearch -or $resumeDeep) -and $null -eq $winner -and $fastComplete -and $deepOffset -lt $candidateCount) {
        while ($deepCount -lt $DeepSearchMaxCandidates -and $deepOffset -lt $candidateCount) {
            $pageLimit = [Math]::Min(10, $DeepSearchMaxCandidates - $deepCount)
            try {
                $page = Invoke-AdaptiveApi @{
                    action = 'candidates'; hostname = $Hostname.ToLowerInvariant(); destination_ip = $DestinationIp
                    profile_id = $ProfileId; scope = $Scope; offset = $deepOffset; limit = $pageLimit
                    candidate_set_version = $candidateSetVersion; ranked_fingerprints = $rankedFingerprintCsv
                    force_revalidate = [int]$ForceRevalidate.IsPresent
                }
            } catch {
                $searchStopped = $true
                $searchStopReason = if ($_.Exception.Message -match 'HTTP 409') { 'candidate_page_conflict' } else { 'candidate_page_request_failed' }
                break
            }
            $pageNumbers = @($page.candidate_numbers)
            $expectedPageCount = [Math]::Min($pageLimit, $candidateCount - $deepOffset)
            if ($page.schema_version -ne 1 -or $page.status -ne 'ready' -or
                $page.source -notin @('local-profile-order', 'local-confirmations-first', 'remote-rankings-first', 'active-rule-revalidation') -or
                $page.profile_id -ne $ProfileId -or $page.scope -ne $Scope -or
                $page.candidate_set_version -ne $candidateSetVersion -or
                $page.profile_strategy_count -ne $profileStrategyCount -or $page.candidate_count -ne $candidateCount -or
                $page.candidate_offset -ne $deepOffset -or
                $pageNumbers.Count -ne $expectedPageCount -or
                @($pageNumbers | Where-Object { $_ -notmatch '^[1-9][0-9]{0,2}$' }).Count -gt 0 -or
                @($pageNumbers | Select-Object -Unique).Count -ne $pageNumbers.Count -or
                @($pageNumbers | Where-Object { [int]$_ -lt 1 -or [int]$_ -gt [int]$profileStrategyCount -or $searchedCandidates.Contains([int]$_) }).Count -gt 0) {
                $searchStopped = $true
                $searchStopReason = 'candidate_page_validation_failed'
                break
            }
            foreach ($candidate in $pageNumbers) {
                [void]$searchedCandidates.Add([int]$candidate)
                $probeResult = Invoke-AdaptiveStrategyCandidate -Candidate ([int]$candidate)
                $attempts.Add($probeResult)
                $deepCount++
                $deepOffset++
                $transition = Get-AdaptiveSearchTransition -Result $probeResult
                if ($transition -eq 'success') {
                    $winner = [int]$candidate
                    $winnerKind = 'STRATEGY'
                    $timeToFirstSuccess = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $searchStartedAt
                    break
                }
                if ($transition -in @('stop_infra', 'cooldown')) {
                    $searchStopped = $true
                    $searchStopReason = "candidate_$($probeResult.reason)"
                    $searchStopStatus = if ($transition -eq 'cooldown') { 'stopped_rate_limit' }
                        elseif ($probeResult.reason -eq 'cancelled') { 'cancelled' } else { 'stopped_infra' }
                    break
                }
                if ($deepCount -lt $DeepSearchMaxCandidates -and $deepOffset -lt $candidateCount -and $CandidatePauseSeconds -gt 0) {
                    Start-Sleep -Seconds $CandidatePauseSeconds
                }
            }
            if ($null -ne $winner -or $searchStopped) { break }
        }
    }
    $nextDeepOffset = $deepOffset
    $nextDeepAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 120
    if ($searchStopStatus -eq 'stopped_rate_limit' -and $deepCount -gt 0) {
        $nextDeepOffset = $deepOffset - 1
        $nextDeepAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 900
    } elseif ($searchStopStatus -eq 'stopped_rate_limit' -and -not $resumeDeep) {
        $nextDeepOffset = [Math]::Max(0, $fastAttemptCount - 1)
        $nextDeepAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 900
    }
    if ($searchStopStatus -eq 'cancelled' -and $resumeDeep) {
        # Keep the existing exact-target cursor; the urgent probe preempted only this candidate.
    } elseif ($null -ne $winner -or (($DeepSearch -or $resumeDeep) -and $deepOffset -ge $candidateCount)) {
        Remove-AdaptiveDeepSearchJob -State $deepState -Key $deepKey
    } elseif ($searchStopStatus -eq 'stopped_infra') {
        Remove-AdaptiveDeepSearchJob -State $deepState -Key $deepKey
    } elseif ($null -eq $winner -and ($fastComplete -or $searchStopStatus -eq 'stopped_rate_limit') -and $candidateCount -gt 0 -and
        (($deepOffset -lt $candidateCount) -or $searchStopStatus -eq 'stopped_rate_limit') -and
        ($deepCount -gt 0 -or -not $DeepSearch -or $resumeDeep)) {
        $jobOffset = if ($searchStopStatus -eq 'stopped_rate_limit') { $nextDeepOffset }
            elseif ($deepCount -eq 0 -and -not $resumeDeep) { $candidateNumbers.Count }
            else { $nextDeepOffset }
        if ($jobOffset -ge 0 -and $jobOffset -lt $candidateCount) {
            $job = @{ Key = $deepKey; Hostname = $Hostname.ToLowerInvariant(); DestinationIp = $DestinationIp
                ProfileId = $ProfileId; Scope = $Scope; RecipeId = $recipeId; CandidateSetVersion = $candidateSetVersion
                CandidateCount = $candidateCount; Offset = $jobOffset; NextAt = $nextDeepAt }
            Save-AdaptiveDeepSearchJob -State $deepState -Job $job
        } else { Remove-AdaptiveDeepSearchJob -State $deepState -Key $deepKey }
    }
    $finalStatus = if ($winnerKind -eq 'DIRECT') { 'direct' }
        elseif ($null -ne $winner) { 'found' }
        elseif ($searchStopStatus) { $searchStopStatus }
        elseif ($searchStopped -or -not $fastComplete) { 'inconclusive' }
        elseif (-not $DeepSearch -and -not $resumeDeep -and $deepOffset -lt $candidateCount) { 'deep_scheduled' }
        elseif (($DeepSearch -or $resumeDeep) -and $deepOffset -lt $candidateCount) { 'deep_scheduled' }
        elseif ($candidateNumbers.Count -lt [Math]::Min(10, $candidateCount) -and -not $DeepSearch) { 'limit_reached' }
        elseif ($DeepSearch -or $resumeDeep) { 'all_exhausted' }
        else { 'all_exhausted' }
    [pscustomobject]@{
        schema_version = 1
        status = $finalStatus
        search_stop_reason = $searchStopReason
        duration_ms = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $searchStartedAt
        time_to_first_success_ms = $timeToFirstSuccess
        target = @{ hostname = $Hostname.ToLowerInvariant(); destination_ip = $DestinationIp; profile_id = $ProfileId; scope = $Scope; group_id = $adaptiveGroupId }
        profile_strategy_count = $profileStrategyCount
        unique_candidate_count = $candidateCount
        fast_candidate_count = $fastAttemptCount
        direct_result = $directResult.overall
        deep_candidate_count = $deepCount
        deep_search_limit = if ($DeepSearch -or $resumeDeep) { $DeepSearchMaxCandidates } else { 0 }
        winner_strategy = if ($winnerKind -eq 'STRATEGY') { $winner } else { $null }
        winner_kind = $winnerKind
        attempts = $attempts
    } | ConvertTo-Json -Compress -Depth 8
    return
}

$curl = Get-Command curl.exe -ErrorAction Stop
if ($recipeId -eq 'googlevideo-tcp-media-v1' -or $recipeId -eq 'googlevideo-quic-h3-media-v1') {
    $curlVersionLine = & $curl.Source --version 2>$null | Select-Object -First 1
    if (-not (Test-AdaptiveCurlHardSizeLimit -VersionLine ([string]$curlVersionLine))) {
        throw 'Googlevideo media probes require curl 8.4 or newer for a hard response-size limit.'
    }
    if ($recipeId -eq 'googlevideo-quic-h3-media-v1') {
        $curlFeatures = (@(& $curl.Source --version 2>$null) -join "`n")
        $curlHelp = (@(& $curl.Source --help all 2>$null) -join "`n")
        if (-not (Test-AdaptiveCurlHttp3Support -VersionOutput $curlFeatures -HelpOutput $curlHelp)) {
            throw 'Profile 5 probes require curl with HTTP/3 support and --http3-only; TCP fallback is disabled.'
        }
    }
}
$sourcePort = if ($ProbeSourcePort -ge 62000 -and $ProbeSourcePort -le 62999) {
    $ProbeSourcePort
} elseif ($ProbeSourcePort -eq 0) {
    Get-AdaptiveAvailableSourcePort
} else {
    throw 'Probe source port must be in 62000-62999.'
}
if (-not [string]::IsNullOrWhiteSpace($CancellationFile) -and (Test-Path -LiteralPath $CancellationFile)) {
    throw 'Adaptive probe was cancelled before lease creation.'
}
$leaseRequest = @{
    action = 'lease'
    hostname = $Hostname.ToLowerInvariant()
    destination_ip = $DestinationIp
    profile_id = $ProfileId
    scope = $Scope
    local_strategy_number = $StrategyNumber
    source_port = $sourcePort
    recipe_id = $recipeId
}
if ($treatmentVariant -ne 'standard') { $leaseRequest.treatment_variant = $treatmentVariant }
if (-not [string]::IsNullOrWhiteSpace($ProbeOwner)) { $leaseRequest.probe_owner = $ProbeOwner }
$lease = Invoke-AdaptiveApi $leaseRequest
$parsedDestination = $null
$parsedSource = $null
$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
if ($lease.schema_version -ne 1 -or $lease.recipe_id -ne $recipeId -or
    $lease.protocol -ne $(if ($recipeId -eq 'googlevideo-quic-h3-media-v1') { 'udp' } else { 'tcp' }) -or
    (-not [string]::IsNullOrWhiteSpace([string]$lease.treatment_variant) -and $lease.treatment_variant -ne $treatmentVariant) -or
    ($treatmentVariant -ne 'standard' -and $lease.treatment_variant -ne $treatmentVariant) -or
    $lease.port -ne 443 -or $lease.expires -lt ($now + 25) -or $lease.expires -gt ($now + 120) -or
    $lease.hostname -ne $Hostname.ToLowerInvariant() -or $lease.destination_ip -ne $DestinationIp -or
    $lease.profile_id -ne $ProfileId -or $lease.scope -ne $Scope -or $lease.local_strategy_number -ne $StrategyNumber -or
    $lease.test_id -notmatch '^[A-Za-z0-9_-]{1,64}$' -or
    $lease.source_port -ne $sourcePort -or $lease.source_port -lt 62000 -or $lease.source_port -gt 62999 -or
    $lease.profile_id -lt 1 -or $lease.profile_id -gt 5 -or
    $lease.local_strategy_number -lt 0 -or
    $lease.strategy_fingerprint -notmatch '^sha256:[0-9a-f]{64}$' -or
    [string]::IsNullOrWhiteSpace([string]$lease.catalog_version) -or
    -not [Net.IPAddress]::TryParse([string]$lease.destination_ip, [ref]$parsedDestination) -or
    $parsedDestination.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
    -not [Net.IPAddress]::TryParse([string]$lease.source_ip, [ref]$parsedSource) -or
    $parsedSource.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
    throw 'Router returned an invalid or expired adaptive lease.'
}

$result = @{
    schema_version = 1
    test_id = [string]$lease.test_id
    route_verified = $false
    overall = 'INCONCLUSIVE'
    observed_at = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    transport = 'UNKNOWN'
    application = 'UNKNOWN'
    reason = 'probe_error'
    target = @{
        hostname = [string]$lease.hostname
        destination_ip = [string]$lease.destination_ip
        ip_family = 'ipv4'
        protocol = if ($recipeId -eq 'googlevideo-quic-h3-media-v1') { 'udp' } else { 'tcp' }
        port = 443
        profile_id = [int]$lease.profile_id
        scope = [string]$lease.scope
    }
    strategy = @{
        fingerprint = [string]$lease.strategy_fingerprint
        local_number = [int]$lease.local_strategy_number
        catalog_version = [string]$lease.catalog_version
    }
    recipe_id = $recipeId
    treatment_variant = $treatmentVariant
    client_profile = if ($recipeId -eq 'googlevideo-tcp-media-v1') { 'curl-windows-media-v1' }
        elseif ($recipeId -eq 'googlevideo-quic-h3-media-v1') { 'curl-windows-quic-media-v1' }
        else { 'curl-windows-v1' }
    media_bytes = 0L
    media_speed_bps = 0L
    media_duration_ms = 0L
}
$responseFile = [IO.Path]::GetTempFileName()
$headerFile = [IO.Path]::GetTempFileName()
$curlConfigFile = $null
try {
    if ($recipeId -eq 'googlevideo-tcp-media-v1' -or $recipeId -eq 'googlevideo-quic-h3-media-v1') {
        $mediaUrl = [string]$lease.media.url
        $parsedMediaUrl = $null
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $mediaExpiry = 0L
        $contentLength = 0L
        if (-not (Test-AdaptiveMediaUrlShape -Url $mediaUrl -Hostname ([string]$lease.hostname)) -or
            -not [uri]::TryCreate($mediaUrl, [UriKind]::Absolute, [ref]$parsedMediaUrl) -or
            $parsedMediaUrl.Query -notmatch '(?:^|[?&])(?:sig|signature)=' -or
            $parsedMediaUrl.Query -notmatch '(?:^|[?&])expire=([0-9]{1,12})(?:&|$)' -or
            -not [long]::TryParse($Matches[1], [ref]$mediaExpiry) -or $mediaExpiry -lt ($now + 25) -or
            -not [long]::TryParse([string]$lease.media.content_length, [ref]$contentLength) -or $contentLength -lt 4194304 -or
            [string]$lease.media.mime_type -notmatch '^video/(mp4|webm)$') {
            throw 'Router returned an invalid or expiring Googlevideo media URL.'
        }
        $curlConfigFile = [IO.Path]::GetTempFileName()
        [IO.File]::WriteAllText($curlConfigFile, 'url = "' + $mediaUrl + '"' + "`n", [Text.Encoding]::ASCII)
        $writeOut = '%{http_code}' + "`t" + '%{size_download}' + "`t" + '%{remote_ip}' + "`t" + '%{speed_download}' + "`t" + '%{time_total}'
        $curlArgs = @(
            '-q', '--config', $curlConfigFile, '--silent', '--show-error', '--noproxy', '*', '--interface', [string]$lease.source_ip,
            '--local-port', [string]$lease.source_port, '--resolve', "$($lease.hostname):443:$($lease.destination_ip)",
            '--http1.1', '--connect-timeout', '8', '--max-time', '25', '--range', '0-1048575', '--max-filesize', '1048576',
            '--limit-rate', '2M', '--output', $responseFile, '--dump-header', $headerFile, '--write-out', $writeOut
        )
        if ($recipeId -eq 'googlevideo-quic-h3-media-v1') {
            $curlArgs = New-AdaptiveQuicMediaCurlArguments -ConfigFile $curlConfigFile `
                -SourceIp ([string]$lease.source_ip) -SourcePort ([int]$lease.source_port) `
                -Hostname ([string]$lease.hostname) -DestinationIp ([string]$lease.destination_ip) `
                -ResponseFile $responseFile -HeaderFile $headerFile `
                -WriteOut ($writeOut + "`t%{http_version}")
        }
    } else {
        $writeOut = '%{http_code}' + "`t" + '%{size_download}' + "`t" + '%{remote_ip}'
        $curlArgs = @(
            '-q', '--silent', '--show-error', '--noproxy', '*', '--interface', [string]$lease.source_ip,
            '--local-port', [string]$lease.source_port, '--resolve', "$($lease.hostname):443:$($lease.destination_ip)",
            '--http1.1', '--connect-timeout', '8', '--max-time', '25', '--range', '0-65535', '--max-filesize', '65536',
            '--output', $responseFile, '--write-out', $writeOut, "https://$($lease.hostname)/"
        )
    }
    $nativeProbe = Invoke-AdaptiveCurlNative -Executable $curl.Source -Arguments $curlArgs
    $probe = $nativeProbe.Output
    $curlExit = $nativeProbe.ExitCode
    $fields = ([string]$probe).Trim() -split "`t", 6
    $httpCode = 0
    $bytes = 0
    $remoteIp = ''
    $mediaSpeed = 0L
    $mediaDurationMs = 0L
    $httpVersion = ''
    if ($fields.Count -eq 3) {
        [void][int]::TryParse($fields[0], [ref]$httpCode)
        [void][long]::TryParse($fields[1], [ref]$bytes)
        $remoteIp = $fields[2]
    } elseif ($fields.Count -eq 5) {
        [void][int]::TryParse($fields[0], [ref]$httpCode)
        [void][long]::TryParse($fields[1], [ref]$bytes)
        $remoteIp = $fields[2]
        [void][long]::TryParse($fields[3], [ref]$mediaSpeed)
        $mediaSeconds = 0.0
        if ([double]::TryParse($fields[4], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$mediaSeconds)) {
            $mediaDurationMs = [long][Math]::Round($mediaSeconds * 1000)
        }
    } elseif ($fields.Count -eq 6) {
        [void][int]::TryParse($fields[0], [ref]$httpCode)
        [void][long]::TryParse($fields[1], [ref]$bytes)
        $remoteIp = $fields[2]
        [void][long]::TryParse($fields[3], [ref]$mediaSpeed)
        $mediaSeconds = 0.0
        if ([double]::TryParse($fields[4], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$mediaSeconds)) {
            $mediaDurationMs = [long][Math]::Round($mediaSeconds * 1000)
        }
        $httpVersion = [string]$fields[5]
    }
    # An empty remote_ip is normal when curl times out before connecting. Keep
    # that distinct from a connected socket whose peer differs from the lease;
    # the router independently decides route_verified from q65535 + Lua ACK.
    if ($remoteIp -and $remoteIp -ne $lease.destination_ip) {
        $result.reason = 'route_unverified'
    } else {
        if ($recipeId -eq 'googlevideo-tcp-media-v1' -or $recipeId -eq 'googlevideo-quic-h3-media-v1') {
            if ($recipeId -eq 'googlevideo-quic-h3-media-v1') {
                $mediaVerdict = Get-AdaptiveQuicMediaVerdict -HttpVersion $httpVersion -CurlExit $curlExit `
                    -HttpCode $httpCode -Bytes $bytes -RemoteIp $remoteIp -DestinationIp ([string]$lease.destination_ip) `
                    -Headers (Get-Content -LiteralPath $headerFile -Raw) -ContentLength $contentLength `
                    -MimeType ([string]$lease.media.mime_type) -SpeedBps $mediaSpeed
            } else {
                $mediaVerdict = Get-AdaptiveMediaVerdict -CurlExit $curlExit -HttpCode $httpCode -Bytes $bytes `
                    -RemoteIp $remoteIp -DestinationIp ([string]$lease.destination_ip) `
                    -Headers (Get-Content -LiteralPath $headerFile -Raw) -ContentLength $contentLength `
                    -MimeType ([string]$lease.media.mime_type) -SpeedBps $mediaSpeed
            }
            $result.transport = $mediaVerdict.transport
            $result.application = $mediaVerdict.application
            $result.reason = $mediaVerdict.reason
            $result | Add-Member -NotePropertyName media_bytes -NotePropertyValue $bytes -Force
            $result | Add-Member -NotePropertyName media_speed_bps -NotePropertyValue $mediaSpeed -Force
            $result | Add-Member -NotePropertyName media_duration_ms -NotePropertyValue $mediaDurationMs -Force
        } else {
            $verdict = Get-AdaptiveHttpVerdict -CurlExit $curlExit -HttpCode $httpCode -Bytes $bytes
            $result.transport = $verdict.transport
            $result.application = $verdict.application
            $result.reason = $verdict.reason
        }
    }
    $result.observed_at = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $completionBody = @{
        action = 'complete'
        schema_version = $result.schema_version
        test_id = $result.test_id
        route_verified = $result.route_verified
        overall = $result.overall
        observed_at = $result.observed_at
        transport = $result.transport
        application = $result.application
        reason = $result.reason
        hostname = $result.target.hostname
        destination_ip = $result.target.destination_ip
        ip_family = $result.target.ip_family
        protocol = $result.target.protocol
        port = $result.target.port
        profile_id = $result.target.profile_id
        scope = $result.target.scope
        strategy_fingerprint = $result.strategy.fingerprint
        local_strategy_number = $result.strategy.local_number
        catalog_version = $result.strategy.catalog_version
        recipe_id = $result.recipe_id
        treatment_variant = $result.treatment_variant
        client_profile = $result.client_profile
    }
    if ($treatmentVariant -eq 'standard') { $completionBody.Remove('treatment_variant') }
    if ($recipeId -eq 'googlevideo-tcp-media-v1' -or $recipeId -eq 'googlevideo-quic-h3-media-v1') {
        $completionBody.media_bytes = [long]$result.media_bytes
        $completionBody.media_speed_bps = [long]$result.media_speed_bps
        $completionBody.media_duration_ms = [long]$result.media_duration_ms
    }
    if (-not [string]::IsNullOrWhiteSpace($ProbeOwner)) { $completionBody.probe_owner = $ProbeOwner }
    $completion = Invoke-AdaptiveApi $completionBody
    if ($completion.overall -notin @('SUCCESS', 'FAIL', 'INCONCLUSIVE')) {
        throw 'Router did not return an authoritative adaptive verdict.'
    }
    if ($UploadStatistics -and $recipeId -in @('tls-http1-v1', 'googlevideo-tcp-media-v1', 'googlevideo-quic-h3-media-v1')) {
        try {
            $identity = Invoke-AdaptiveApi @{ action = 'stats_identity' }
            if ($identity.schema_version -ne 1 -or [string]::IsNullOrWhiteSpace([string]$identity.provider)) {
                throw 'Router has no validated ISP identity for adaptive statistics.'
            }
            $statsState = Read-AdaptiveStatsState
            [void](Add-AdaptiveStatsResult -State $statsState -Result $completion -Provider ([string]$identity.provider))
            [void](Invoke-AdaptiveStatsUpload -State $statsState -Token $StatisticsToken -Endpoint $StatisticsEndpoint)
        } catch { [Console]::Error.WriteLine("Adaptive statistics: $($_.Exception.Message)") }
    }
    $completion | ConvertTo-Json -Compress -Depth 6
} finally {
    Remove-Item -LiteralPath $responseFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $headerFile -Force -ErrorAction SilentlyContinue
    if ($curlConfigFile) { Remove-Item -LiteralPath $curlConfigFile -Force -ErrorAction SilentlyContinue }
}
