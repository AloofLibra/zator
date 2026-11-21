# This repository, including its original source code and implementation, is licensed under GNU GPL v3.0; see LICENSE for the full terms. Redistribution, modification, and reuse must comply with that license and preserve applicable copyright and license notices. Unauthorized copying, including verbatim code copying or presenting this repository implementation or operating logic as your own, may be reported to the relevant hosting platforms.
# Bounded per-user cursor and pacing state for opt-in local exploration.
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
        foreach ($line in Get-Content -LiteralPath $path -ErrorAction Stop) {
            $parts = $line -split "`t", 5
            if ($parts.Count -in @(2, 3) -and $parts[0] -eq 'last' -and $parts[1] -match '^\d{1,10}$') {
                $last = [long]$parts[1]
                if ($parts.Count -eq 3 -and $parts[2] -match '^\d{1,3}$') { $jitter = [int]$parts[2] }
                continue
            }
            if ($parts.Count -eq 5 -and $parts[0] -eq 'target' -and $parts[1] -match '^[0-9a-f]{64}$' -and
                $parts[2] -match '^\d{1,3}$' -and $parts[3] -match '^[1-9]\d{0,2}$' -and $parts[4] -match '^\d{1,10}$') {
                $rows += ,@{ Key = $parts[1]; Offset = [int]$parts[2]; Count = [int]$parts[3]; Updated = [long]$parts[4] }
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
    param([hashtable]$State, [string]$TargetKey, [int]$NextOffset, [int]$Count, [ValidateRange(0, 600)][int]$JitterSeconds = 0)
    $directory = Split-Path -Parent $State.Path
    [void](New-Item -ItemType Directory -Path $directory -Force)
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("last`t$now`t$JitterSeconds")
    $retainedRows = @($State.Rows | Where-Object { [string]::IsNullOrWhiteSpace($TargetKey) -or $_.Key -ne $TargetKey } | Sort-Object Updated -Descending | Select-Object -First 255)
    foreach ($row in $retainedRows) {
        $lines.Add(("target`t{0}`t{1}`t{2}`t{3}" -f $row.Key, $row.Offset, $row.Count, $row.Updated))
    }
    if (-not [string]::IsNullOrWhiteSpace($TargetKey)) {
        $lines.Add(("target`t{0}`t{1}`t{2}`t{3}" -f $TargetKey, $NextOffset, $Count, $now))
    }
    $temporary = "$($State.Path).$PID.tmp"
    [IO.File]::WriteAllLines($temporary, $lines.ToArray(), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $State.Path -Force
}

function Get-ExploreMachineLoad {
    $processors = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop)
    $interfaces = @(Get-CimInstance -ClassName Win32_PerfFormattedData_Tcpip_NetworkInterface -ErrorAction Stop |
        Where-Object { $_.Name -notmatch 'Loopback|Teredo|isatap' })
    if ($processors.Count -eq 0 -or $interfaces.Count -eq 0) { throw 'Machine load counters are unavailable.' }
    $cpu = [Math]::Round((($processors | Measure-Object -Property LoadPercentage -Average).Average), 0)
    $network = [long](($interfaces | Measure-Object -Property BytesReceivedPersec -Sum).Sum +
        ($interfaces | Measure-Object -Property BytesSentPersec -Sum).Sum)
    @{ CpuPercent = [int]$cpu; NetworkBytesPerSecond = $network }
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
