function Get-AdaptiveStatsStatePath {
    if (-not [string]::IsNullOrWhiteSpace($AdaptiveStatsStatePath)) { return $AdaptiveStatsStatePath }
    $base = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { [Environment]::GetFolderPath('LocalApplicationData') }
    Join-Path $base 'Zator\adaptive-stats-v2.json'
}

function Read-AdaptiveStatsState {
    $path = Get-AdaptiveStatsStatePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return @{ Path = $path; Pending = [System.Collections.Generic.List[object]]::new(); Inflight = $null; Due = 0 }
    }
    try { $saved = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -ErrorAction Stop }
    catch { throw 'Adaptive statistics spool is invalid; preserve it and inspect before retrying.' }
    if ($saved.schema_version -ne 2 -or $null -eq $saved.pending -or $saved.pending.Count -gt 50) {
        throw 'Adaptive statistics spool has an unsupported format.'
    }
    $pending = [System.Collections.Generic.List[object]]::new()
    foreach ($row in $saved.pending) {
        if (-not $row.PSObject.Properties['recipe_id']) { $row | Add-Member -NotePropertyName recipe_id -NotePropertyValue 'tls-http1-v1' }
        if (-not $row.PSObject.Properties['client_profile']) { $row | Add-Member -NotePropertyName client_profile -NotePropertyValue 'curl-windows-v1' }
        if (-not $row.PSObject.Properties['treatment_variant']) { $row | Add-Member -NotePropertyName treatment_variant -NotePropertyValue 'standard' }
        foreach ($metric in @('media_bytes', 'media_speed_bps', 'media_duration_ms')) {
            if (-not $row.PSObject.Properties[$metric]) { $row | Add-Member -NotePropertyName $metric -NotePropertyValue 0 }
        }
        $success = $row.verdict -eq 'SUCCESS' -and $row.route_verified -eq $true -and
            $row.transport -eq 'OK' -and $row.application -eq 'OK' -and $row.failure_confirmations -eq 0
        $failure = $row.verdict -eq 'FAIL' -and $row.route_verified -eq $true -and
            ($row.transport -eq 'FAIL' -or $row.application -eq 'FAIL') -and
            $row.failure_confirmations -in @(2, 3, 4, 5)
        $recipeOk = ($row.recipe_id -eq 'tls-http1-v1' -and $row.client_profile -eq 'curl-windows-v1' -and
            $row.profile_id -in @(1, 2, 3, 4) -and $row.protocol -eq 'tls' -and $row.treatment_variant -eq 'standard') -or
            ($row.recipe_id -eq 'googlevideo-tcp-media-v1' -and $row.client_profile -eq 'curl-windows-media-v1' -and
            $row.profile_id -eq 2 -and $row.protocol -eq 'tcp-media' -and
            $row.treatment_variant -in @('standard', 'gv_tcp_plain', 'gv_tcp_ramp', 'gv_tcp_ramp_syndata')) -or
            ($row.recipe_id -eq 'googlevideo-quic-h3-media-v1' -and $row.client_profile -eq 'curl-windows-quic-media-v1' -and
            $row.profile_id -eq 5 -and $row.protocol -eq 'quic' -and $row.treatment_variant -eq 'standard')
        if ($row.provider -isnot [string] -or [string]::IsNullOrWhiteSpace($row.provider) -or
            -not $recipeOk -or
            $row.fingerprint -notmatch '^sha256:[a-f0-9]{64}$' -or (-not $success -and -not $failure)) {
            throw 'Adaptive statistics spool contains an invalid row.'
        }
        $pending.Add($row)
    }
    $inflight = $null
    if ($saved.inflight) {
        if ($saved.inflight.request_id -notmatch '^[a-f0-9]{32}$' -or
            $saved.inflight.body -isnot [string] -or $saved.inflight.body.Length -gt 32768 -or
            $saved.inflight.row_keys.Count -gt 50) { throw 'Adaptive statistics spool contains an invalid in-flight batch.' }
        $inflight = $saved.inflight
    }
    @{ Path = $path; Pending = $pending; Inflight = $inflight; Due = [long]$saved.due }
}

