# This repository, including its original source code and implementation, is licensed under GNU GPL v3.0; see LICENSE for the full terms. Redistribution, modification, and reuse must comply with that license and preserve applicable copyright and license notices. Unauthorized copying, including verbatim code copying or presenting this repository implementation or operating logic as your own, may be reported to the relevant hosting platforms.
# Bounded per-user cursor and pacing state for opt-in local exploration.
function Get-AdaptiveFailureRetryStatePath {
    if (-not [string]::IsNullOrWhiteSpace($AdaptiveRetryStatePath)) { return $AdaptiveRetryStatePath }
    $base = if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { $env:LOCALAPPDATA } else { $env:USERPROFILE }
    if ([string]::IsNullOrWhiteSpace($base)) { throw 'Cannot locate a private adaptive revalidation state directory.' }
    Join-Path $base 'Zator\adaptive-revalidation.tsv'
}

function Get-AdaptiveAgentMetricsPath {
    if (-not [string]::IsNullOrWhiteSpace($AdaptiveAgentMetricsStatePath)) { return $AdaptiveAgentMetricsStatePath }
    $base = if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { $env:LOCALAPPDATA } else { $env:USERPROFILE }
    if ([string]::IsNullOrWhiteSpace($base)) { throw 'Cannot locate a private adaptive metrics directory.' }
    Join-Path $base 'Zator\adaptive-agent-metrics.tsv'
}

function Read-AdaptiveAgentMetrics {
    $path = Get-AdaptiveAgentMetricsPath
    $metrics = @{ Path = $path; RevalidationRecoveries = 0; RevalidationFailures = 0 }
    if (-not (Test-Path -LiteralPath $path)) { return $metrics }
    $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -gt 128) {
        throw 'Adaptive agent metrics are not a bounded regular file.'
    }
    $parts = (Get-Content -LiteralPath $path -Raw -ErrorAction Stop).TrimEnd("`r", "`n") -split "`t", 3
    if ($parts.Count -ne 3 -or $parts[0] -ne '1' -or $parts[1] -notmatch '^(0|[1-9][0-9]{0,5})$' -or
        $parts[2] -notmatch '^(0|[1-9][0-9]{0,5})$') { throw 'Adaptive agent metrics are malformed.' }
    $metrics.RevalidationRecoveries = [int]$parts[1]
    $metrics.RevalidationFailures = [int]$parts[2]
    return $metrics
}

function Add-AdaptiveAgentMetric {
    param([Parameter(Mandatory = $true)][hashtable]$Metrics,
        [Parameter(Mandatory = $true)][ValidateSet('revalidation_recovery', 'revalidation_failure')][string]$Kind)
    $property = if ($Kind -eq 'revalidation_recovery') { 'RevalidationRecoveries' } else { 'RevalidationFailures' }
    $Metrics[$property] = [Math]::Min(999999, [int]$Metrics[$property] + 1)
    $directory = Split-Path -Parent $Metrics.Path
    [void](New-Item -ItemType Directory -Path $directory -Force)
    $temporary = "$($Metrics.Path).$PID.tmp"
    $line = "1`t$($Metrics.RevalidationRecoveries)`t$($Metrics.RevalidationFailures)`n"
    [IO.File]::WriteAllText($temporary, $line, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $Metrics.Path -Force
}

function Get-AdaptiveFailureRetryKey {
    param([Parameter(Mandatory = $true)]$Event)
    Get-ExploreTargetKey -TargetHost ([string]$Event.hostname) -TargetIp ([string]$Event.destination_ip) `
        -TargetProfile ([int]$Event.profile_id) -TargetScope ([string]$Event.scope)
}

function Read-AdaptiveFailureRetryState {
    $path = Get-AdaptiveFailureRetryStatePath
    $rows = @()
    if (Test-Path -LiteralPath $path) {
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -gt 16384) {
            throw 'Adaptive revalidation state is not a bounded regular file.'
        }
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $seen = @{}
        foreach ($line in Get-Content -LiteralPath $path -ErrorAction Stop) {
            $parts = $line -split "`t", 6
            if ($parts.Count -ne 5 -or $parts[0] -ne 'retry' -or $parts[1] -notmatch '^[0-9a-f]{64}$' -or
                $parts[2] -notmatch '^[1-8]$' -or $parts[3] -notmatch '^[0-9]{1,10}$' -or
                $parts[4] -notmatch '^[0-9]{1,10}$' -or $seen.ContainsKey($parts[1]) -or $rows.Count -ge 128) { continue }
            $updated = [long]$parts[4]; $nextAt = [long]$parts[3]
            if ($updated -lt ($now - 604800) -or $updated -gt ($now + 300) -or $nextAt -gt ($now + 86400)) { continue }
            $seen[$parts[1]] = $true
            $rows += ,@{ Key = $parts[1]; Attempts = [int]$parts[2]; NextAt = $nextAt; Updated = $updated }
        }
    }
    @{ Path = $path; Rows = $rows }
}

