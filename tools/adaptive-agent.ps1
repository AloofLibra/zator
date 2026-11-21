# This repository, including its original source code and implementation, is licensed under GNU GPL v3.0; see LICENSE for the full terms. Redistribution, modification, and reuse must comply with that license and preserve applicable copyright and license notices. Unauthorized copying, including verbatim code copying or presenting this repository implementation or operating logic as your own, may be reported to the relevant hosting platforms.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][uri]$Router,
    [Parameter(Mandatory = $true)][string]$Token,
    [string]$Hostname,
    [string]$DestinationIp,
    [ValidateRange(1, 4)][int]$ProfileId = 1,
    [ValidateRange(0, 999)][int]$StrategyNumber = 1,
    [ValidatePattern('^(default|mark:[1-9][0-9]{0,4})$')][string]$Scope = 'default',
    [switch]$ListEvents,
    [switch]$FastSearch,
    [switch]$DeepSearch,
    [ValidateRange(1, 100)][int]$DeepSearchMaxCandidates = 20,
    [switch]$Watch,
    [switch]$Explore,
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
    [ValidateRange(0, 128)][int]$EventIndex = 0,
    [ValidateRange(1, 10)][int]$MaxCandidates = 10,
    [ValidateRange(0, 60)][int]$CandidatePauseSeconds = 15,
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