function Save-AdaptiveStatsState {
    param([hashtable]$State)
    $directory = Split-Path -Parent $State.Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $document = [ordered]@{
        schema_version = 2
        due = [long]$State.Due
        pending = @($State.Pending.ToArray())
        inflight = $State.Inflight
    }
    $temporary = "$($State.Path).$PID.tmp"
    [IO.File]::WriteAllText($temporary, ($document | ConvertTo-Json -Depth 6 -Compress), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $State.Path -Force
}

function Test-AdaptiveFailureEvidence {
    param([object]$DirectBefore, [object[]]$CandidateResults, [object]$DirectAfter)
    if ($CandidateResults.Count -lt 2 -or $CandidateResults.Count -gt 5) { return $null }
    $first = $CandidateResults[0]
    $target = $first.target
    $fingerprint = [string]$first.strategy.fingerprint
    $strategyNumber = [int]$first.strategy.local_number
    $reason = [string]$first.reason
    if ($reason -notin @('timeout', 'http_rejected') -or $strategyNumber -lt 1 -or
        $fingerprint -notmatch '^sha256:[a-f0-9]{64}$') { return $null }
    $sameTarget = {
        param($Result)
        $Result.recipe_id -eq 'tls-http1-v1' -and $Result.client_profile -eq 'curl-windows-v1' -and
            $Result.target.hostname -eq $target.hostname -and $Result.target.destination_ip -eq $target.destination_ip -and
            $Result.target.profile_id -eq $target.profile_id -and $Result.target.protocol -eq 'tcp' -and
            $Result.target.port -eq 443 -and $Result.target.scope -eq $target.scope
    }
    foreach ($control in @($DirectBefore, $DirectAfter)) {
        if (-not $control -or $control.overall -ne 'SUCCESS' -or $control.route_verified -ne $true -or
            $control.transport -ne 'OK' -or $control.application -ne 'OK' -or
            $control.strategy.local_number -ne 0 -or -not (& $sameTarget $control)) { return $null }
    }
    foreach ($candidate in $CandidateResults) {
        if ($candidate.overall -ne 'INCONCLUSIVE' -or $candidate.route_verified -ne $true -or
            $candidate.reason -ne $reason -or $candidate.strategy.local_number -ne $strategyNumber -or
            $candidate.strategy.fingerprint -ne $fingerprint -or -not (& $sameTarget $candidate)) { return $null }
        if ($reason -eq 'timeout' -and ($candidate.transport -ne 'UNKNOWN' -or $candidate.application -ne 'UNKNOWN')) { return $null }
        if ($reason -eq 'http_rejected' -and ($candidate.transport -ne 'OK' -or $candidate.application -ne 'UNKNOWN')) { return $null }
    }
    [pscustomobject]@{
        overall = 'FAIL'
        route_verified = $true
        transport = if ($reason -eq 'timeout') { 'FAIL' } else { 'OK' }
        application = if ($reason -eq 'http_rejected') { 'FAIL' } else { 'UNKNOWN' }
        failure_confirmations = $CandidateResults.Count
        failure_evidence_verified = $true
        recipe_id = 'tls-http1-v1'
        client_profile = 'curl-windows-v1'
        treatment_variant = 'standard'
        target = $target
        strategy = $first.strategy
    }
}

function Add-AdaptiveStatsResult {
    param([hashtable]$State, [object]$Result, [string]$Provider)
    $recipe = [string]$Result.recipe_id
    $media = $recipe -in @('googlevideo-tcp-media-v1', 'googlevideo-quic-h3-media-v1')
    $expectedProtocol = switch ($recipe) {
        'tls-http1-v1' { 'tcp' }
        'googlevideo-tcp-media-v1' { 'tcp' }
        'googlevideo-quic-h3-media-v1' { 'udp' }
        default { '' }
    }
    $expectedClient = switch ($recipe) {
        'tls-http1-v1' { 'curl-windows-v1' }
        'googlevideo-tcp-media-v1' { 'curl-windows-media-v1' }
        'googlevideo-quic-h3-media-v1' { 'curl-windows-quic-media-v1' }
        default { '' }
    }
    $treatment = if ($Result.treatment_variant) { [string]$Result.treatment_variant } else { 'standard' }
    $mediaShape = if ($recipe -eq 'googlevideo-tcp-media-v1') {
        $Result.target.profile_id -eq 2 -and $Result.target.protocol -eq 'tcp' -and
            $Result.target.hostname -match '(?i)^(?:[a-z0-9-]+\.)+googlevideo\.com$' -and
            $treatment -in @('standard', 'gv_tcp_plain', 'gv_tcp_ramp', 'gv_tcp_ramp_syndata')
    } elseif ($recipe -eq 'googlevideo-quic-h3-media-v1') {
        $Result.target.profile_id -eq 5 -and $Result.target.protocol -eq 'udp' -and
            $Result.target.hostname -match '(?i)^(?:[a-z0-9-]+\.)+googlevideo\.com$' -and $treatment -eq 'standard'
    } else { $false }
    $commonValid = $Result.route_verified -eq $true -and
        (($recipe -eq 'tls-http1-v1' -and $Result.target.profile_id -in @(1, 2, 3, 4) -and
            $Result.target.protocol -eq 'tcp' -and $treatment -eq 'standard') -or $mediaShape) -and
        $Result.target.port -eq 443 -and $Result.client_profile -eq $expectedClient -and
        $Result.strategy.local_number -ge 1 -and $Result.strategy.fingerprint -match '^sha256:[a-f0-9]{64}$'
    if ($media) {
        $commonValid = $commonValid -and $Result.media_bytes -ge 65536 -and $Result.media_duration_ms -gt 0 -and
            $Result.media_speed_bps -gt 0
    }
    $success = $Result.overall -eq 'SUCCESS' -and $commonValid -and $Result.transport -eq 'OK' -and
        $Result.application -eq 'OK'
    $failure = -not $media -and $Result.overall -eq 'FAIL' -and $commonValid -and $Result.failure_evidence_verified -eq $true -and
        $Result.failure_confirmations -in @(2, 3, 4, 5) -and
        ($Result.transport -eq 'FAIL' -or $Result.application -eq 'FAIL')
    if ([string]::IsNullOrWhiteSpace($Provider) -or $Provider.Length -gt 120 -or (-not $success -and -not $failure)) { return $false }
    $fingerprint = [string]$Result.strategy.fingerprint
    $profile = [int]$Result.target.profile_id
    $protocol = if ($recipe -eq 'tls-http1-v1') { 'tls' } elseif ($recipe -eq 'googlevideo-quic-h3-media-v1') { 'quic' } else { 'tcp-media' }
    $clientProfile = $expectedClient
    $key = "$Provider|$profile|$protocol|$recipe|$treatment|$fingerprint"
    for ($i = $State.Pending.Count - 1; $i -ge 0; $i--) {
        $rowKey = "$($State.Pending[$i].provider)|$($State.Pending[$i].profile_id)|$($State.Pending[$i].protocol)|$($State.Pending[$i].recipe_id)|$($State.Pending[$i].treatment_variant)|$($State.Pending[$i].fingerprint)"
        if ($rowKey -eq $key) { $State.Pending.RemoveAt($i) }
    }
    $State.Pending.Add([pscustomobject]@{
        provider = $Provider
        profile_id = $profile
        protocol = $protocol
        recipe_id = $recipe
        treatment_variant = $treatment
        client_profile = $clientProfile
        fingerprint = $fingerprint
        verdict = $Result.overall
        route_verified = $true
        transport = [string]$Result.transport
        application = [string]$Result.application
        failure_confirmations = if ($success) { 0 } else { [int]$Result.failure_confirmations }
        media_bytes = if ($media) { [long]$Result.media_bytes } else { 0 }
        media_speed_bps = if ($media) { [long]$Result.media_speed_bps } else { 0 }
        media_duration_ms = if ($media) { [long]$Result.media_duration_ms } else { 0 }
    })
    while ($State.Pending.Count -gt 50) { $State.Pending.RemoveAt(0) }
    if ($State.Due -le 0) { $State.Due = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + (Get-Random -Minimum 900 -Maximum 1801) }
    Save-AdaptiveStatsState $State
    $true
}

function Invoke-AdaptiveStatsHttp {
    param([string]$Token, [uri]$Endpoint, [string]$Body)
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $http = [System.Net.Http.HttpClient]::new($handler)
    $http.Timeout = [TimeSpan]::FromSeconds(15)
    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, $Endpoint)
    $request.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $Token)
    $request.Content = [System.Net.Http.StringContent]::new($Body, [Text.Encoding]::UTF8, 'application/json')
    $response = $null
    try {
        $response = $http.SendAsync($request).GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) { throw "Adaptive statistics server returned HTTP $([int]$response.StatusCode)." }
        $receipt = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
        if ($receipt.ok -ne $true -or $receipt.accepted -lt 0) { throw 'Adaptive statistics server returned an invalid receipt.' }
        $receipt
    } finally {
        $request.Dispose(); $http.Dispose(); $handler.Dispose()
        if ($response) { $response.Dispose() }
    }
}

