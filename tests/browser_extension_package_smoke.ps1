$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$tempZip = Join-Path $env:TEMP ("zator-browser-extension-{0}.zip" -f [guid]::NewGuid().ToString('N'))
try {
    & (Join-Path $repoRoot 'tools/package-browser-extension.ps1') -OutputPath $tempZip | Out-Null
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw 'Extension packager exited unsuccessfully.' }
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($tempZip)
    try {
        $files = @($archive.Entries | ForEach-Object FullName | Sort-Object)
        $expected = @('README.md', 'manifest.json', 'options.html', 'options.js', 'popup.html', 'popup.js', 'service-worker.js', 'style.css')
        if (Compare-Object $expected $files) { throw 'Extension archive contents differ from the package allowlist.' }
        if ($archive.Entries | Where-Object { $_.FullName -match 'token|secret|key' }) { throw 'Extension archive contains a credential-like file.' }
    } finally { $archive.Dispose() }
    if (-not (Test-Path -LiteralPath "$tempZip.sha256" -PathType Leaf)) { throw 'Extension package checksum is missing.' }
    Write-Output 'browser extension package smoke: PASS'
} finally {
    foreach ($path in @($tempZip, "$tempZip.sha256")) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
}
