[CmdletBinding()]
param(
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$sourceRoot = Join-Path $repoRoot 'browser-extension'
$expectedFiles = @('manifest.json', 'service-worker.js', 'options.html', 'options.js', 'popup.html', 'popup.js', 'style.css', 'README.md')
$manifest = Get-Content -LiteralPath (Join-Path $sourceRoot 'manifest.json') -Raw | ConvertFrom-Json
if ($manifest.manifest_version -ne 3 -or $manifest.version -notmatch '^\d+\.\d+\.\d+$') {
    throw 'Browser extension manifest version is invalid.'
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $repoRoot ("webui-src/dist/zator-browser-feedback-v{0}.zip" -f $manifest.version)
}
$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)
$outputDirectory = [System.IO.Path]::GetDirectoryName($OutputPath)
if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}
$temporaryPath = "$OutputPath.tmp.$PID.zip"

foreach ($file in $expectedFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot $file) -PathType Leaf)) {
        throw "Browser extension package is missing $file."
    }
}
$unexpected = Get-ChildItem -LiteralPath $sourceRoot -File | Where-Object { $_.Name -notin $expectedFiles }
if ($unexpected) { throw 'Refusing to package unreviewed files from browser-extension/.' }

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = $null
try {
    if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force }
    $archive = [System.IO.Compression.ZipFile]::Open($temporaryPath, [System.IO.Compression.ZipArchiveMode]::Create)
    foreach ($file in $expectedFiles) {
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $archive, (Join-Path $sourceRoot $file), $file, [System.IO.Compression.CompressionLevel]::Optimal
        ) | Out-Null
    }
    $archive.Dispose()
    $archive = $null

    $check = [System.IO.Compression.ZipFile]::OpenRead($temporaryPath)
    try {
        $actual = @($check.Entries | ForEach-Object FullName | Sort-Object)
        $expected = @($expectedFiles | Sort-Object)
        if (Compare-Object -ReferenceObject $expected -DifferenceObject $actual) {
            throw 'Packaged extension file list did not match the reviewed allowlist.'
        }
    } finally { $check.Dispose() }

    Move-Item -LiteralPath $temporaryPath -Destination $OutputPath -Force
    $hash = (Get-FileHash -LiteralPath $OutputPath -Algorithm SHA256).Hash.ToLowerInvariant()
    [System.IO.File]::WriteAllText("$OutputPath.sha256", "$hash  $([System.IO.Path]::GetFileName($OutputPath))`n", [System.Text.Encoding]::ASCII)
    Write-Output "Created $OutputPath"
    Write-Output "SHA256 $hash"
} finally {
    if ($archive) { $archive.Dispose() }
    if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force }
}