function Invoke-AdaptiveExplorationProbe {
    param(
        [Parameter(Mandatory = $true)]$Event,
        [Parameter(Mandatory = $true)][int]$Strategy,
        [string]$ScriptPath = $PSCommandPath
    )
    $cancelPath = Join-Path ([IO.Path]::GetTempPath()) ('zator-adaptive-explore-cancel-' + [guid]::NewGuid().ToString('N'))
    $job = Start-Job -ArgumentList @(
        $ScriptPath, $Router.AbsoluteUri, $Token, [string]$Event.hostname,
        [string]$Event.destination_ip, [int]$Event.profile_id, [string]$Event.scope,
        [string]$ApiPath, [bool]$UploadStatistics, [string]$StatisticsEndpoint,
        [string]$AdaptiveStatsStatePath, $Strategy, $cancelPath
    ) -ScriptBlock {
        param($ScriptPath, $RouterUri, $PairToken, $HostName, $Destination, $Profile, $ClientScope,
              $EndpointPath, $Upload, $StatsEndpoint, $StatsStatePath, $Candidate, $CancelPath)
        function Invoke-ExploreProbe([int]$Number) {
            if (Test-Path -LiteralPath $CancelPath) { return $null }
            $arguments = @{
                Router = [uri]$RouterUri; Token = $PairToken; Hostname = $HostName
                DestinationIp = $Destination; ProfileId = [int]$Profile
                StrategyNumber = $Number; Scope = $ClientScope; ApiPath = $EndpointPath
            }
            if ($Upload) {
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
        if ($Upload) { $directBefore = Invoke-ExploreProbe 0 }
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
                $urgent = @($queue.events | Where-Object { $_.status -in @('needs_verify', 'suspected_failure') }).Count -gt 0
                if ($urgent) {
                    [IO.File]::WriteAllText($cancelPath, 'urgent')
                    $preempted = $true
                    $cancel = Invoke-AdaptiveApi @{ action = 'cancel_probes' }
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
                if (-not $summary.cancelled -and $UploadStatistics) {
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
                if ($preempted -or $summary.cancelled) { return [pscustomobject]@{ status = 'cancelled' } }
                if ($evidence) { return [pscustomobject]@{ status = 'failure-confirmed' } }
                return [pscustomobject]@{ status = 'complete' }
            } catch {
                [Console]::Error.WriteLine("Adaptive exploration result: $($_.Exception.Message)")
            }
        }
        if ($preempted) { return [pscustomobject]@{ status = 'cancelled' } }
    } finally {
        if ($job.State -eq 'Running') {
            try { Invoke-AdaptiveApi @{ action = 'cancel_probes' } | Out-Null } catch { }
            [void](Wait-Job -Job $job -Timeout 15)
        }
        if ($job.State -in @('Running', 'NotStarted')) { Stop-Job -Job $job -ErrorAction SilentlyContinue }
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $cancelPath -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-AdaptiveStrategyCandidate {
    param([int]$Candidate)
    try {
        $rawResult = & $PSCommandPath -Router $Router -Token $Token -Hostname $Hostname `
            -DestinationIp $DestinationIp -ProfileId $ProfileId -StrategyNumber $Candidate `
            -Scope $Scope -ApiPath $ApiPath -UploadStatistics:$UploadStatistics `
            -StatisticsEndpoint $StatisticsEndpoint -AdaptiveStatsStatePath $AdaptiveStatsStatePath `
            -UseSharedRankings:$UseSharedRankings -AdaptiveRankingEndpoint $AdaptiveRankingEndpoint `
            -AdaptiveRankingCachePath $AdaptiveRankingCachePath | Out-String
        $rawResult.Trim() | ConvertFrom-Json
    } catch {
        [pscustomobject]@{ strategy = $Candidate; overall = 'INCONCLUSIVE'; reason = 'probe_error' }
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
if ($Watch) {
    if ($ListEvents -or $FastSearch -or $DeepSearch -or $EventIndex -gt 0 -or
        -not [string]::IsNullOrWhiteSpace($Hostname) -or -not [string]::IsNullOrWhiteSpace($DestinationIp)) {
        throw '-Watch cannot be combined with a one-shot action or explicit target.'
    }
    $processed = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    if ($Explore) { $exploreState = Read-ExploreState }
    $exploreLoadWarningShown = $false
    Write-Output (if ($Explore) { "Watching with low-priority exploration every $ExploreIntervalSeconds seconds; Ctrl+C stops." } else { "Watching adaptive observations every $WatchIntervalSeconds seconds; Ctrl+C stops." })
    while ($true) {
        try {
            $queue = Invoke-AdaptiveApi @{ action = 'events' }
            if ($queue.schema_version -ne 1 -or $queue.mode -notin @('OFF', 'OBSERVE', 'TEST_ONLY') -or $null -eq $queue.events) {
                throw 'Router returned an invalid observation response.'
            }
            if ($queue.mode -eq 'TEST_ONLY') {
                $exploreInterval = if ($UploadStatistics) { [Math]::Max(240, $ExploreIntervalSeconds) } else { $ExploreIntervalSeconds }
                $exploreDue = -not $Explore -or ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $exploreState.Last -ge ($exploreInterval + $exploreState.Jitter))
                $hasUrgentRequest = @($queue.events | Where-Object { $_.status -in @('needs_verify', 'suspected_failure') }).Count -gt 0
                $hasPassiveTarget = @($queue.events | Where-Object status -eq 'seen').Count -gt 0
                if ($Explore -and $exploreDue -and -not $hasUrgentRequest -and $hasPassiveTarget) {
                    try {
                        $load = Get-ExploreMachineLoad
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
                $next = @($queue.events | Sort-Object @{ Expression = { if ($_.request_id) { 0 } elseif ($_.status -eq 'suspected_failure') { 1 } else { 2 } } }, { [long]$_.observed_at } | Where-Object {
                    $_.protocol -eq 'tls' -and $_.status -in @('seen', 'needs_verify', 'suspected_failure') -and
                    $_.hostname -match '^(?=.{1,253}$)([a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)(\.([a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?))*$' -and
                    $_.destination_ip -match '^([0-9]{1,3}\.){3}[0-9]{1,3}$' -and
                    [int]$_.profile_id -ge 1 -and [int]$_.profile_id -le 4 -and
                    $_.scope -match '^(default|mark:[1-9][0-9]{0,4})$'
                } | Where-Object {
                    -not $Explore -or $_.status -in @('needs_verify', 'suspected_failure') -or $exploreDue
                } | Where-Object {
                    if ($_.request_id -match '^[a-f0-9]{32}$') {
                        $key = 'request|{0}' -f $_.request_id
                    } else {
                        $key = 'event|{0}|{1}|{2}|{3}|{4}' -f $_.hostname, $_.destination_ip, $_.profile_id, $_.scope, $_.observed_at
                    }
                    -not $processed.Contains($key)
                } | Select-Object -First 1)
                if ($next.Count -gt 0) {
                    $event = $next[0]
                    if ($event.request_id -match '^[a-f0-9]{32}$') {
                        $key = 'request|{0}' -f $event.request_id
                        foreach ($observed in $queue.events) {
                            if ($observed.status -in @('seen', 'suspected_failure') -and $observed.hostname -eq $event.hostname -and
                                $observed.destination_ip -eq $event.destination_ip -and $observed.profile_id -eq $event.profile_id -and $observed.scope -eq $event.scope) {
                                [void]$processed.Add(('event|{0}|{1}|{2}|{3}|{4}' -f $observed.hostname, $observed.destination_ip, $observed.profile_id, $observed.scope, $observed.observed_at))
                            }
                        }
                    } else {
                        $key = 'event|{0}|{1}|{2}|{3}|{4}' -f $event.hostname, $event.destination_ip, $event.profile_id, $event.scope, $event.observed_at
                    }
                    if (-not $Explore -or $event.status -ne 'seen') { [void]$processed.Add($key) }
                    if ($processed.Count -gt 512) { $processed.Clear() }
                    Write-Output ("Starting FastSearch for {0} ({1}, profile {2}, {3})." -f $event.hostname, $event.destination_ip, $event.profile_id, $event.scope)
                    try {
                        if ($Explore -and $event.status -eq 'seen') {
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
                            $catalog.profile_strategy_count -notmatch '^[1-9][0-9]{0,2}$' -or
                            $catalog.candidate_count -ne $catalog.profile_strategy_count) { throw 'Invalid exploration catalog response.' }
                            $count = [int]$catalog.profile_strategy_count
                            $offset = if ($null -ne $cursor -and $cursor.Count -eq $count) { $cursor.Offset } else { 0 }
                            if ($offset -ge $count) { $offset = 0 }
                            $candidateRequest.offset = $offset
                            $candidate = Invoke-AdaptiveApi $candidateRequest
                            $numbers = @($candidate.candidate_numbers)
                            if ($candidate.schema_version -ne 1 -or $candidate.status -ne 'ready' -or $candidate.source -ne 'local-profile-order' -or
                                $candidate.candidate_offset -ne $offset -or $candidate.profile_strategy_count -ne $count -or
                                $candidate.candidate_count -ne $count -or $numbers.Count -ne 1 -or
                                $numbers[0] -notmatch '^[1-9][0-9]{0,2}$' -or [int]$numbers[0] -ne ($offset + 1)) { throw 'Invalid exploration candidate response.' }
                            Write-Output ("Exploring strategy {0}/{1} for {2}." -f $numbers[0], $count, $event.hostname)
                            $nextJitter = if ($ExploreJitterSeconds -gt 0) { Get-Random -Minimum 0 -Maximum ($ExploreJitterSeconds + 1) } else { 0 }
                            Save-ExploreState -State $exploreState -TargetKey $targetKey -NextOffset (($offset + 1) % $count) -Count $count -JitterSeconds $nextJitter
                            $exploreState = Read-ExploreState
                            $exploreResult = Invoke-AdaptiveExplorationProbe -Event $event -Strategy ([int]$numbers[0])
                            if ($exploreResult.status -eq 'failure-confirmed') {
                                # The evidence sequence ran four isolated probes; pause long enough to retain the low-priority budget.
                                Save-ExploreState -State $exploreState -TargetKey '' -NextOffset 0 -Count 0 -JitterSeconds 480
                                $exploreState = Read-ExploreState
                            }
                        } else {
                            & $PSCommandPath -Router $Router -Token $Token -Hostname ([string]$event.hostname) `
                                -DestinationIp ([string]$event.destination_ip) -ProfileId ([int]$event.profile_id) `
                                -Scope ([string]$event.scope) -FastSearch -MaxCandidates $MaxCandidates `
                                -CandidatePauseSeconds $CandidatePauseSeconds -ApiPath $ApiPath `
                                -UploadStatistics:$UploadStatistics `
                                -StatisticsEndpoint $StatisticsEndpoint -AdaptiveStatsStatePath $AdaptiveStatsStatePath `
                                -UseSharedRankings:$UseSharedRankings -AdaptiveRankingEndpoint $AdaptiveRankingEndpoint `
                                -AdaptiveRankingCachePath $AdaptiveRankingCachePath
                        }
                    } finally {
                        if ($Explore -and $event.status -in @('needs_verify', 'suspected_failure')) {
                            try {
                                $nextJitter = if ($ExploreJitterSeconds -gt 0) { Get-Random -Minimum 0 -Maximum ($ExploreJitterSeconds + 1) } else { 0 }
                                Save-ExploreState -State $exploreState -TargetKey '' -NextOffset 0 -Count 0 -JitterSeconds $nextJitter
                                $exploreState = Read-ExploreState
                            }
                            catch { [Console]::Error.WriteLine("Adaptive exploration: could not persist priority cooldown: $($_.Exception.Message)") }
                        }
                        if ($event.request_id -match '^[a-f0-9]{32}$') {
                            try { Invoke-AdaptiveApi @{ action = 'ack_request'; request_id = [string]$event.request_id } | Out-Null }
                            catch { [Console]::Error.WriteLine("Adaptive watch: could not acknowledge request: $($_.Exception.Message)") }
                        }
                        if (-not ($Explore -and $event.status -eq 'seen')) {
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

if ($FastSearch) {
    $rankedFingerprints = @(Get-AdaptiveRankingHint -Enabled:$UseSharedRankings -ProfileId $ProfileId `
        -Endpoint $AdaptiveRankingEndpoint -IdentityRequest { Invoke-AdaptiveApi @{ action = 'stats_identity' } })
    $rankedFingerprintCsv = $rankedFingerprints -join ','
    $candidateSet = Invoke-AdaptiveApi @{
        action = 'candidates'; hostname = $Hostname.ToLowerInvariant(); destination_ip = $DestinationIp
        profile_id = $ProfileId; scope = $Scope; ranked_fingerprints = $rankedFingerprintCsv
    }
    if ($candidateSet.schema_version -ne 1 -or $candidateSet.profile_id -ne $ProfileId -or
        $candidateSet.scope -ne $Scope) {
        throw 'Router returned an invalid local candidate response.'
    }
    if ($candidateSet.status -eq 'already_confirmed') {
        if ($candidateSet.strategy_number -notmatch '^[1-9][0-9]{0,2}$' -or
            $candidateSet.strategy_fingerprint -notmatch '^sha256:[0-9a-f]{64}$' -or
            $candidateSet.catalog_version -notmatch '^sha256:[0-9a-f]{64}$' -or
            $candidateSet.expires -le [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) {
            throw 'Router returned an invalid or expired local confirmation.'
        }
        [pscustomobject]@{
            schema_version = 1
            status = 'already_confirmed'
            target = @{ hostname = $Hostname.ToLowerInvariant(); destination_ip = $DestinationIp; profile_id = $ProfileId; scope = $Scope }
            winner_strategy = [int]$candidateSet.strategy_number
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
    if ($candidateSet.status -ne $expectedStatus -or $candidateSet.source -notin @('local-profile-order', 'local-confirmations-first', 'remote-rankings-first') -or
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
    $attempts = [System.Collections.Generic.List[object]]::new()
    $winner = $null
    $winnerKind = $null
    $searchStopped = $false
    $searchStopReason = $null
    $directResult = Invoke-AdaptiveStrategyCandidate -Candidate 0
    $attempts.Add($directResult)
    if ($directResult.overall -eq 'SUCCESS') {
        $winner = 0
        $winnerKind = 'DIRECT'
    } elseif ($directResult.overall -ne 'FAIL' -and $directResult.reason -ne 'http_rejected') {
        $searchStopped = $true
        $searchStopReason = "direct_$($directResult.reason)"
    }
    if ($null -eq $winner -and -not $searchStopped) {
        if ($CandidatePauseSeconds -gt 0) { Start-Sleep -Seconds $CandidatePauseSeconds }
        foreach ($candidate in $candidateNumbers) {
            $probeResult = Invoke-AdaptiveStrategyCandidate -Candidate ([int]$candidate)
            $attempts.Add($probeResult)
            if ($probeResult.overall -eq 'SUCCESS') {
                $winner = [int]$candidate
                $winnerKind = 'STRATEGY'
                break
            }
            if ($probeResult.overall -ne 'FAIL' -and $probeResult.reason -ne 'http_rejected') {
                $searchStopped = $true
                $searchStopReason = "candidate_$($probeResult.reason)"
                break
            }
            if ($candidate -ne $candidateNumbers[-1] -and $CandidatePauseSeconds -gt 0) {
                Start-Sleep -Seconds $CandidatePauseSeconds
            }
        }
    }
    $fastAttemptCount = $attempts.Count - 1
    $fastComplete = -not $searchStopped -and $fastAttemptCount -eq $candidateNumbers.Count
    $deepCount = 0
    $deepOffset = $candidateNumbers.Count
    $searchedCandidates = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($candidate in $candidateNumbers) { [void]$searchedCandidates.Add([int]$candidate) }
    if ($DeepSearch -and $null -eq $winner -and $fastComplete -and $deepOffset -lt $candidateCount) {
        while ($deepCount -lt $DeepSearchMaxCandidates -and $deepOffset -lt $candidateCount) {
            $pageLimit = [Math]::Min(10, $DeepSearchMaxCandidates - $deepCount)
            try {
                $page = Invoke-AdaptiveApi @{
                    action = 'candidates'; hostname = $Hostname.ToLowerInvariant(); destination_ip = $DestinationIp
                    profile_id = $ProfileId; scope = $Scope; offset = $deepOffset; limit = $pageLimit
                    candidate_set_version = $candidateSetVersion; ranked_fingerprints = $rankedFingerprintCsv
                }
            } catch {
                $searchStopped = $true
                $searchStopReason = if ($_.Exception.Message -match 'HTTP 409') { 'candidate_page_conflict' } else { 'candidate_page_request_failed' }
                break
            }
            $pageNumbers = @($page.candidate_numbers)
            $expectedPageCount = [Math]::Min($pageLimit, $candidateCount - $deepOffset)
            if ($page.schema_version -ne 1 -or $page.status -ne 'ready' -or
                $page.source -notin @('local-profile-order', 'local-confirmations-first', 'remote-rankings-first') -or
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
                if ($probeResult.overall -eq 'SUCCESS') {
                    $winner = [int]$candidate
                    $winnerKind = 'STRATEGY'
                    break
                }
                if ($probeResult.overall -ne 'FAIL' -and $probeResult.reason -ne 'http_rejected') {
                    $searchStopped = $true
                    $searchStopReason = "candidate_$($probeResult.reason)"
                    break
                }
                if ($deepCount -lt $DeepSearchMaxCandidates -and $deepOffset -lt $candidateCount -and $CandidatePauseSeconds -gt 0) {
                    Start-Sleep -Seconds $CandidatePauseSeconds
                }
            }
            if ($null -ne $winner -or $searchStopped) { break }
        }
    }
    $finalStatus = if ($winnerKind -eq 'DIRECT') { 'direct' }
        elseif ($null -ne $winner) { 'found' }
        elseif ($searchStopped -or -not $fastComplete) { 'inconclusive' }
        elseif ($candidateNumbers.Count -lt [Math]::Min(10, $candidateCount) -and -not $DeepSearch) { 'limit_reached' }
        elseif ($DeepSearch -and $deepOffset -lt $candidateCount) { 'deep_candidates_exhausted' }
        elseif (-not $DeepSearch -and $fastAttemptCount -lt $candidateCount) { 'fast_candidates_exhausted' }
        else { 'not_found' }
    [pscustomobject]@{
        schema_version = 1
        status = $finalStatus
        search_stop_reason = $searchStopReason
        target = @{ hostname = $Hostname.ToLowerInvariant(); destination_ip = $DestinationIp; profile_id = $ProfileId; scope = $Scope }
        profile_strategy_count = $profileStrategyCount
        unique_candidate_count = $candidateCount
        fast_candidate_count = $fastAttemptCount
        direct_result = $directResult.overall
        deep_candidate_count = $deepCount
        deep_search_limit = if ($DeepSearch) { $DeepSearchMaxCandidates } else { 0 }
        winner_strategy = if ($winnerKind -eq 'STRATEGY') { $winner } else { $null }
        winner_kind = $winnerKind
        attempts = $attempts
    } | ConvertTo-Json -Compress -Depth 8
    return
}

$curl = Get-Command curl.exe -ErrorAction Stop
$sourcePort = Get-AdaptiveAvailableSourcePort
$lease = Invoke-AdaptiveApi @{
    action = 'lease'
    hostname = $Hostname.ToLowerInvariant()
    destination_ip = $DestinationIp
    profile_id = $ProfileId
    scope = $Scope
    local_strategy_number = $StrategyNumber
    source_port = $sourcePort
}
$parsedDestination = $null
$parsedSource = $null
$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
if ($lease.schema_version -ne 1 -or $lease.recipe_id -ne 'tls-http1-v1' -or
    $lease.port -ne 443 -or $lease.expires -lt ($now + 25) -or $lease.expires -gt ($now + 120) -or
    $lease.hostname -ne $Hostname.ToLowerInvariant() -or $lease.destination_ip -ne $DestinationIp -or
    $lease.profile_id -ne $ProfileId -or $lease.scope -ne $Scope -or $lease.local_strategy_number -ne $StrategyNumber -or
    $lease.test_id -notmatch '^[A-Za-z0-9_-]{1,64}$' -or
    $lease.source_port -ne $sourcePort -or $lease.source_port -lt 62000 -or $lease.source_port -gt 62999 -or
    $lease.profile_id -lt 1 -or $lease.profile_id -gt 4 -or
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
        protocol = 'tcp'
        port = 443
        profile_id = [int]$lease.profile_id
        scope = [string]$lease.scope
    }
    strategy = @{
        fingerprint = [string]$lease.strategy_fingerprint
        local_number = [int]$lease.local_strategy_number
        catalog_version = [string]$lease.catalog_version
    }
    recipe_id = 'tls-http1-v1'
    client_profile = 'curl-windows-v1'
}
$responseFile = [IO.Path]::GetTempFileName()
try {
    $writeOut = '%{http_code}' + "`t" + '%{size_download}' + "`t" + '%{remote_ip}'
    $curlArgs = @(
        '--silent', '--show-error', '--noproxy', '*', '--interface', [string]$lease.source_ip,
        '--local-port', [string]$lease.source_port, '--resolve', "$($lease.hostname):443:$($lease.destination_ip)",
        '--http1.1', '--connect-timeout', '8', '--max-time', '25', '--range', '0-65535', '--max-filesize', '65536',
        '--output', $responseFile, '--write-out', $writeOut, "https://$($lease.hostname)/"
    )
    $nativeProbe = Invoke-AdaptiveCurlNative -Executable $curl.Source -Arguments $curlArgs
    $probe = $nativeProbe.Output
    $curlExit = $nativeProbe.ExitCode
    $fields = ([string]$probe).Trim() -split "`t", 3
    $httpCode = 0
    $bytes = 0
    $remoteIp = ''
    if ($fields.Count -eq 3) {
        [void][int]::TryParse($fields[0], [ref]$httpCode)
        [void][long]::TryParse($fields[1], [ref]$bytes)
        $remoteIp = $fields[2]
    }
    if ($remoteIp -ne $lease.destination_ip) {
        $result.reason = 'route_unverified'
    } else {
        $verdict = Get-AdaptiveHttpVerdict -CurlExit $curlExit -HttpCode $httpCode -Bytes $bytes
        $result.transport = $verdict.transport
        $result.application = $verdict.application
        $result.reason = $verdict.reason
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
        client_profile = $result.client_profile
    }
    $completion = Invoke-AdaptiveApi $completionBody
    if ($completion.overall -notin @('SUCCESS', 'FAIL', 'INCONCLUSIVE')) {
        throw 'Router did not return an authoritative adaptive verdict.'
    }
    if ($UploadStatistics) {
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
}
