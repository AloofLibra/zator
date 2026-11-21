$ErrorActionPreference = 'Stop'
$temp = Join-Path $env:TEMP ('zator-adaptive-state-' + [guid]::NewGuid().ToString('N'))
$ExploreStatePath = Join-Path $temp 'adaptive-explore.tsv'
$AdaptiveAgentMetricsStatePath = Join-Path $temp 'adaptive-agent-metrics.tsv'
$AdaptiveRetryStatePath = Join-Path $temp 'adaptive-retries.tsv'
$DeepSearchStatePath = Join-Path $temp 'adaptive-deepsearch.tsv'
$AdaptiveRampAuditStatePath = Join-Path $temp 'adaptive-ramp-audit.tsv'
try {
    . (Join-Path $PSScriptRoot '..\tools\adaptive-agent-state.ps1')
    if (-not (Test-ExploreBudget -CpuPercent 20 -NetworkBytesPerSecond 1000) -or
        (Test-ExploreBudget -CpuPercent 80 -NetworkBytesPerSecond 1000) -or
        (Test-ExploreBudget -CpuPercent 20 -NetworkBytesPerSecond 2000000) -or
        (Test-ExploreBudget -CpuPercent $null -NetworkBytesPerSecond 1000)) {
        throw 'Exploration load gate did not fail closed at its CPU/network thresholds.'
    }
    if (-not (Test-ExploreRouterBudget -Load1PerCore 0.4 -MemoryAvailableKiB 65536 -ActiveProbes 0) -or
        (Test-ExploreRouterBudget -Load1PerCore 1.1 -MemoryAvailableKiB 65536 -ActiveProbes 0) -or
        (Test-ExploreRouterBudget -Load1PerCore 0.4 -MemoryAvailableKiB 8192 -ActiveProbes 0) -or
        (Test-ExploreRouterBudget -Load1PerCore 0.4 -MemoryAvailableKiB 65536 -ActiveProbes 1) -or
        (Test-ExploreRouterBudget -Load1PerCore $null -MemoryAvailableKiB 65536 -ActiveProbes 0)) {
        throw 'Router capacity gate did not fail closed at load, memory, busy, or missing-metric limits.'
    }
    function Get-CimInstance {
        param([string]$ClassName, [string]$ErrorAction)
        switch ($ClassName) {
            Win32_Processor { return @([pscustomobject]@{ LoadPercentage = 23 }) }
            Win32_PerfFormattedData_Tcpip_NetworkInterface { return @(
                [pscustomobject]@{ Name = 'Ethernet'; BytesReceivedPersec = 1000; BytesSentPersec = 2000 },
                [pscustomobject]@{ Name = 'Loopback Pseudo-Interface'; BytesReceivedPersec = 9000; BytesSentPersec = 9000 }
            ) }
            Win32_OperatingSystem { return [pscustomobject]@{ FreePhysicalMemory = 4194304 } }
            default { throw "Unexpected CIM class: $ClassName" }
        }
    }
    $machineLoad = Get-ExploreMachineLoad
    if ($machineLoad.CpuPercent -ne 23 -or $machineLoad.FreeMemoryBytes -ne 4294967296 -or
        $machineLoad.NetworkBytesPerSecond -ne 3000) {
        throw 'Windows runtime metrics did not use CPU, available memory, and non-loopback network counters.'
    }
    Remove-Item Function:\Get-CimInstance -ErrorAction SilentlyContinue
    $agentMetrics = Read-AdaptiveAgentMetrics
    Add-AdaptiveAgentMetric -Metrics $agentMetrics -Kind revalidation_recovery
    Add-AdaptiveAgentMetric -Metrics $agentMetrics -Kind revalidation_failure
    Add-AdaptiveAgentMetric -Metrics $agentMetrics -Kind revalidation_recovery
    $agentMetrics = Read-AdaptiveAgentMetrics
    if ($agentMetrics.RevalidationRecoveries -ne 2 -or $agentMetrics.RevalidationFailures -ne 1 -or
        (Get-Content -LiteralPath $AdaptiveAgentMetricsStatePath -Raw).Contains('cdn.example.org')) {
        throw 'Bounded adaptive revalidation counters did not persist as target-free local metrics.'
    }
    $key = Get-ExploreTargetKey -TargetHost 'CDN.Example.org' -TargetIp '93.184.216.34' -TargetProfile 1 -TargetScope 'default'
    $sameKey = Get-ExploreTargetKey -TargetHost 'cdn.example.org' -TargetIp '93.184.216.34' -TargetProfile 1 -TargetScope 'default'
    $otherIpKey = Get-ExploreTargetKey -TargetHost 'cdn.example.org' -TargetIp '93.184.216.35' -TargetProfile 1 -TargetScope 'default'
    if ($key -notmatch '^[0-9a-f]{64}$' -or $key -ne $sameKey -or $key -eq $otherIpKey) {
        throw 'Exploration tuple key is not stable and IP-specific.'
    }
    $retryState = Read-AdaptiveFailureRetryState
    $retryEvent = [pscustomobject]@{ hostname = 'cdn.example.org'; destination_ip = '93.184.216.34'; profile_id = 1; scope = 'default' }
    $retryNow = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    Save-AdaptiveFailureRetry -State $retryState -Event $retryEvent -DelayBaseSeconds 60 -Now $retryNow
    $retryState = Read-AdaptiveFailureRetryState
    if ((Get-AdaptiveFailureRetryCooldownCount -State $retryState -Now ($retryNow + 1)) -ne 1 -or
        (Get-AdaptiveFailureRetryCooldownCount -State $retryState -Now ($retryNow + 60)) -ne 0 -or
        (Get-Content -LiteralPath $AdaptiveRetryStatePath -Raw).Contains('cdn.example.org')) {
        throw 'Target-free retry cooldown count did not track active cooldown state.'
    }

    $state = Read-ExploreState
    $catalogVersion = 'sha256:' + ('a' * 64)
    Save-ExploreState -State $state -TargetKey $key -NextOffset 2 -Count 10 -JitterSeconds 17 -CandidateSetVersion $catalogVersion
    $state = Read-ExploreState
    $row = @($state.Rows | Where-Object Key -eq $key)
    if ($state.Last -le 0 -or $state.Jitter -ne 17 -or $row.Count -ne 1 -or $row[0].Offset -ne 2 -or
        $row[0].Count -ne 10 -or $row[0].CandidateSetVersion -ne $catalogVersion) {
        throw 'Exploration cursor, catalog identity, or global pacing timestamp did not persist.'
    }
    $raw = Get-Content -LiteralPath $ExploreStatePath -Raw
    if ($raw.Contains('cdn.example.org') -or $raw.Contains('93.184.216.34')) {
        throw 'Exploration state persisted a raw hostname or destination IP.'
    }

    Save-ExploreState -State $state -TargetKey '' -NextOffset 0 -Count 0 -JitterSeconds 480
    $state = Read-ExploreState
    if ($state.Jitter -ne 480) { throw 'Confirmed four-probe failure cooldown did not persist.' }

    Save-ExploreState -State $state -TargetKey '' -NextOffset 0 -Count 0
    $state = Read-ExploreState
    $row = @($state.Rows | Where-Object Key -eq $key)
    if ($row.Count -ne 1 -or $row[0].Offset -ne 2 -or $row[0].CandidateSetVersion -ne $catalogVersion) {
        throw 'Urgent-test pacing update discarded the exploration cursor or catalog identity.'
    }
    [IO.File]::WriteAllText($ExploreStatePath, "last`t9999999999`n", [Text.Encoding]::ASCII)
    if ((Read-ExploreState).Last -ne 0) { throw 'Future-dated exploration pacing state was accepted.' }
    [IO.File]::WriteAllText($ExploreStatePath, ('x' * 16385), [Text.Encoding]::ASCII)
    $oversizedExploreRejected = $false
    try { [void](Read-ExploreState) } catch { $oversizedExploreRejected = $_.Exception.Message -like '*bounded regular file*' }
    if (-not $oversizedExploreRejected) { throw 'Oversized exploration state was read without a hard bound.' }

    foreach ($reason in @('timeout', 'http_rejected', 'response_too_large')) {
        if ((Get-AdaptiveSearchTransition ([pscustomobject]@{ overall = 'INCONCLUSIVE'; route_verified = $true; reason = $reason })) -ne 'next_candidate') {
            throw "Candidate-level $reason did not continue FastSearch."
        }
    }
    if ((Get-AdaptiveSearchTransition ([pscustomobject]@{ overall = 'SUCCESS'; route_verified = $true; reason = 'probe_ok' })) -ne 'success' -or
        (Get-AdaptiveSearchTransition ([pscustomobject]@{ overall = 'INCONCLUSIVE'; route_verified = $false; reason = 'route_unverified' })) -ne 'stop_infra' -or
        (Get-AdaptiveSearchTransition ([pscustomobject]@{ overall = 'INCONCLUSIVE'; route_verified = $false; queue_seen = $true; reason = 'strategy_unconfirmed' })) -ne 'next_candidate' -or
        (Get-AdaptiveSearchTransition ([pscustomobject]@{ overall = 'INCONCLUSIVE'; route_verified = $true; reason = 'rate_limited' })) -ne 'cooldown' -or
        (Get-AdaptiveSearchTransition ([pscustomobject]@{ overall = 'INCONCLUSIVE'; route_verified = $true; reason = 'server_busy' })) -ne 'cooldown') {
        throw 'FastSearch transition classifier mishandled success, infrastructure failure, or target cooldown.'
    }
    $groups = @(
        (Get-AdaptiveGooglevideoGroupId 'RR1-index.googlevideo.com.')
        (Get-AdaptiveGooglevideoGroupId 'rr2-index.googlevideo.com')
        (Get-AdaptiveGooglevideoGroupId 'rr1-index2.googlevideo.com')
        (Get-AdaptiveGooglevideoGroupId 'r1---sn-abcd.googlevideo.com')
        (Get-AdaptiveGooglevideoGroupId 'r2---sn-abcd.googlevideo.com')
        (Get-AdaptiveGooglevideoGroupId 'r2---sn-efgh.googlevideo.com')
        (Get-AdaptiveGooglevideoGroupId 'redirector.googlevideo.com')
        (Get-AdaptiveGooglevideoGroupId 'rr1-index.evilgooglevideo.com')
    )
    if ($groups[0] -ne $groups[1] -or $groups[0] -eq $groups[2] -or
        $groups[3] -ne $groups[4] -or $groups[3] -eq $groups[5] -or
        $groups[6] -ne 'exact:redirector.googlevideo.com' -or
        $groups[7] -ne 'exact:rr1-index.evilgooglevideo.com') {
        throw "Adaptive Googlevideo grouping merged unrelated hosts: $($groups -join ',')"
    }
    $transitionAudit = [pscustomobject]@{ Target = [pscustomobject]@{ hostname = 'rr1-index.googlevideo.com'; destination_ip = '142.250.72.14'; scope = 'mark:4'; ramp_state = 'ramp_default' }
        Step = 0; Outcome = 'pending'; TreatmentVariant = 'gv_tcp_ramp'; StrategyNumber = 7; PlainSuccesses = 0; RampSuccesses = 0; MediaUrlHash = '' }
    $validRampResult = [pscustomobject]@{ route_verified = $true; queue_seen = $true; strategy_ack_seen = $true; overall = 'SUCCESS'
        transport = 'OK'; application = 'OK'; syn_stage_confirmed = $true; late_ack_stage_confirmed = $true
        target = [pscustomobject]@{ hostname = 'rr1-index.googlevideo.com'; destination_ip = '142.250.72.14'; profile_id = 2; scope = 'mark:4' }
        strategy = [pscustomobject]@{ local_number = 7 }; recipe_id = 'googlevideo-tcp-media-v1'; treatment_variant = 'gv_tcp_ramp'
        media_url_sha256 = ('d' * 64) }
    if ((Get-AdaptiveRampAuditTransition -Audit $transitionAudit -Result $validRampResult -ProbeStatus complete).Step -ne 1 -or
        (Get-AdaptiveRampAuditTransition -Audit $transitionAudit -Result ($validRampResult | Select-Object * -ExcludeProperty late_ack_stage_confirmed) -ProbeStatus complete).Step -ne 0 -or
        (Get-AdaptiveRampAuditTransition -Audit $transitionAudit -Result $validRampResult -ProbeStatus cancelled).Step -ne 0) {
        throw 'Ramp audit transition accepted missing late-ACK or cancelled evidence.'
    }
    $differentMediaResult = $validRampResult | Select-Object *; $differentMediaResult.media_url_sha256 = ('e' * 64)
    $sameUrlAudit = $transitionAudit | Select-Object *; $sameUrlAudit.MediaUrlHash = ('d' * 64)
    if ((Get-AdaptiveRampAuditTransition -Audit $sameUrlAudit -Result $differentMediaResult -ProbeStatus complete).Outcome -ne 'inconclusive') {
        throw 'Ramp audit accepted results measured against different signed media URLs.'
    }
    $transitionAudit.Step = 1; $transitionAudit.TreatmentVariant = 'gv_tcp_plain'; $validPlainResult = $validRampResult | Select-Object *
    $validPlainResult.target = $validRampResult.target; $validPlainResult.strategy = $validRampResult.strategy
    $validPlainResult.treatment_variant = 'gv_tcp_plain'; $validPlainResult.syn_stage_confirmed = $false; $validPlainResult.late_ack_stage_confirmed = $false
    $plainTransition = Get-AdaptiveRampAuditTransition -Audit $transitionAudit -Result $validPlainResult -ProbeStatus complete
    if ($plainTransition.Outcome -ne 'plain_ok' -or $plainTransition.Step -ne 2 -or $plainTransition.PlainSuccesses -ne 1) {
        throw 'Ramp audit did not require and record a route-verified plain media success.'
    }
    $degradedTarget = $transitionAudit.Target | Select-Object *; $degradedTarget.ramp_state = 'ramp_exempt'
    $suspectAudit = [pscustomobject]@{ Target = $degradedTarget; Step = 1; Outcome = 'ramp_ok'; TreatmentVariant = 'gv_tcp_plain';
        StrategyNumber = 7; PlainSuccesses = 0; RampSuccesses = 1; MediaUrlHash = ('d' * 64) }
    $degradedPlain = $validPlainResult | Select-Object *; $degradedPlain.overall = 'INCONCLUSIVE'; $degradedPlain.transport = 'UNKNOWN'
    $degradedPlain.application = 'UNKNOWN'; $degradedPlain | Add-Member -NotePropertyName reason -NotePropertyValue 'media_insufficient'
    $suspectTransition = Get-AdaptiveRampAuditTransition -Audit $suspectAudit -Result $degradedPlain -ProbeStatus complete
    $reconfirmAudit = [pscustomobject]@{ Target = $degradedTarget; Step = 3; Outcome = 'plain_suspect'; TreatmentVariant = 'gv_tcp_ramp';
        StrategyNumber = 7; PlainSuccesses = 0; RampSuccesses = 1; MediaUrlHash = ('d' * 64) }
    $reconfirmTransition = Get-AdaptiveRampAuditTransition -Audit $reconfirmAudit -Result $validRampResult -ProbeStatus complete
    if ($suspectTransition.Outcome -ne 'plain_suspect' -or $suspectTransition.Step -ne 3 -or
        $reconfirmTransition.Outcome -ne 'plain_degraded_confirmed' -or $reconfirmTransition.Step -ne 0) {
        throw 'Ramp exemption degradation was not confirmed by the same-URL Ramp/plain/Ramp sequence.'
    }
    $wrongIpResult = $validPlainResult | Select-Object *; $wrongIpResult.target = [pscustomobject]@{ hostname = 'rr1-index.googlevideo.com'; destination_ip = '142.250.72.15'; profile_id = 2; scope = 'mark:4' }
    if ((Get-AdaptiveRampAuditTransition -Audit $transitionAudit -Result $wrongIpResult -ProbeStatus complete).Outcome -ne 'inconclusive') {
        throw 'Ramp audit accepted a media result for another IP.'
    }
    $finalAudit = [pscustomobject]@{ Target = $transitionAudit.Target; Step = 3; TreatmentVariant = 'gv_tcp_ramp'; StrategyNumber = 7; PlainSuccesses = 2; RampSuccesses = 1 }
    $finalTransition = Get-AdaptiveRampAuditTransition -Audit $finalAudit -Result $validRampResult -ProbeStatus complete
    if ($finalTransition.Outcome -ne 'plain_confirmed' -or $finalTransition.Step -ne 4 -or $finalTransition.RampSuccesses -ne 2) {
        throw 'Two plain successes were not bracketed by Ramp controls.'
    }
    $rampKey = Get-AdaptiveRampAuditKey -Hostname 'RR1-index.googlevideo.com.' -DestinationIp '142.250.72.14' -Scope 'mark:4'
    $rampSameKey = Get-AdaptiveRampAuditKey -Hostname 'rr1-index.googlevideo.com' -DestinationIp '142.250.72.14' -Scope 'mark:4'
    $rampOtherScope = Get-AdaptiveRampAuditKey -Hostname 'rr1-index.googlevideo.com' -DestinationIp '142.250.72.14' -Scope 'default'
    if ($rampKey -ne $rampSameKey -or $rampKey -eq $rampOtherScope -or
        (Test-AdaptiveRampPublicIpv4 '192.168.1.1') -or -not (Test-AdaptiveRampPublicIpv4 '142.250.72.14')) {
        throw 'Ramp audit cooldown identity merged scope or accepted a non-public destination.'
    }
    $rampNow = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $rampTarget = [pscustomobject]@{ hostname = 'rr1-index.googlevideo.com'; destination_ip = '142.250.72.14'; scope = 'mark:4'
        group_id = 'gv1:rr:index'; observed_at = $rampNow; provenance = 'tls-observed'; ramp_state = 'ramp_default'
        dns_expires_at = $rampNow + 3600; media_recipe_available = 'available' }
    $rampUnsafe = [pscustomobject]@{ hostname = 'rr2-index.googlevideo.com'; destination_ip = '192.168.1.1'; scope = 'mark:4'
        group_id = 'gv1:rr:index'; observed_at = $rampNow; provenance = 'tls-observed'; ramp_state = 'ramp_default'
        dns_expires_at = $null; media_recipe_available = 'available' }
    [IO.File]::WriteAllText($AdaptiveRampAuditStatePath, "last`t9999999999`n", [Text.Encoding]::ASCII)
    $rampState = Read-AdaptiveRampAuditState
    $rampCatalog = 'sha256:' + ('c' * 64)
    if ($rampState.Last -ne 0) { throw 'Future-dated Ramp audit pacing state blocked the scheduler.' }
    $dueRamp = Get-AdaptiveDueRampAuditTarget -Targets @($rampUnsafe, $rampTarget) -State $rampState -Now $rampNow
    if ($null -eq $dueRamp -or $dueRamp.Key -ne $rampKey -or $dueRamp.GroupKey -ne 'gv1:rr:index' -or
        $dueRamp.TreatmentVariant -ne 'gv_tcp_ramp' -or $dueRamp.Step -ne 0) {
        throw 'Ramp audit scheduler did not select only the fresh, observed, media-ready exact target.'
    }
    Save-AdaptiveRampAuditAttempt -State $rampState -Key $dueRamp.Key -GroupId $dueRamp.GroupKey -Outcome ramp_ok -RampSuccesses 1 -Step 1 -CandidateSetVersion $rampCatalog -MediaUrlHash ('d' * 64) -ProofTestId ('a' * 32) -StrategyNumber 7
    $rampState = Read-AdaptiveRampAuditState
    $rampRaw = Get-Content -LiteralPath $AdaptiveRampAuditStatePath -Raw
    if ($rampState.Rows.Count -ne 1 -or $rampState.Rows[0].RampSuccesses -ne 1 -or $rampState.Rows[0].Step -ne 1 -or
        $rampState.Rows[0].MediaUrlHash -ne ('d' * 64) -or
        $rampRaw.Contains('rr1-index.googlevideo.com') -or $rampRaw.Contains('142.250.72.14') -or
        $null -ne (Get-AdaptiveDueRampAuditTarget -Targets @($rampTarget) -State $rampState -Now ($rampNow + 100))) {
        throw 'Ramp audit cursor failed persistence, exact-target cooldown, or local identifier privacy.'
    }
    $dueRamp = Get-AdaptiveDueRampAuditTarget -Targets @($rampTarget) -State $rampState -Now ($rampNow + 301)
    if ($null -eq $dueRamp -or $dueRamp.TreatmentVariant -ne 'gv_tcp_plain') { throw 'Ramp audit did not alternate to the plain control after Ramp.' }
    $rampSibling = $rampTarget | Select-Object *
    $rampSibling.hostname = 'rr2-index.googlevideo.com'; $rampSibling.destination_ip = '142.250.72.15'
    $rampDifferentGroup = $rampTarget | Select-Object *
    $rampDifferentGroup.hostname = 'rr1-index2.googlevideo.com'; $rampDifferentGroup.destination_ip = '142.250.72.16'
    $rampDifferentGroup.group_id = 'gv1:rr:index2'
    $diverseRamp = Get-AdaptiveDueRampAuditTarget -Targets @($rampSibling, $rampDifferentGroup) -State $rampState -Now ($rampNow + 301)
    if ($null -eq $diverseRamp -or $diverseRamp.Key -eq $rampKey -or $diverseRamp.GroupKey -ne 'gv1:rr:index2') {
        throw "Ramp audit scheduler did not prefer an untested CDN group while keeping exact targets distinct: $(ConvertTo-Json -InputObject $diverseRamp -Compress -Depth 4)"
    }
    $inProgressRamp = Get-AdaptiveDueRampAuditTarget -Targets @($rampTarget, $rampDifferentGroup) -State $rampState -Now ($rampNow + 301)
    if ($null -eq $inProgressRamp -or $inProgressRamp.Key -ne $rampKey -or $inProgressRamp.TreatmentVariant -ne 'gv_tcp_plain' -or $inProgressRamp.Step -ne 1) {
        throw 'Group diversity interrupted an exact Ramp/plain audit sequence in progress.'
    }
    Save-AdaptiveRampAuditAttempt -State $rampState -Key $dueRamp.Key -GroupId $dueRamp.GroupKey -Outcome plain_ok -PlainSuccesses 1 -RampSuccesses 1 -Step 2 -CandidateSetVersion $rampCatalog -MediaUrlHash ('d' * 64) -ProofTestIds $dueRamp.ProofTestIds -ProofTestId ('b' * 32) -StrategyNumber 7
    $rampState = Read-AdaptiveRampAuditState
    $dueRamp = Get-AdaptiveDueRampAuditTarget -Targets @($rampTarget) -State $rampState -Now ($rampNow + 602)
    if ($null -eq $dueRamp -or $dueRamp.TreatmentVariant -ne 'gv_tcp_plain') { throw 'Ramp audit did not require a second independent plain confirmation.' }
    Save-AdaptiveRampAuditAttempt -State $rampState -Key $dueRamp.Key -GroupId $dueRamp.GroupKey -Outcome plain_ok -PlainSuccesses 2 -RampSuccesses 1 -Step 3 -CandidateSetVersion $rampCatalog -MediaUrlHash ('d' * 64) -ProofTestIds $dueRamp.ProofTestIds -ProofTestId ('c' * 32) -StrategyNumber 7
    $rampState = Read-AdaptiveRampAuditState
    $dueRamp = Get-AdaptiveDueRampAuditTarget -Targets @($rampTarget) -State $rampState -Now ($rampNow + 903)
    if ($null -eq $dueRamp -or $dueRamp.TreatmentVariant -ne 'gv_tcp_ramp') { throw 'Ramp audit did not schedule the final Ramp control.' }
    Save-AdaptiveRampAuditAttempt -State $rampState -Key $dueRamp.Key -GroupId $dueRamp.GroupKey -Outcome plain_confirmed -PlainSuccesses 2 -RampSuccesses 2 -Step 4 -CandidateSetVersion $rampCatalog -MediaUrlHash ('d' * 64) -ProofTestIds $dueRamp.ProofTestIds -ProofTestId ('e' * 32) -StrategyNumber 7 -CooldownSeconds 18000
    $rampState = Read-AdaptiveRampAuditState
    if ($rampState.Rows[0].ProofTestIds -ne (('{0},{1},{2},{3}' -f ('a' * 32), ('b' * 32), ('c' * 32), ('e' * 32)))) {
        throw 'Ramp audit proof did not retain the four ordered controller result IDs.'
    }
    if ($null -ne (Get-AdaptiveDueRampAuditTarget -Targets @($rampTarget) -State $rampState -Now ($rampNow + 1204))) {
        throw 'Confirmed Ramp/plain comparison was scheduled again instead of becoming terminal.'
    }
    $rampTarget.ramp_state = 'ramp_exempt'
    Save-AdaptiveRampAuditAttempt -State $rampState -Key $rampKey -GroupId 'gv1:rr:index' -Outcome plain_suspect `
        -RampSuccesses 1 -Step 3 -CandidateSetVersion $rampCatalog -MediaUrlHash ('d' * 64) -ProofTestIds ('a' * 32) `
        -ProofTestId ('b' * 32) -StrategyNumber 7 -CooldownSeconds 300
    $rampState = Read-AdaptiveRampAuditState
    $recheckRamp = Get-AdaptiveDueRampAuditTarget -Targets @($rampTarget) -State $rampState -Now ($rampNow + 1505)
    if ($null -eq $recheckRamp -or $recheckRamp.TreatmentVariant -ne 'gv_tcp_ramp' -or $recheckRamp.Step -ne 3 -or
        $recheckRamp.ProofTestIds -ne (('{0},{1}' -f ('a' * 32), ('b' * 32))) -or $recheckRamp.MediaUrlHash -ne ('d' * 64)) {
        throw 'A suspected plain-media degradation did not schedule a same-proof Ramp control.'
    }
    $deep = Read-AdaptiveDeepSearchState
    $deepKey = Get-AdaptiveDeepSearchKey -Hostname 'cdn.example.org' -DestinationIp '93.184.216.34' -ProfileId 1 -Scope default
    $mediaDeepKey = Get-AdaptiveDeepSearchKey -Hostname 'rr1---sn-a5mekn6e.googlevideo.com' -DestinationIp '93.184.216.34' -ProfileId 2 -Scope default -RecipeId 'googlevideo-tcp-media-v1'
    if ($deepKey -eq $mediaDeepKey) { throw 'TLS and Googlevideo media DeepSearch cursors collided.' }
    $deepDueAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $job = @{ Key = $deepKey; Hostname = 'cdn.example.org'; DestinationIp = '93.184.216.34'; ProfileId = 1; Scope = 'default';
        RecipeId = 'tls-http1-v1'; CandidateSetVersion = 'sha256:' + ('b' * 64); CandidateCount = 20; Offset = 10; NextAt = $deepDueAt }
    Save-AdaptiveDeepSearchJob -State $deep -Job $job
    $mediaJob = @{ Key = $mediaDeepKey; Hostname = 'rr1---sn-a5mekn6e.googlevideo.com'; DestinationIp = '93.184.216.34'; ProfileId = 2; Scope = 'default';
        RecipeId = 'googlevideo-tcp-media-v1'; CandidateSetVersion = 'sha256:' + ('c' * 64); CandidateCount = 30; Offset = 10; NextAt = $deepDueAt }
    $deep = Read-AdaptiveDeepSearchState
    Save-AdaptiveDeepSearchJob -State $deep -Job $mediaJob
    $deep = Read-AdaptiveDeepSearchState
    if ($deep.Jobs.Count -ne 2 -or $deep.Jobs[0].RecipeId -ne 'tls-http1-v1' -or $deep.Jobs[0].Offset -ne 10 -or
        $deep.Jobs[0].CandidateSetVersion -ne $job.CandidateSetVersion -or $deep.Jobs[1].RecipeId -ne 'googlevideo-tcp-media-v1') {
        throw 'Adaptive DeepSearch cursor did not survive restart-style reload.'
    }
    if ($null -ne (Get-AdaptiveDueDeepSearchJob -State $deep -Now ($deepDueAt - 1)) -or
        $null -eq (Get-AdaptiveDueDeepSearchJob -State $deep -Now $deepDueAt)) {
        throw 'Adaptive DeepSearch scheduler ignored its persisted due time.'
    }
    if ($deep.Jobs[0].RecipeId -ne 'tls-http1-v1') { throw 'Adaptive DeepSearch recipe category was not persisted.' }
    Remove-AdaptiveDeepSearchJob -State $deep -Key $deepKey
    $deep = Read-AdaptiveDeepSearchState
    Remove-AdaptiveDeepSearchJob -State $deep -Key $mediaDeepKey
    if ((Read-AdaptiveDeepSearchState).Jobs.Count -ne 0) { throw 'Completed DeepSearch cursor was not removed.' }
    Write-Output 'adaptive agent exploration state smoke: ok'
} finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