function Invoke-AdaptiveStatsUpload {
    param([hashtable]$State, [string]$Token, [uri]$Endpoint)
    if ($Endpoint.Scheme -ne 'https') { throw 'Adaptive statistics endpoint must use HTTPS.' }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if ($State.Due -gt $now) { return $false }
    if (-not $State.Inflight) {
        if ($State.Pending.Count -eq 0) { return $false }
        $first = $State.Pending[0]
        $rows = @($State.Pending | Where-Object {
            $_.provider -eq $first.provider -and $_.recipe_id -eq $first.recipe_id -and
                $_.treatment_variant -eq $first.treatment_variant -and $_.client_profile -eq $first.client_profile
        } | Select-Object -First 12)
        $requestId = [guid]::NewGuid().ToString('N')
        $body = [ordered]@{
            schema_version = 2
            request_id = $requestId
            provider = [string]$first.provider
            observed_at = $now
            recipe_id = [string]$first.recipe_id
            client_profile = [string]$first.client_profile
            results = @($rows | ForEach-Object {
                [ordered]@{ profile_id = $_.profile_id; protocol = $_.protocol; fingerprint = $_.fingerprint
                    treatment_variant = $_.treatment_variant
                    verdict = $_.verdict; route_verified = $_.route_verified; transport = $_.transport
                    application = $_.application; failure_confirmations = $_.failure_confirmations
                    media_bytes = $_.media_bytes; media_speed_bps = $_.media_speed_bps
                    media_duration_ms = $_.media_duration_ms }
            })
        }
        $json = $body | ConvertTo-Json -Depth 8 -Compress
        if ([Text.Encoding]::UTF8.GetByteCount($json) -gt 32768) { throw 'Adaptive statistics batch exceeds 32 KiB.' }
        $keys = @($rows | ForEach-Object { "$($_.provider)|$($_.profile_id)|$($_.protocol)|$($_.recipe_id)|$($_.treatment_variant)|$($_.fingerprint)" })
        $State.Inflight = [pscustomobject]@{ request_id = $requestId; body = $json; row_keys = $keys }
        Save-AdaptiveStatsState $State
    }
    try { $receipt = Invoke-AdaptiveStatsHttp -Token $Token -Endpoint $Endpoint -Body $State.Inflight.body }
    catch {
        $State.Due = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + (Get-Random -Minimum 900 -Maximum 1801)
        Save-AdaptiveStatsState $State
        throw
    }
    $keys = @($State.Inflight.row_keys)
    for ($i = $State.Pending.Count - 1; $i -ge 0; $i--) {
        $row = $State.Pending[$i]
        $rowKey = "$($row.provider)|$($row.profile_id)|$($row.protocol)|$($row.recipe_id)|$($row.treatment_variant)|$($row.fingerprint)"
        if ($keys -contains $rowKey) { $State.Pending.RemoveAt($i) }
    }
    $State.Inflight = $null
    $State.Due = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + (Get-Random -Minimum 900 -Maximum 1801)
    Save-AdaptiveStatsState $State
    return $true
}

