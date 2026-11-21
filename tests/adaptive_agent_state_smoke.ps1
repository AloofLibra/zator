$ErrorActionPreference = 'Stop'
$temp = Join-Path $env:TEMP ('zator-adaptive-state-' + [guid]::NewGuid().ToString('N'))
$ExploreStatePath = Join-Path $temp 'adaptive-explore.tsv'
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
    $key = Get-ExploreTargetKey -TargetHost 'CDN.Example.org' -TargetIp '93.184.216.34' -TargetProfile 1 -TargetScope 'default'
    $sameKey = Get-ExploreTargetKey -TargetHost 'cdn.example.org' -TargetIp '93.184.216.34' -TargetProfile 1 -TargetScope 'default'
    $otherIpKey = Get-ExploreTargetKey -TargetHost 'cdn.example.org' -TargetIp '93.184.216.35' -TargetProfile 1 -TargetScope 'default'
    if ($key -notmatch '^[0-9a-f]{64}$' -or $key -ne $sameKey -or $key -eq $otherIpKey) {
        throw 'Exploration tuple key is not stable and IP-specific.'
    }

    $state = Read-ExploreState
    Save-ExploreState -State $state -TargetKey $key -NextOffset 2 -Count 10 -JitterSeconds 17
    $state = Read-ExploreState
    $row = @($state.Rows | Where-Object Key -eq $key)
    if ($state.Last -le 0 -or $state.Jitter -ne 17 -or $row.Count -ne 1 -or $row[0].Offset -ne 2 -or $row[0].Count -ne 10) {
        throw 'Exploration cursor or global pacing timestamp did not persist.'
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
    if ($row.Count -ne 1 -or $row[0].Offset -ne 2) { throw 'Urgent-test pacing update discarded the exploration cursor.' }
    Write-Output 'adaptive agent exploration state smoke: ok'
} finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
