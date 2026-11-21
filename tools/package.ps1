param([string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $projectRoot 'dist' }
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
$manifest = Join-Path $projectRoot 'LumaUI.toc'
$lines = Get-Content -LiteralPath $manifest -Encoding UTF8
$versionLine = $lines | Where-Object { $_ -match '^## Version: ' } | Select-Object -First 1
$version = $versionLine -replace '^## Version:\s*', ''
if ($version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') { throw 'Invalid package version' }
$entries = @('LumaUI.toc', 'README.md', 'docs/EXTENSIONS.md', 'docs/IN_GAME_VALIDATION.md')
$entries += $lines | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
# LumaUI's own textures are loaded by path, so they are not listed in the TOC but
# they must ship with it.
$mediaRoot = Join-Path $projectRoot 'Media'
if (Test-Path -LiteralPath $mediaRoot -PathType Container) {
    $entries += Get-ChildItem -LiteralPath $mediaRoot -File | ForEach-Object { 'Media/' + $_.Name }
}
foreach ($entry in $entries) {
    $resolved = [IO.Path]::GetFullPath((Join-Path $projectRoot $entry))
    if (-not $resolved.StartsWith($projectRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw "Invalid package path: $entry" }
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { throw "Missing package file: $entry" }
}
[IO.Directory]::CreateDirectory($outputRoot) | Out-Null
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archivePath = Join-Path $outputRoot "LumaUI-$version.zip"
$stream = [IO.File]::Open($archivePath, [IO.FileMode]::Create)
$archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($entry in $entries) {
        $file = [IO.Path]::GetFullPath((Join-Path $projectRoot $entry))
        $archiveEntry = 'LumaUI/' + ($entry -replace '\\', '/')
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $file, $archiveEntry, [IO.Compression.CompressionLevel]::Optimal) | Out-Null
    }
} finally {
    $archive.Dispose()
    $stream.Dispose()
}
Write-Output $archivePath