function Get-AdaptiveRankingCachePath {
    if (-not [string]::IsNullOrWhiteSpace($AdaptiveRankingCachePath)) { return $AdaptiveRankingCachePath }
    $base = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { [Environment]::GetFolderPath('LocalApplicationData') }
    Join-Path $base 'Zator\adaptive-rankings-v2.json'
}

function Read-AdaptiveRankingCache {
    $path = Get-AdaptiveRankingCachePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return @{ Path = $path; Entries = [System.Collections.Generic.List[object]]::new() }
    }
    try { $saved = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -ErrorAction Stop }
    catch { throw 'Adaptive ranking cache is invalid.' }
    if ($saved.schema_version -ne 1 -or $null -eq $saved.entries -or $saved.entries.Count -gt 32) {
        throw 'Adaptive ranking cache has an unsupported format.'
    }
    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in $saved.entries) {
        if (-not $entry.PSObject.Properties['recipe_id']) { $entry | Add-Member -NotePropertyName recipe_id -NotePropertyValue 'tls-http1-v1' }
        if (-not $entry.PSObject.Properties['protocol']) { $entry | Add-Member -NotePropertyName protocol -NotePropertyValue 'tls' }
        if (-not $entry.PSObject.Properties['treatment_variant']) { $entry | Add-Member -NotePropertyName treatment_variant -NotePropertyValue 'standard' }
        $entryDimensionOk = ($entry.recipe_id -eq 'tls-http1-v1' -and $entry.treatment_variant -eq 'standard' -and $entry.protocol -eq 'tls' -and $entry.profile_id -in @(1, 2, 3, 4)) -or
            ($entry.recipe_id -eq 'googlevideo-tcp-media-v1' -and $entry.protocol -eq 'tcp-media' -and $entry.profile_id -eq 2) -or
            ($entry.recipe_id -eq 'googlevideo-quic-h3-media-v1' -and $entry.protocol -eq 'quic' -and $entry.profile_id -eq 5)
        if ($entry.provider -isnot [string] -or [string]::IsNullOrWhiteSpace($entry.provider) -or
            -not $entryDimensionOk -or $entry.treatment_variant -notin @('standard', 'gv_tcp_plain', 'gv_tcp_ramp', 'gv_tcp_ramp_syndata') -or
            $entry.expires -notmatch '^[0-9]{1,12}$' -or
            $entry.status -notin @('fresh', 'stale', 'not_ready', 'stale-cache') -or
            $entry.fingerprints.Count -gt 10 -or
            @($entry.fingerprints | Where-Object { $_ -notmatch '^sha256:[a-f0-9]{64}$' }).Count -gt 0 -or
            @($entry.fingerprints | Select-Object -Unique).Count -ne $entry.fingerprints.Count) {
            throw 'Adaptive ranking cache contains an invalid entry.'
        }
        $entries.Add($entry)
    }
    @{ Path = $path; Entries = $entries }
}