function Test-AdaptiveFailureRetryDue {
    param([Parameter(Mandatory = $true)][hashtable]$State, [Parameter(Mandatory = $true)][string]$Key,
        [long]$Now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
    if ($Key -notmatch '^[0-9a-f]{64}$') { return $false }
    $row = @($State.Rows | Where-Object Key -eq $Key | Select-Object -First 1)
    return $row.Count -eq 0 -or [long]$row[0].NextAt -le $Now
}

function Save-AdaptiveFailureRetry {
    param([Parameter(Mandatory = $true)][hashtable]$State, [Parameter(Mandatory = $true)]$Event,
        [ValidateRange(60, 86400)][int]$DelayBaseSeconds = 60,
        [long]$Now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
    $key = Get-AdaptiveFailureRetryKey -Event $Event
    $previous = @($State.Rows | Where-Object Key -eq $key | Select-Object -First 1)
    $attempts = if ($previous.Count -gt 0) { [Math]::Min(8, [int]$previous[0].Attempts + 1) } else { 1 }
    $delay = [Math]::Min(1800, $DelayBaseSeconds * [Math]::Pow(2, $attempts - 1))
    $retained = @($State.Rows | Where-Object Key -ne $key | Sort-Object Updated -Descending | Select-Object -First 127)
    $retained += ,@{ Key = $key; Attempts = $attempts; NextAt = $Now + [long]$delay; Updated = $Now }
    Write-AdaptiveFailureRetryState -State $State -Rows $retained
}

function Clear-AdaptiveFailureRetry {
    param([Parameter(Mandatory = $true)][hashtable]$State, [Parameter(Mandatory = $true)][string]$Key)
    if ($Key -notmatch '^[0-9a-f]{64}$') { throw 'Invalid adaptive revalidation identity.' }
    $retained = @($State.Rows | Where-Object Key -ne $Key)
    if ($retained.Count -eq $State.Rows.Count) { return }
    Write-AdaptiveFailureRetryState -State $State -Rows $retained
}

function Write-AdaptiveFailureRetryState {
    param([Parameter(Mandatory = $true)][hashtable]$State,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Rows)
    $directory = Split-Path -Parent $State.Path
    [void](New-Item -ItemType Directory -Path $directory -Force)
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($row in @($Rows | Sort-Object Updated -Descending | Select-Object -First 128)) {
        if ($row.Key -notmatch '^[0-9a-f]{64}$' -or $row.Attempts -lt 1 -or $row.Attempts -gt 8 -or
            $row.NextAt -notmatch '^[0-9]{1,10}$' -or $row.Updated -notmatch '^[0-9]{1,10}$') { continue }
        $lines.Add(("retry`t{0}`t{1}`t{2}`t{3}" -f $row.Key, $row.Attempts, $row.NextAt, $row.Updated))
    }
    $temporary = "$($State.Path).$PID.tmp"
    [IO.File]::WriteAllLines($temporary, $lines.ToArray(), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $State.Path -Force
}

function Get-ExploreStatePath {
    if (-not [string]::IsNullOrWhiteSpace($ExploreStatePath)) { return $ExploreStatePath }
    $base = if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { $env:LOCALAPPDATA } else { $env:USERPROFILE }
    if ([string]::IsNullOrWhiteSpace($base)) { throw 'Cannot locate a private per-user exploration state directory.' }
    Join-Path $base 'Zator\adaptive-explore.tsv'
}

function Read-ExploreState {
    $path = Get-ExploreStatePath
    $rows = @()
    $last = 0L
    $jitter = 0
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -gt 16384) {
            throw 'Adaptive exploration state is not a bounded regular file.'
        }
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        foreach ($line in Get-Content -LiteralPath $path -ErrorAction Stop) {
            $parts = $line -split "`t", 6
            if ($parts.Count -in @(2, 3) -and $parts[0] -eq 'last' -and $parts[1] -match '^\d{1,10}$') {
                $candidateLast = [long]$parts[1]
                if ($candidateLast -ge ($now - 604800) -and $candidateLast -le ($now + 300)) { $last = $candidateLast }
                if ($parts.Count -eq 3 -and $parts[2] -match '^\d{1,3}$' -and [int]$parts[2] -le 600) { $jitter = [int]$parts[2] }
                continue
            }
            if ($parts.Count -in @(5, 6) -and $parts[0] -eq 'target' -and $parts[1] -match '^[0-9a-f]{64}$' -and
                $parts[2] -match '^\d{1,3}$' -and $parts[3] -match '^[1-9]\d{0,2}$' -and
                [int]$parts[2] -lt [int]$parts[3] -and $parts[4] -match '^\d{1,10}$' -and
                ($parts.Count -eq 5 -or $parts[5] -match '^(|sha256:[a-f0-9]{64})$') -and
                [long]$parts[4] -ge ($now - 604800) -and [long]$parts[4] -le ($now + 300) -and $rows.Count -lt 255) {
                $rows += ,@{ Key = $parts[1]; Offset = [int]$parts[2]; Count = [int]$parts[3]; Updated = [long]$parts[4];
                    CandidateSetVersion = if ($parts.Count -eq 6) { $parts[5] } else { '' } }
            }
        }
    }
    @{ Path = $path; Last = $last; Jitter = $jitter; Rows = $rows }
}

function Get-ExploreTargetKey {
    param([string]$TargetHost, [string]$TargetIp, [int]$TargetProfile, [string]$TargetScope)
    $bytes = [Text.Encoding]::UTF8.GetBytes(('{0}|{1}|{2}|{3}' -f $TargetHost.ToLowerInvariant(), $TargetIp, $TargetProfile, $TargetScope))
    $sha = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Save-ExploreState {
    param([hashtable]$State, [string]$TargetKey, [int]$NextOffset, [int]$Count,
        [ValidateRange(0, 600)][int]$JitterSeconds = 0, [string]$CandidateSetVersion = '')
    if ($CandidateSetVersion -notmatch '^(|sha256:[a-f0-9]{64})$') { throw 'Invalid exploration candidate-set version.' }
    $directory = Split-Path -Parent $State.Path
    [void](New-Item -ItemType Directory -Path $directory -Force)
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("last`t$now`t$JitterSeconds")
    $retainedRows = @($State.Rows | Where-Object { [string]::IsNullOrWhiteSpace($TargetKey) -or $_.Key -ne $TargetKey } | Sort-Object Updated -Descending | Select-Object -First 255)
    foreach ($row in $retainedRows) {
        $lines.Add(("target`t{0}`t{1}`t{2}`t{3}`t{4}" -f $row.Key, $row.Offset, $row.Count, $row.Updated, $row.CandidateSetVersion))
    }
    if (-not [string]::IsNullOrWhiteSpace($TargetKey)) {
        $lines.Add(("target`t{0}`t{1}`t{2}`t{3}`t{4}" -f $TargetKey, $NextOffset, $Count, $now, $CandidateSetVersion))
    }
    $temporary = "$($State.Path).$PID.tmp"
    [IO.File]::WriteAllLines($temporary, $lines.ToArray(), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $State.Path -Force
}

function Get-ExploreMachineLoad {
    $processors = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop)
    $interfaces = @(Get-CimInstance -ClassName Win32_PerfFormattedData_Tcpip_NetworkInterface -ErrorAction Stop |
        Where-Object { $_.Name -notmatch 'Loopback|Teredo|isatap' })
    $operatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    if ($processors.Count -eq 0 -or $interfaces.Count -eq 0 -or $null -eq $operatingSystem) { throw 'Machine load counters are unavailable.' }
    $cpu = [Math]::Round((($processors | Measure-Object -Property LoadPercentage -Average).Average), 0)
    $network = [long](($interfaces | Measure-Object -Property BytesReceivedPersec -Sum).Sum +
        ($interfaces | Measure-Object -Property BytesSentPersec -Sum).Sum)
    $memory = [long]$operatingSystem.FreePhysicalMemory * 1024
    if ($cpu -lt 0 -or $cpu -gt 100 -or $network -lt 0 -or $memory -lt 0) { throw 'Machine load counters are invalid.' }
    @{ CpuPercent = [int]$cpu; FreeMemoryBytes = $memory; NetworkBytesPerSecond = $network }
}

function Test-ExploreBudget {
    param(
        [AllowNull()][Nullable[int]]$CpuPercent,
        [AllowNull()][Nullable[long]]$NetworkBytesPerSecond,
        [ValidateRange(1, 100)][int]$MaxCpuPercent = 70,
        [ValidateRange(1, 1073741824)][long]$MaxNetworkBytesPerSecond = 1048576
    )
    if ($null -eq $CpuPercent -or $null -eq $NetworkBytesPerSecond) { return $false }
    return ($CpuPercent -lt $MaxCpuPercent -and $NetworkBytesPerSecond -lt $MaxNetworkBytesPerSecond)
}

function Test-ExploreRouterBudget {
    param(
        [AllowNull()][Nullable[double]]$Load1PerCore,
        [AllowNull()][Nullable[long]]$MemoryAvailableKiB,
        [AllowNull()][Nullable[int]]$ActiveProbes,
        [ValidateRange(0.1, 16)][double]$MaxLoadPerCore = 0.8,
        [ValidateRange(8, 1024)][int]$MinMemoryMiB = 32
    )
    if ($null -eq $Load1PerCore -or $null -eq $MemoryAvailableKiB -or $null -eq $ActiveProbes) { return $false }
    return ($Load1PerCore -lt $MaxLoadPerCore -and
        $MemoryAvailableKiB -ge ([long]$MinMemoryMiB * 1024) -and
        $ActiveProbes -eq 0)
}

function Get-AdaptiveSearchTransition {
    param([Parameter(Mandatory = $true)][object]$Result)
    if ($Result.overall -eq 'SUCCESS') { return 'success' }
    if ($Result.reason -in @('rate_limited', 'server_busy')) { return 'cooldown' }
    if ($Result.overall -eq 'INCONCLUSIVE' -and $Result.queue_seen -eq $true -and
        $Result.reason -in @('timeout', 'http_rejected', 'response_too_large', 'empty_response', 'strategy_unconfirmed')) {
        return 'next_candidate'
    }
    if ($Result.route_verified -ne $true -or $Result.reason -in @(
        'route_unverified', 'strategy_unconfirmed', 'cancelled', 'expired', 'probe_error',
        'invalid_result', 'candidate_page_conflict', 'candidate_page_validation_failed'
    )) { return 'stop_infra' }
    if ($Result.overall -in @('FAIL', 'INCONCLUSIVE')) { return 'next_candidate' }
    return 'stop_infra'
}

function Get-AdaptiveGooglevideoGroupId {
    param([Parameter(Mandatory = $true)][string]$Hostname)
    $hostName = $Hostname.Trim().TrimEnd('.').ToLowerInvariant()
    if ($hostName.Length -gt 253 -or $hostName -notmatch '^(?=.{1,253}$)([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)(\.([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?))*$') {
        throw 'Invalid Googlevideo hostname.'
    }
    if ($hostName -notmatch '(^|\.)googlevideo\.com$') { return "exact:$hostName" }
    if ($hostName -match '^rr[0-9]+-(.+)\.googlevideo\.com$') { return "gv1:rr:$($Matches[1])" }
    if ($hostName -match '^r[0-9]+(---sn-[a-z0-9-]+)\.googlevideo\.com$') { return "gv1:r:$($Matches[1])" }
    return "exact:$hostName"
}

# Exact, local cooldown identity for the future low-priority Ramp audit queue.
# Grouping is intentionally excluded: group hints may prioritize a target but
# never suppress an exact host/IP/scope audit.
function Get-AdaptiveRampAuditKey {
    param([string]$Hostname, [string]$DestinationIp, [string]$Scope)
    $hostName = $Hostname.Trim().TrimEnd('.').ToLowerInvariant()
    if ($hostName -notmatch '^(?=.{1,253}$)([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)(\.([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?))*\.googlevideo\.com$' -or
        $DestinationIp -notmatch '^([0-9]{1,3}\.){3}[0-9]{1,3}$' -or $Scope -notmatch '^(default|mark:[1-9][0-9]{0,4})$') {
        throw 'Invalid exact Googlevideo Ramp audit target.'
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes(('{0}|{1}|{2}' -f $hostName, $DestinationIp, $Scope))
    $sha = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-AdaptiveRampAuditGroupKey {
    param([Parameter(Mandatory = $true)][string]$GroupId)
    if ($GroupId -notmatch '^gv1:(rr|r|exact):[a-z0-9.-]+$') { throw 'Invalid Googlevideo group identity.' }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($GroupId)))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Test-AdaptiveRampPublicIpv4 {
    param([string]$Address)
    $parsed = $null
    if (-not [Net.IPAddress]::TryParse($Address, [ref]$parsed) -or $parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { return $false }
    $octets = $Address.Split('.')
    if ($octets.Count -ne 4 -or @($octets | Where-Object { $_ -notmatch '^(0|[1-9][0-9]{0,2})$' -or [int]$_ -gt 255 }).Count -gt 0) { return $false }
    $a = [int]$octets[0]; $b = [int]$octets[1]; $c = [int]$octets[2]
    return -not ($a -eq 0 -or $a -eq 10 -or $a -eq 127 -or $a -ge 224 -or
        ($a -eq 100 -and $b -ge 64 -and $b -le 127) -or ($a -eq 169 -and $b -eq 254) -or
        ($a -eq 172 -and $b -ge 16 -and $b -le 31) -or ($a -eq 192 -and ($b -eq 168 -or ($b -eq 0 -and $c -in @(0, 2)) -or ($b -eq 88 -and $c -eq 99))) -or
        ($a -eq 198 -and ($b -in @(18, 19) -or ($b -eq 51 -and $c -eq 100))) -or ($a -eq 203 -and $b -eq 0 -and $c -eq 113))
}

function Get-AdaptiveRampAuditStatePath {
    if (-not [string]::IsNullOrWhiteSpace($AdaptiveRampAuditStatePath)) { return $AdaptiveRampAuditStatePath }
    $base = if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { $env:LOCALAPPDATA } else { $env:USERPROFILE }
    if ([string]::IsNullOrWhiteSpace($base)) { throw 'Cannot locate private Ramp audit state.' }
    Join-Path $base 'Zator\adaptive-ramp-audit.tsv'
}

function Read-AdaptiveRampAuditState {
    $path = Get-AdaptiveRampAuditStatePath
    $rows = @()
    $seen = @{}
    $last = 0L
    if (Test-Path -LiteralPath $path) {
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -gt 16384) {
            throw 'Adaptive Ramp audit state is not a bounded regular file.'
        }
        foreach ($line in Get-Content -LiteralPath $path -ErrorAction Stop) {
            $parts = $line -split "`t", 13
            if ($parts.Count -eq 2 -and $parts[0] -eq 'last' -and $parts[1] -match '^[0-9]{1,10}$') {
                $candidateLast = [long]$parts[1]
                $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                if ($candidateLast -ge ($now - 604800) -and $candidateLast -le ($now + 300)) { $last = $candidateLast }
                continue
            }
            if ($parts.Count -notin @(11, 12, 13) -or $parts[0] -ne 'target' -or $parts[1] -notmatch '^[0-9a-f]{64}$' -or
                $parts[2] -notmatch '^[0-9a-f]{64}$' -or $parts[3] -notmatch '^[0-9]{1,10}$' -or
                $parts[4] -notmatch '^[0-2]$' -or $parts[5] -notmatch '^[0-2]$' -or $parts[6] -notmatch '^[0-4]$' -or
                $parts[7] -notin @('pending', 'ramp_ok', 'plain_ok', 'inconclusive', 'conflict', 'plain_failed', 'plain_suspect', 'plain_confirmed') -or
                $parts[8] -notmatch '^[0-9]{1,10}$' -or $parts[9] -notmatch '^(|-|sha256:[a-f0-9]{64})$' -or
                $parts[10] -notmatch '^(0|[1-9][0-9]{0,2})$' -or
                ($parts.Count -eq 12 -and $parts[11] -notmatch '^([a-f0-9]{64})?$') -or
                ($parts.Count -eq 13 -and ($parts[11] -notmatch '^([a-f0-9]{64})?$' -or $parts[12] -notmatch '^([a-f0-9]{32}(,[a-f0-9]{32}){0,3})?$')) -or
                $seen.ContainsKey($parts[1]) -or $rows.Count -ge 128) { continue }
            $updated = [long]$parts[3]
            $due = [long]$parts[8]
            $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            if ($updated -lt ($now - 604800) -or $updated -gt ($now + 300) -or $due -gt ($now + 604800)) { continue }
            $seen[$parts[1]] = $true
            $rows += ,@{ Key = $parts[1]; GroupKey = $parts[2]; Updated = $updated; PlainSuccesses = [int]$parts[4];
                RampSuccesses = [int]$parts[5]; Step = [int]$parts[6]; Outcome = $parts[7]; NextAt = $due;
                CandidateSetVersion = $parts[9]; StrategyNumber = [int]$parts[10]; MediaUrlHash = if ($parts.Count -ge 12) { $parts[11] } else { '' };
                ProofTestIds = if ($parts.Count -eq 13) { $parts[12] } else { '' } }
        }
    }
    @{ Path = $path; Last = $last; Rows = $rows }
}

function Get-AdaptiveDueRampAuditTarget {
    param(
        [Parameter(Mandatory = $true)][object[]]$Targets,
        [Parameter(Mandatory = $true)][hashtable]$State,
        [long]$Now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(),
        [ValidateRange(60, 86400)][int]$CooldownSeconds = 300
    )
    if ($State.Last -gt 0 -and ($Now - $State.Last) -lt $CooldownSeconds) { return $null }
    $byKey = @{}
    $groupLastAttempt = @{}
    $groupAttemptCount = @{}
    foreach ($row in $State.Rows) {
        $byKey[$row.Key] = $row
        if ($row.GroupKey) {
            if (-not $groupLastAttempt.ContainsKey($row.GroupKey) -or $row.Updated -gt $groupLastAttempt[$row.GroupKey]) {
                $groupLastAttempt[$row.GroupKey] = [long]$row.Updated
            }
            $groupAttemptCount[$row.GroupKey] = 1 + [int]$groupAttemptCount[$row.GroupKey]
        }
    }
    $eligible = @()
    foreach ($target in ($Targets | Select-Object -First 128)) {
        if ($null -eq $target -or $target.provenance -ne 'tls-observed' -or $target.ramp_state -notin @('ramp_default', 'ramp_exempt') -or
            $target.media_recipe_available -notin @('available', 'unknown') -or
            $target.hostname -notmatch '^(?=.{1,253}$)([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)(\.([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?))*\.googlevideo\.com$' -or
            -not (Test-AdaptiveRampPublicIpv4 ([string]$target.destination_ip)) -or
            $target.scope -notmatch '^(default|mark:[1-9][0-9]{0,4})$' -or $target.group_id -notmatch '^gv1:(rr|r|exact):[a-z0-9.-]+$' -or
            $target.observed_at -notmatch '^[0-9]{1,10}$' -or [long]$target.observed_at -lt ($Now - 604800) -or
            [long]$target.observed_at -gt ($Now + 60)) { continue }
        if ($target.scope -match '^mark:' -and [int]($target.scope -replace '^mark:', '') -gt 65535) { continue }
        if ($target.dns_expires_at -and [long]$target.dns_expires_at -gt 0 -and [long]$target.dns_expires_at -le $Now) { continue }
        $key = Get-AdaptiveRampAuditKey -Hostname $target.hostname -DestinationIp $target.destination_ip -Scope $target.scope
        $saved = $byKey[$key]
        if ($null -ne $saved -and ($saved.NextAt -gt $Now -or ($Now - $saved.Updated) -lt $CooldownSeconds)) { continue }
        if ($null -ne $saved -and $saved.Outcome -eq 'plain_confirmed' -and $saved.NextAt -le $Now) { $saved = $null }
        $treatment = 'gv_tcp_ramp'
        if ($null -ne $saved -and $saved.Step -in @(1, 2)) { $treatment = 'gv_tcp_plain' }
        if ($null -ne $saved -and $saved.Step -eq 3) { $treatment = 'gv_tcp_ramp' }
        $groupId = Get-AdaptiveGooglevideoGroupId -Hostname $target.hostname
        $groupHash = Get-AdaptiveRampAuditGroupKey -GroupId $groupId
        $eligible += [pscustomobject]@{ Target = $target; Key = $key; GroupKey = $groupId;
            AuditPriority = if ($null -ne $saved -and $saved.Step -gt 0) { 0 } else { 1 };
            TreatmentVariant = $treatment; Step = if ($null -eq $saved) { 0 } else { [int]$saved.Step };
            PlainSuccesses = if ($null -eq $saved) { 0 } else { [int]$saved.PlainSuccesses };
            RampSuccesses = if ($null -eq $saved) { 0 } else { [int]$saved.RampSuccesses };
            CandidateSetVersion = if ($null -eq $saved) { '' } else { [string]$saved.CandidateSetVersion };
            StrategyNumber = if ($null -eq $saved) { 0 } else { [int]$saved.StrategyNumber };
            MediaUrlHash = if ($null -eq $saved) { '' } else { [string]$saved.MediaUrlHash };
            ProofTestIds = if ($null -eq $saved) { '' } else { [string]$saved.ProofTestIds };
            LastAttempt = if ($null -eq $saved) { 0L } else { [long]$saved.Updated };
            GroupLastAttempt = if ($groupLastAttempt.ContainsKey($groupHash)) { [long]$groupLastAttempt[$groupHash] } else { 0L };
            GroupAttemptCount = if ($groupAttemptCount.ContainsKey($groupHash)) { [int]$groupAttemptCount[$groupHash] } else { 0 } }
    }
    # Prefer under-sampled CDN families, but retain exact target cooldowns and
    # exact host/IP/scope proof identity. Grouping only changes queue order.
    $due = @($eligible | Sort-Object AuditPriority, GroupLastAttempt, GroupAttemptCount, LastAttempt,
        @{ Expression = { [long]$_.Target.observed_at } } | Select-Object -First 1)
    if ($due.Count -gt 0) { return $due[0] }
    return $null
}

function Save-AdaptiveRampAuditAttempt {
    param(
        [Parameter(Mandatory = $true)][hashtable]$State,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$GroupId,
        [ValidateSet('pending', 'ramp_ok', 'plain_ok', 'inconclusive', 'conflict', 'plain_failed', 'plain_suspect', 'plain_confirmed', 'plain_degraded_confirmed')][string]$Outcome,
        [ValidateRange(0, 2)][int]$PlainSuccesses = 0,
        [ValidateRange(0, 2)][int]$RampSuccesses = 0,
        [ValidateRange(0, 4)][int]$Step = 0,
        [string]$CandidateSetVersion = '',
        [string]$MediaUrlHash = '',
        [string]$ProofTestIds = '',
        [string]$ProofTestId = '',
        [ValidateRange(0, 999)][int]$StrategyNumber = 0,
        [ValidateRange(60, 86400)][int]$CooldownSeconds = 300
    )
    if ($State.Rows.Count -gt 128 -or $Key -notmatch '^[0-9a-f]{64}$' -or
        $GroupId -notmatch '^gv1:(rr|r|exact):[a-z0-9.-]+$' -or
        ($Step -gt 0 -and ($CandidateSetVersion -notmatch '^sha256:[a-f0-9]{64}$' -or $StrategyNumber -lt 1)) -or
        ($Step -eq 0 -and (($CandidateSetVersion -ne '' -and $CandidateSetVersion -notmatch '^sha256:[a-f0-9]{64}$') -or $StrategyNumber -lt 0)) -or
        ($Step -gt 0 -and $MediaUrlHash -notmatch '^[a-f0-9]{64}$') -or
        ($Step -eq 0 -and $MediaUrlHash -ne '' -and $MediaUrlHash -notmatch '^[a-f0-9]{64}$') -or
        ($Step -gt 0 -and ($ProofTestId -notmatch '^[a-f0-9]{32}$' -or ($ProofTestIds -ne '' -and $ProofTestIds -notmatch '^[a-f0-9]{32}(,[a-f0-9]{32}){0,2}$'))) -or
        ($Step -eq 0 -and ($ProofTestId -ne '' -or $ProofTestIds -ne ''))) {
        throw 'Invalid Ramp audit cursor.'
    }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $proofs = if ($Step -gt 0) { if ($ProofTestIds) { "$ProofTestIds,$ProofTestId" } else { $ProofTestId } } else { '' }
    if ($proofs -and $proofs -notmatch '^[a-f0-9]{32}(,[a-f0-9]{32}){0,3}$') { throw 'Invalid Ramp proof cursor.' }
    $retained = @($State.Rows | Where-Object Key -ne $Key | Sort-Object Updated -Descending | Select-Object -First 127)
    $retained += ,@{ Key = $Key; GroupKey = ''; Updated = $now; PlainSuccesses = $PlainSuccesses;
        RampSuccesses = $RampSuccesses; Step = $Step; Outcome = $Outcome; NextAt = $now + $CooldownSeconds;
        CandidateSetVersion = $CandidateSetVersion; StrategyNumber = $StrategyNumber; MediaUrlHash = $MediaUrlHash; ProofTestIds = $proofs }
    # Group keys are already a normalized local identifier; hash them without
    # ever persisting the observed hostname or address.
    $entry = $retained[-1]
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $entry.GroupKey = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($GroupId)))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
    $directory = Split-Path -Parent $State.Path
    [void](New-Item -ItemType Directory -Path $directory -Force)
    $lines = @("last`t$now") + @($retained | ForEach-Object {
        "target`t{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}`t{7}`t{8}`t{9}`t{10}`t{11}" -f $_.Key, $_.GroupKey, $_.Updated, $_.PlainSuccesses, $_.RampSuccesses, $_.Step, $_.Outcome, $_.NextAt, $_.CandidateSetVersion, $_.StrategyNumber, $_.MediaUrlHash, $_.ProofTestIds
    })
    $temporary = "$($State.Path).$PID.tmp"
    [IO.File]::WriteAllLines($temporary, $lines, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $State.Path -Force
    $State.Last = $now
    $State.Rows = $retained
}

function Get-AdaptiveRampAuditTransition {
    param(
        [Parameter(Mandatory = $true)][psobject]$Audit,
        [Parameter(Mandatory = $true)][AllowNull()][psobject]$Result,
        [string]$ProbeStatus = 'complete'
    )
    $empty = @{ Outcome = 'inconclusive'; Step = 0; PlainSuccesses = 0; RampSuccesses = 0; MediaUrlHash = '' }
    if ($ProbeStatus -ne 'complete' -or $null -eq $Result) { return $empty }
    $target = $Audit.Target
    $expectedTreatment = if ([int]$Audit.Step -in @(1, 2)) { 'gv_tcp_plain' } else { 'gv_tcp_ramp' }
    $sameTarget = $Audit.TreatmentVariant -eq $expectedTreatment -and $Result.target -and
        $Result.target.hostname -eq ([string]$target.hostname).ToLowerInvariant() -and
        $Result.target.destination_ip -eq [string]$target.destination_ip -and $Result.target.profile_id -eq 2 -and
        $Result.target.scope -eq [string]$target.scope -and $Result.strategy.local_number -eq [int]$Audit.StrategyNumber -and
        $Result.recipe_id -eq 'googlevideo-tcp-media-v1' -and $Result.treatment_variant -eq $expectedTreatment
    $mediaUrlHash = [string]$Result.media_url_sha256
    $sameMedia = $mediaUrlHash -match '^[a-f0-9]{64}$' -and
        ([string]::IsNullOrEmpty([string]$Audit.MediaUrlHash) -or [string]$Audit.MediaUrlHash -eq $mediaUrlHash)
    if (-not $sameTarget -or -not $sameMedia -or $Result.route_verified -ne $true -or $Result.queue_seen -ne $true -or
        $Result.strategy_ack_seen -ne $true) { return $empty }
    if ($expectedTreatment -eq 'gv_tcp_plain' -and $Audit.Step -eq 1 -and
        $target.ramp_state -eq 'ramp_exempt' -and $Result.syn_stage_confirmed -eq $false -and
        $Result.late_ack_stage_confirmed -eq $false -and $Result.overall -ne 'SUCCESS' -and
        $Result.reason -in @('media_insufficient', 'transport_timeout', 'target_unavailable')) {
        return @{ Outcome = 'plain_suspect'; Step = 3; PlainSuccesses = 0; RampSuccesses = [int]$Audit.RampSuccesses; MediaUrlHash = $mediaUrlHash }
    }
    if ($Result.overall -ne 'SUCCESS' -or $Result.transport -ne 'OK' -or $Result.application -ne 'OK') { return $empty }
    if ($expectedTreatment -eq 'gv_tcp_ramp') {
        if ($Result.syn_stage_confirmed -ne $true -or $Result.late_ack_stage_confirmed -ne $true) { return $empty }
        if ($Audit.Outcome -eq 'plain_suspect' -and $Audit.Step -eq 3) {
            return @{ Outcome = 'plain_degraded_confirmed'; Step = 0; PlainSuccesses = 0; RampSuccesses = 0; MediaUrlHash = $mediaUrlHash }
        }
        $plain = [int]$Audit.PlainSuccesses
        $ramp = [Math]::Min(2, [int]$Audit.RampSuccesses + 1)
        $step = [int]$Audit.Step + 1
        $outcome = 'ramp_ok'
    } else {
        if ($Result.syn_stage_confirmed -ne $false -or $Result.late_ack_stage_confirmed -ne $false) { return $empty }
        $plain = [Math]::Min(2, [int]$Audit.PlainSuccesses + 1)
        $ramp = [int]$Audit.RampSuccesses
        $step = [int]$Audit.Step + 1
        $outcome = 'plain_ok'
    }
    if ($step -eq 4 -and $plain -eq 2 -and $ramp -eq 2) { $outcome = 'plain_confirmed' }
    return @{ Outcome = $outcome; Step = $step; PlainSuccesses = $plain; RampSuccesses = $ramp; MediaUrlHash = $mediaUrlHash }
}

function Get-AdaptiveDeepSearchStatePath {
    if (-not [string]::IsNullOrWhiteSpace($DeepSearchStatePath)) { return $DeepSearchStatePath }
    $base = if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { $env:LOCALAPPDATA } else { $env:USERPROFILE }
    if ([string]::IsNullOrWhiteSpace($base)) { throw 'Cannot locate private adaptive deep-search state.' }
    Join-Path $base 'Zator\adaptive-deepsearch.tsv'
}

function Get-AdaptiveDeepSearchKey {
    param([string]$Hostname, [string]$DestinationIp, [int]$ProfileId, [string]$Scope, [string]$RecipeId = 'tls-http1-v1')
    if ($RecipeId -notin @('tls-http1-v1', 'googlevideo-tcp-media-v1')) { throw 'Invalid adaptive deep-search recipe.' }
    $bytes = [Text.Encoding]::UTF8.GetBytes(('{0}|{1}|{2}|{3}|{4}' -f $Hostname.ToLowerInvariant(), $DestinationIp, $ProfileId, $Scope, $RecipeId))
    $sha = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Read-AdaptiveDeepSearchState {
    $path = Get-AdaptiveDeepSearchStatePath
    $jobs = @()
    $seenKeys = @{}
    if (Test-Path -LiteralPath $path) {
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -gt 32768) {
            throw 'Adaptive deep-search state is not a bounded regular file.'
        }
        foreach ($line in Get-Content -LiteralPath $path -ErrorAction Stop) {
            $parts = $line -split "`t", 10
            if ($parts.Count -eq 9) { $parts = @($parts[0..7] + @('tls-http1-v1') + @($parts[8])) }
            if ($parts.Count -ne 10 -or $parts[0] -ne 'deep' -or $parts[1] -notmatch '^[0-9a-f]{64}$' -or
                $parts[2] -notmatch '^(?=.{1,253}$)([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)(\.([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?))*$' -or
                $parts[3] -notmatch '^([0-9]{1,3}\.){3}[0-9]{1,3}$' -or $parts[4] -notmatch '^[1-4]$' -or
                $parts[5] -notmatch '^(default|mark:[1-9][0-9]{0,4})$' -or $parts[6] -notmatch '^sha256:[0-9a-f]{64}$' -or
                $parts[7] -notmatch '^[1-9][0-9]{0,2}$' -or $parts[8] -notin @('tls-http1-v1', 'googlevideo-tcp-media-v1') -or
                $parts[9] -notmatch '^(0|[1-9][0-9]{0,2})\|[0-9]{1,10}$') { continue }
            $tail = $parts[9] -split '\|', 2
            $expectedKey = Get-AdaptiveDeepSearchKey -Hostname $parts[2] -DestinationIp $parts[3] -ProfileId ([int]$parts[4]) -Scope $parts[5] -RecipeId $parts[8]
            $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            if ([int]$tail[0] -gt [int]$parts[7] -or [long]$tail[1] -lt ($now - 604800) -or
                [long]$tail[1] -gt ($now + 3600) -or $expectedKey -ne $parts[1] -or $seenKeys.ContainsKey($parts[1]) -or $jobs.Count -ge 128) { continue }
            $seenKeys[$parts[1]] = $true
            $jobs += ,@{ Key = $parts[1]; Hostname = $parts[2]; DestinationIp = $parts[3]; ProfileId = [int]$parts[4];
                Scope = $parts[5]; CandidateSetVersion = $parts[6]; CandidateCount = [int]$parts[7]; RecipeId = $parts[8];
                Offset = [int]$tail[0]; NextAt = [long]$tail[1] }
        }
    }
    @{ Path = $path; Jobs = $jobs }
}

function Get-AdaptiveDueDeepSearchJob {
    param([hashtable]$State, [long]$Now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
    $due = @($State.Jobs | Where-Object { $_.NextAt -le $Now } | Sort-Object NextAt | Select-Object -First 1)
    if ($due.Count -gt 0) { return $due[0] }
    return $null
}

function Save-AdaptiveDeepSearchJob {
    param([hashtable]$State, [hashtable]$Job)
    if ($State.Jobs.Count -gt 128 -or $Job.Key -notmatch '^[0-9a-f]{64}$' -or
        $Job.RecipeId -notin @('tls-http1-v1', 'googlevideo-tcp-media-v1') -or
        $Job.CandidateSetVersion -notmatch '^sha256:[0-9a-f]{64}$' -or
        $Job.Offset -lt 0 -or $Job.Offset -ge $Job.CandidateCount -or $Job.CandidateCount -gt 999) {
        throw 'Invalid adaptive deep-search cursor.'
    }
    $retained = @($State.Jobs | Where-Object Key -ne $Job.Key | Select-Object -First 127)
    $retained += ,$Job
    $path = $State.Path
    $directory = Split-Path -Parent $path
    [void](New-Item -ItemType Directory -Path $directory -Force)
    $lines = @($retained | ForEach-Object {
        "deep`t{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}`t{7}`t{8}|{9}" -f $_.Key, $_.Hostname, $_.DestinationIp, $_.ProfileId,
            $_.Scope, $_.CandidateSetVersion, $_.CandidateCount, $_.RecipeId, $_.Offset, $_.NextAt
    })
    $temporary = "$path.$PID.tmp"
    [IO.File]::WriteAllLines($temporary, $lines, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $path -Force
    $State.Jobs = $retained
}

function Remove-AdaptiveDeepSearchJob {
    param([hashtable]$State, [string]$Key)
    $State.Jobs = @($State.Jobs | Where-Object Key -ne $Key)
    $path = $State.Path
    $temporary = "$path.$PID.tmp"
    $lines = @($State.Jobs | ForEach-Object {
        "deep`t{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}`t{7}`t{8}|{9}" -f $_.Key, $_.Hostname, $_.DestinationIp, $_.ProfileId,
            $_.Scope, $_.CandidateSetVersion, $_.CandidateCount, $_.RecipeId, $_.Offset, $_.NextAt
    })
    if ($lines.Count -eq 0) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue; return }
    [IO.File]::WriteAllLines($temporary, $lines, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $path -Force
}
