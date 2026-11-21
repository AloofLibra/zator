$ErrorActionPreference = 'Stop'
$temp = Join-Path $env:TEMP ('zator-fastsearch-' + [guid]::NewGuid().ToString('N'))
$DeepSearchStatePath = Join-Path $temp 'deepsearch.tsv'
$script:ProbeCalls = @()
$script:ProbeSuccess = $null
$script:ProbeCooldown = $null
$script:CandidateSetVersion = 'sha256:' + ('c' * 64)
try {
    New-Item -ItemType Directory -Path $temp | Out-Null
    . (Join-Path $PSScriptRoot '..\tools\adaptive-agent-state.ps1')
    . (Join-Path $PSScriptRoot '..\tools\adaptive-agent-stats.ps1')

    function Get-AdaptiveRankingHint { param($Enabled, $ProfileId, $Endpoint, $IdentityRequest) @() }
    function Invoke-AdaptiveApi {
        param([hashtable]$Body)
        if ($Body.action -ne 'candidates') { throw "Unexpected API action: $($Body.action)" }
        $all = @(1..10)
        if (-not $Body.ContainsKey('offset')) {
            return [pscustomobject]@{
                schema_version = 1; status = 'ready'; profile_id = 1; scope = 'default'; protocol = 'tls'; recipe_id = 'tls-http1-v1'
                profile_strategy_count = 11; candidate_count = 11; candidate_set_version = $script:CandidateSetVersion
                candidate_offset = 0; candidate_numbers = $all; source = 'local-profile-order'
            }
        }
        if ($Body.offset -eq 10 -and $Body.limit -eq 1 -and $Body.candidate_set_version -eq $script:CandidateSetVersion) {
            return [pscustomobject]@{
                schema_version = 1; status = 'ready'; profile_id = 1; scope = 'default'; protocol = 'tls'; recipe_id = 'tls-http1-v1'
                profile_strategy_count = 11; candidate_count = 11; candidate_set_version = $script:CandidateSetVersion
                candidate_offset = 10; candidate_numbers = @(11); source = 'local-profile-order'
            }
        }
        throw "Unexpected candidate page: offset=$($Body.offset), limit=$($Body.limit)."
    }
    function Invoke-AdaptiveStrategyCandidate {
        param([int]$Candidate)
        $script:ProbeCalls += $Candidate
        if ($Candidate -eq $script:ProbeCooldown) {
            return [pscustomobject]@{ strategy = $Candidate; overall = 'INCONCLUSIVE'; route_verified = $true; reason = 'rate_limited' }
        }
        if ($Candidate -eq $script:ProbeSuccess) {
            return [pscustomobject]@{ strategy = $Candidate; overall = 'SUCCESS'; route_verified = $true; reason = 'probe_ok' }
        }
        return [pscustomobject]@{ strategy = $Candidate; overall = 'INCONCLUSIVE'; route_verified = $true; reason = 'timeout' }
    }

    $agentPath = Join-Path $PSScriptRoot '..\tools\adaptive-agent.ps1'
    $tokens = $null; $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $agentPath), [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw ($parseErrors | ForEach-Object Message | Out-String) }
    $node = $ast.Find({
        param($item)
        $item -is [System.Management.Automation.Language.IfStatementAst] -and $item.Extent.Text -match '^if \(\$FastSearch\)'
    }, $true)
    if (-not $node) { throw 'FastSearch implementation block was not found.' }
    $script:FastSearchBlock = [scriptblock]::Create($node.Extent.Text)
    function Invoke-FastSearchHarness { & $script:FastSearchBlock }

    $Router = [uri]'http://192.168.1.1'; $Token = 'a' * 64; $ApiPath = '/cgi-bin/adaptive.cgi'
    $Hostname = 'cdn.example.org'; $DestinationIp = '93.184.216.34'; $ProfileId = 1; $Scope = 'default'; $recipeId = 'tls-http1-v1'
    $FastSearch = $true; $ResumeDeepSearch = $false; $DeepSearch = $false; $DeepSearchMaxCandidates = 20
    $MaxCandidates = 10; $CandidatePauseSeconds = 0; $UseSharedRankings = $false
    $AdaptiveRankingEndpoint = [uri]'https://stats.example/rankings'; $UploadStatistics = $false
    $StatisticsEndpoint = [uri]'https://stats.example/results'; $AdaptiveStatsStatePath = ''
    $AdaptiveRankingCachePath = ''

    $first = (Invoke-FastSearchHarness | Out-String).Trim() | ConvertFrom-Json
    $state = Read-AdaptiveDeepSearchState
    if ($first.status -ne 'deep_scheduled' -or $first.duration_ms -lt 0 -or $null -ne $first.time_to_first_success_ms -or
        $state.Jobs.Count -ne 1 -or $state.Jobs[0].Offset -ne 10 -or
        $script:ProbeCalls.Count -ne 11 -or $script:ProbeCalls[0] -ne 0 -or $script:ProbeCalls[-1] -ne 10) {
        throw "FastSearch did not schedule its untested tail: result=$($first | ConvertTo-Json -Compress) calls=$($script:ProbeCalls -join ',')"
    }

    $script:ProbeCalls = @(); $script:ProbeSuccess = 11; $ResumeDeepSearch = $true; $DeepSearchMaxCandidates = 1
    $second = (Invoke-FastSearchHarness | Out-String).Trim() | ConvertFrom-Json
    if ($second.status -ne 'found' -or $second.winner_strategy -ne 11 -or $second.duration_ms -lt 0 -or
        $second.time_to_first_success_ms -lt 0 -or
        ($script:ProbeCalls -join ',') -ne '11' -or (Read-AdaptiveDeepSearchState).Jobs.Count -ne 0) {
        throw "Resumed DeepSearch repeated fast candidates or failed to clear its completed cursor: result=$($second | ConvertTo-Json -Compress) calls=$($script:ProbeCalls -join ',')"
    }

    $script:ProbeCalls = @(); $script:ProbeSuccess = $null; $script:ProbeCooldown = 3; $ResumeDeepSearch = $false
    $cooldown = (Invoke-FastSearchHarness | Out-String).Trim() | ConvertFrom-Json
    $state = Read-AdaptiveDeepSearchState
    if ($cooldown.status -ne 'stopped_rate_limit' -or $state.Jobs.Count -ne 1 -or
        $state.Jobs[0].Offset -ne 2 -or $state.Jobs[0].NextAt -lt ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 800)) {
        throw "Rate limit did not persist a target-scoped cooldown cursor: result=$($cooldown | ConvertTo-Json -Compress)"
    }
    'adaptive FastSearch and resumable DeepSearch smoke: ok'
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