function Save-AdaptiveRankingCache {
    param([hashtable]$Cache)
    $directory = Split-Path -Parent $Cache.Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $document = [ordered]@{ schema_version = 1; entries = @($Cache.Entries.ToArray()) }
    $temporary = "$($Cache.Path).$PID.tmp"
    [IO.File]::WriteAllText($temporary, ($document | ConvertTo-Json -Depth 6 -Compress), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $Cache.Path -Force
}

function Invoke-AdaptiveRankingHttp {
    param([uri]$Uri)
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $http = [System.Net.Http.HttpClient]::new($handler)
    $http.Timeout = [TimeSpan]::FromSeconds(8)
    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $Uri)
    $response = $null
    try {
        $response = $http.SendAsync($request).GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) { throw "Adaptive ranking server returned HTTP $([int]$response.StatusCode)." }
        $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
    } finally {
        $request.Dispose(); $http.Dispose(); $handler.Dispose()
        if ($response) { $response.Dispose() }
    }
}

function Get-AdaptiveRankedFingerprints {
    param([string]$Provider, [int]$ProfileId, [uri]$Endpoint,
          [ValidateSet('tls-http1-v1', 'googlevideo-tcp-media-v1', 'googlevideo-quic-h3-media-v1')][string]$RecipeId = 'tls-http1-v1',
          [ValidateSet('standard', 'gv_tcp_plain', 'gv_tcp_ramp', 'gv_tcp_ramp_syndata')][string]$TreatmentVariant = 'standard')
    $expectedProfile = switch ($RecipeId) { 'tls-http1-v1' { $ProfileId -in @(1, 2, 3, 4) -and $TreatmentVariant -eq 'standard' }; 'googlevideo-tcp-media-v1' { $ProfileId -eq 2 }; 'googlevideo-quic-h3-media-v1' { $ProfileId -eq 5 -and $TreatmentVariant -eq 'standard' } }
    if ([string]::IsNullOrWhiteSpace($Provider) -or $Provider.Length -gt 120 -or
        -not $expectedProfile -or $Endpoint.Scheme -ne 'https') {
        throw 'Invalid adaptive ranking request.'
    }
    $cache = Read-AdaptiveRankingCache
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $protocol = switch ($RecipeId) { 'tls-http1-v1' { 'tls' }; 'googlevideo-tcp-media-v1' { 'tcp-media' }; 'googlevideo-quic-h3-media-v1' { 'quic' } }
    $entry = @($cache.Entries | Where-Object { $_.provider -eq $Provider -and $_.profile_id -eq $ProfileId -and $_.recipe_id -eq $RecipeId -and $_.treatment_variant -eq $TreatmentVariant } | Select-Object -First 1)
    if ($entry.Count -gt 0 -and [long]$entry[0].expires -gt $now) { return $entry[0] }
    $url = [UriBuilder]$Endpoint
    $url.Query = 'provider=' + [uri]::EscapeDataString($Provider) + '&profile=' + $ProfileId + '&protocol=' + $protocol +
        '&recipe=' + [uri]::EscapeDataString($RecipeId) + '&treatment=' + [uri]::EscapeDataString($TreatmentVariant)
    try {
        $document = Invoke-AdaptiveRankingHttp -Uri $url.Uri
        if ($document.schema_version -ne 2 -or $document.status -notin @('fresh', 'stale', 'not_ready') -or
            $document.provider -ne $Provider -or $document.profile_id -ne $ProfileId -or $document.protocol -ne $protocol -or
            $document.recipe_id -ne $RecipeId -or $document.treatment_variant -ne $TreatmentVariant) {
            throw 'Adaptive ranking server returned an invalid document.'
        }
        $fingerprints = @()
        if ($document.status -ne 'not_ready') {
            $generatedAt = [long]$document.generated_at
            if ($generatedAt -lt $now - 86400 -or $generatedAt -gt $now + 300 -or $document.rankings.Count -gt 20) {
                throw 'Adaptive ranking server returned stale or oversized data.'
            }
            foreach ($row in $document.rankings) {
                if ($row.fingerprint -notmatch '^sha256:[a-f0-9]{64}$' -or
                    $row.score -is [bool] -or [double]$row.score -lt 0 -or [double]$row.score -gt 1 -or
                    $row.samples -is [bool] -or [int]$row.samples -lt 10) {
                    throw 'Adaptive ranking server returned an invalid strategy row.'
                }
                if ($fingerprints -notcontains [string]$row.fingerprint -and $fingerprints.Count -lt 10) {
                    $fingerprints += [string]$row.fingerprint
                }
            }
        }
        $status = [string]$document.status
        $generated = if ($status -eq 'not_ready') { 0 } else { [long]$document.generated_at }
    } catch {
        if ($entry.Count -eq 0 -or $entry[0].status -eq 'not_ready' -or $entry[0].fingerprints.Count -eq 0) {
            return [pscustomobject]@{ provider = $Provider; profile_id = $ProfileId; status = 'unavailable'; fingerprints = @(); expires = $now }
        }
        $cached = $entry[0]
        if ([long]$cached.generated_at -lt $now - 86400) {
            return [pscustomobject]@{ provider = $Provider; profile_id = $ProfileId; status = 'unavailable'; fingerprints = @(); expires = $now }
        }
        $status = 'stale-cache'
        $generated = [long]$cached.generated_at
        $fingerprints = @($cached.fingerprints)
    }
    $newEntry = [pscustomobject]@{
        provider = $Provider; profile_id = $ProfileId; protocol = $protocol; recipe_id = $RecipeId
        treatment_variant = $TreatmentVariant; status = $status; generated_at = $generated
        expires = $now + (Get-Random -Minimum 600 -Maximum 1801); fingerprints = @($fingerprints)
    }
    if ($entry.Count -gt 0) { $cache.Entries.Remove($entry[0]) }
    $cache.Entries.Add($newEntry)
    while ($cache.Entries.Count -gt 32) { $cache.Entries.RemoveAt(0) }
    Save-AdaptiveRankingCache $cache
    $newEntry
}

function Get-AdaptiveRankingHint {
    param([switch]$Enabled, [int]$ProfileId, [uri]$Endpoint, [scriptblock]$IdentityRequest,
          [string]$RecipeId = 'tls-http1-v1', [string]$TreatmentVariant = 'standard')
    if (-not $Enabled) { return }
    try {
        $identity = & $IdentityRequest
        if ($identity.schema_version -ne 1 -or $identity.provider -isnot [string] -or
            [string]::IsNullOrWhiteSpace($identity.provider)) { return }
        $rankings = Get-AdaptiveRankedFingerprints -Provider $identity.provider -ProfileId $ProfileId -Endpoint $Endpoint `
            -RecipeId $RecipeId -TreatmentVariant $TreatmentVariant
        @($rankings.fingerprints)
    } catch {
        [Console]::Error.WriteLine('Adaptive rankings unavailable; using the local candidate order.')
        return
    }
}
