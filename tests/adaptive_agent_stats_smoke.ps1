$ErrorActionPreference = 'Stop'
$temp = Join-Path $env:TEMP ('zator-adaptive-stats-' + [guid]::NewGuid().ToString('N'))
$AdaptiveStatsStatePath = Join-Path $temp 'adaptive-stats.json'
$AdaptiveRankingCachePath = Join-Path $temp 'rankings.json'
$script:StatsUploadMode = 'fail'
$script:RankingMode = 'fresh'
$script:RankingRequests = 0
$script:IdentityRequests = 0
$script:StatsCapturedBody = ''
$script:StatsCapturedToken = ''
try {
    . (Join-Path $PSScriptRoot '..\tools\adaptive-agent-stats.ps1')
    function Invoke-AdaptiveStatsHttp {
        param([string]$Token, [uri]$Endpoint, [string]$Body)
        $script:StatsCapturedBody = $Body
        $script:StatsCapturedToken = $Token
        if ($script:StatsUploadMode -eq 'fail') { throw 'simulated transport failure' }
        [pscustomobject]@{ ok = $true; accepted = 1 }
    }
    function Invoke-AdaptiveRankingHttp {
        param([uri]$Uri)
        $script:RankingRequests++
        if ($script:RankingMode -eq 'fail') { throw 'simulated ranking transport failure' }
        $query = @{}
        foreach ($part in $Uri.Query.TrimStart('?').Split('&')) {
            $pair = $part.Split('=', 2); if ($pair.Count -eq 2) { $query[[uri]::UnescapeDataString($pair[0])] = [uri]::UnescapeDataString($pair[1]) }
        }
        $recipe = if ($query.recipe) { $query.recipe } else { 'tls-http1-v1' }
        $treatment = if ($query.treatment) { $query.treatment } else { 'standard' }
        $protocol = switch ($recipe) { 'tls-http1-v1' { 'tls' }; 'googlevideo-tcp-media-v1' { 'tcp-media' }; 'googlevideo-quic-h3-media-v1' { 'quic' } }
        [pscustomobject]@{
            schema_version = 2; status = 'fresh'; provider = 'Example ISP'; profile_id = [int]$query.profile; protocol = $protocol
            recipe_id = $recipe; treatment_variant = $treatment
            generated_at = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            rankings = @(
                [pscustomobject]@{ fingerprint = 'sha256:' + ('c' * 64); score = 0.9; samples = 20 },
                [pscustomobject]@{ fingerprint = 'sha256:' + ('d' * 64); score = 0.8; samples = 12 }
            )
        }
    }
    $identityRequest = {
        $script:IdentityRequests++
        [pscustomobject]@{ schema_version = 1; provider = 'Example ISP' }
    }
    $disabledRanking = @(Get-AdaptiveRankingHint -Enabled:$false -ProfileId 1 `
        -Endpoint ([uri]'https://stats.example/rankings') -IdentityRequest $identityRequest)
    if ($disabledRanking.Count -ne 0 -or $script:IdentityRequests -ne 0 -or $script:RankingRequests -ne 0) {
        throw 'Shared ranking opt-in did not prevent provider lookup and remote ranking requests.'
    }
    $enabledRanking = @(Get-AdaptiveRankingHint -Enabled:$true -ProfileId 1 `
        -Endpoint ([uri]'https://stats.example/rankings') -IdentityRequest $identityRequest)
    if ($enabledRanking.Count -ne 2 -or $script:IdentityRequests -ne 1 -or $script:RankingRequests -ne 1) {
        throw 'Explicit shared-ranking opt-in did not fetch and return the bounded rankings.'
    }
    $quicRanking = @(Get-AdaptiveRankingHint -Enabled:$true -ProfileId 5 -RecipeId 'googlevideo-quic-h3-media-v1' `
        -Endpoint ([uri]'https://stats.example/rankings') -IdentityRequest $identityRequest)
    if ($quicRanking.Count -ne 2 -or $script:RankingRequests -ne 2) {
        throw 'QUIC recipe ranking was not fetched in its independent dimension.'
    }
    $ranking = Get-AdaptiveRankedFingerprints -Provider 'Example ISP' -ProfileId 1 -Endpoint ([uri]'https://stats.example/rankings')
    if ($ranking.status -ne 'fresh' -or $ranking.fingerprints.Count -ne 2 -or
        $ranking.fingerprints[0] -ne ('sha256:' + ('c' * 64)) -or $script:RankingRequests -ne 2) {
        throw 'Fresh remote ranking response was not cached and validated.'
    }
    $cachedRanking = Get-AdaptiveRankedFingerprints -Provider 'Example ISP' -ProfileId 1 -Endpoint ([uri]'https://stats.example/rankings')
    if ($cachedRanking.fingerprints.Count -ne 2 -or $script:RankingRequests -ne 2) { throw 'Fresh ranking cache did not suppress a repeated request.' }
    $rankingCacheText = Get-Content -LiteralPath $AdaptiveRankingCachePath -Raw
    foreach ($privateValue in @('hostname', 'destination_ip', 'test_id', '203.0.113.')) {
        if ($rankingCacheText.Contains($privateValue)) { throw "Private target data leaked into ranking cache: $privateValue" }
    }
    $script:RankingMode = 'fail'
    $cache = Read-AdaptiveRankingCache
    $cache.Entries[0].expires = '1'
    Save-AdaptiveRankingCache $cache
    $staleRanking = Get-AdaptiveRankedFingerprints -Provider 'Example ISP' -ProfileId 1 -Endpoint ([uri]'https://stats.example/rankings')
    if ($staleRanking.status -ne 'stale-cache' -or $staleRanking.fingerprints.Count -ne 2 -or $script:RankingRequests -ne 3) {
        throw 'Ranking transport failure did not use the bounded stale cache.'
    }
    $state = Read-AdaptiveStatsState
    $result = [pscustomobject]@{
        overall = 'SUCCESS'; route_verified = $true; transport = 'OK'; application = 'OK'
        recipe_id = 'tls-http1-v1'; client_profile = 'curl-windows-v1'; treatment_variant = 'standard'
        target = @{ hostname = 'private.example'; destination_ip = '203.0.113.9'; profile_id = 1; protocol = 'tcp'; port = 443; scope = 'mark:17' }
        strategy = @{ local_number = 0; fingerprint = 'sha256:' + ('a' * 64) }
        test_id = 'private-test-id'; url = 'https://private.example/path?token=secret'
    }
    if (Add-AdaptiveStatsResult -State $state -Result $result -Provider 'Example ISP') { throw 'Invalid direct test result was queued.' }
    $result.overall = 'INCONCLUSIVE'; $result.strategy.local_number = 7
    if (Add-AdaptiveStatsResult -State $state -Result $result -Provider 'Example ISP') { throw 'Inconclusive result was queued.' }
    $result.overall = 'SUCCESS'; $result.route_verified = $false
    if (Add-AdaptiveStatsResult -State $state -Result $result -Provider 'Example ISP') { throw 'Unverified route was queued.' }
    $result.route_verified = $true
    if (-not (Add-AdaptiveStatsResult -State $state -Result $result -Provider 'Example ISP')) { throw 'Verified exact success was not queued.' }
    $mediaState = @{ Path = (Join-Path $temp 'media-stats.json'); Pending = [System.Collections.Generic.List[object]]::new(); Inflight = $null; Due = 0 }
    $mediaResult = [pscustomobject]@{
        overall = 'SUCCESS'; route_verified = $true; transport = 'OK'; application = 'OK'
        recipe_id = 'googlevideo-quic-h3-media-v1'; client_profile = 'curl-windows-quic-media-v1'; treatment_variant = 'standard'
        media_bytes = 1048576; media_speed_bps = 1500000; media_duration_ms = 700
        target = @{ hostname = 'rr2---sn-test.googlevideo.com'; destination_ip = '142.251.1.2'; profile_id = 5; protocol = 'udp'; port = 443; scope = 'default' }
        strategy = @{ local_number = 18; fingerprint = 'sha256:' + ('e' * 64) }
    }
    if (-not (Add-AdaptiveStatsResult -State $mediaState -Result $mediaResult -Provider 'Example ISP')) {
        throw 'Route-verified HTTP/3 media success was not queued.'
    }
    $badMedia = $mediaResult.PSObject.Copy(); $badMedia.media_bytes = 0
    if (Add-AdaptiveStatsResult -State $mediaState -Result $badMedia -Provider 'Example ISP') {
        throw 'QUIC media result without transferred bytes was queued.'
    }
    $directControl = [pscustomobject]@{
        overall = 'SUCCESS'; route_verified = $true; transport = 'OK'; application = 'OK'
        recipe_id = 'tls-http1-v1'; client_profile = 'curl-windows-v1'
        target = $result.target; strategy = @{ local_number = 0; fingerprint = 'sha256:' + ('0' * 64) }
    }
    $failedCandidate = [pscustomobject]@{
        overall = 'INCONCLUSIVE'; route_verified = $true; transport = 'UNKNOWN'; application = 'UNKNOWN'; reason = 'timeout'
        recipe_id = 'tls-http1-v1'; client_profile = 'curl-windows-v1'
        target = $result.target; strategy = @{ local_number = 7; fingerprint = 'sha256:' + ('a' * 64) }
    }
    $evidence = Test-AdaptiveFailureEvidence -DirectBefore $directControl -CandidateResults @($failedCandidate, $failedCandidate) -DirectAfter $directControl
    if (-not $evidence -or $evidence.overall -ne 'FAIL' -or $evidence.failure_confirmations -ne 2 -or
        $evidence.transport -ne 'FAIL' -or $evidence.application -ne 'UNKNOWN') {
        throw 'Two identical route-verified timeouts between successful DIRECT controls were not recognized.'
    }
    $rejectedCandidate = [pscustomobject]@{
        overall = 'INCONCLUSIVE'; route_verified = $true; transport = 'OK'; application = 'UNKNOWN'; reason = 'http_rejected'
        recipe_id = 'tls-http1-v1'; client_profile = 'curl-windows-v1'
        target = $result.target; strategy = @{ local_number = 7; fingerprint = 'sha256:' + ('a' * 64) }
    }
    $httpEvidence = Test-AdaptiveFailureEvidence -DirectBefore $directControl `
        -CandidateResults @($rejectedCandidate, $rejectedCandidate) -DirectAfter $directControl
    if (-not $httpEvidence -or $httpEvidence.transport -ne 'OK' -or $httpEvidence.application -ne 'FAIL') {
        throw 'Two repeated HTTP rejections between successful DIRECT controls were not classified as application failure.'
    }
    $failedCandidate.route_verified = $false
    if (Test-AdaptiveFailureEvidence -DirectBefore $directControl -CandidateResults @($failedCandidate, $failedCandidate) -DirectAfter $directControl) {
        throw 'Unverified repeated failures were accepted.'
    }
    $failedCandidate.route_verified = $true
    $failedCandidate.reason = 'rate_limited'
    if (Test-AdaptiveFailureEvidence -DirectBefore $directControl -CandidateResults @($failedCandidate, $failedCandidate) -DirectAfter $directControl) {
        throw 'Rate limiting was incorrectly promoted to a strategy failure.'
    }
    $failedCandidate.reason = 'timeout'
    $badControl = [pscustomobject]@{ overall = 'INCONCLUSIVE'; route_verified = $true; transport = 'UNKNOWN'; application = 'UNKNOWN'; target = $result.target; strategy = $directControl.strategy }
    if (Test-AdaptiveFailureEvidence -DirectBefore $directControl -CandidateResults @($failedCandidate, $failedCandidate) -DirectAfter $badControl) {
        throw 'A failed trailing DIRECT control was accepted.'
    }
    if (-not (Add-AdaptiveStatsResult -State $state -Result $evidence -Provider 'Example ISP')) {
        throw 'Verified repeated strategy failure was not queued.'
    }
    $stored = Get-Content -LiteralPath $AdaptiveStatsStatePath -Raw
    foreach ($privateValue in @('private.example', '203.0.113.9', 'private-test-id', 'secret', 'mark:17')) {
        if ($stored.Contains($privateValue)) { throw "Private probe detail leaked into statistics spool: $privateValue" }
    }
    $loaded = Read-AdaptiveStatsState
    if ($loaded.Pending.Count -ne 1 -or $loaded.Pending[0].fingerprint -ne $evidence.strategy.fingerprint -or
        $loaded.Pending[0].verdict -ne 'FAIL' -or $loaded.Pending[0].failure_confirmations -ne 2 -or
        $loaded.Due -lt ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 899) -or
        $loaded.Due -gt ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 1801)) { throw 'Statistics spool contents or jitter are invalid.' }
    $loaded.Due = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    Save-AdaptiveStatsState $loaded
    try { Invoke-AdaptiveStatsUpload -State $loaded -Token 'individual-client-token' -Endpoint ([uri]'https://stats.example/results') | Out-Null }
    catch { }
    $retry = Read-AdaptiveStatsState
    $requestId = $retry.Inflight.request_id
    $retryBody = [string]$retry.Inflight.body
    if ($retry.Pending.Count -ne 1 -or $requestId -notmatch '^[a-f0-9]{32}$' -or $script:StatsCapturedToken -ne 'individual-client-token' -or
        $retry.Due -lt ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 899) -or
        $retry.Due -gt ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 1801)) {
        throw 'Failed upload did not persist a retryable idempotent request.'
    }
    $retry.Due = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    Save-AdaptiveStatsState $retry
    $script:StatsUploadMode = 'success'
    if (-not (Invoke-AdaptiveStatsUpload -State $retry -Token 'individual-client-token' -Endpoint ([uri]'https://stats.example/results'))) {
        throw 'Successful statistics upload was not acknowledged.'
    }
    $body = $script:StatsCapturedBody | ConvertFrom-Json
    $final = Read-AdaptiveStatsState
    if ($script:StatsCapturedBody -ne $retryBody -or $body.request_id -ne $requestId -or
        $null -ne $body.source_id -or $body.results[0].verdict -ne 'FAIL' -or $body.results[0].failure_confirmations -ne 2 -or
        $final.Pending.Count -ne 0 -or $final.Inflight) {
        throw 'Upload retry changed its payload or failed to clear acknowledged data.'
    }
    $mediaState.Due = 0
    $script:StatsUploadMode = 'success'
    if (-not (Invoke-AdaptiveStatsUpload -State $mediaState -Token 'individual-client-token' -Endpoint ([uri]'https://stats.example/results'))) {
        throw 'Media statistics batch was not acknowledged.'
    }
    $mediaBody = $script:StatsCapturedBody | ConvertFrom-Json
    if ($mediaBody.recipe_id -ne 'googlevideo-quic-h3-media-v1' -or $mediaBody.client_profile -ne 'curl-windows-quic-media-v1' -or
        $mediaBody.results[0].protocol -ne 'quic' -or $mediaBody.results[0].profile_id -ne 5) {
        throw 'QUIC media upload lost its protocol-specific dimensions.'
    }
    Write-Output 'adaptive agent statistics smoke: ok'
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
