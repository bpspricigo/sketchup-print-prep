# Builds print_prep.rbz in the repo root.
# SketchUp needs forward slashes inside the zip, so we don't use Compress-Archive
# (Windows PowerShell 5.1 writes backslashes, and SketchUp then fails to install).
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$out  = Join-Path $root 'print_prep.rbz'

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

if (Test-Path $out) { Remove-Item $out -Force }
$zip = [System.IO.Compression.ZipFile]::Open($out, 'Create')
try {
    $files  = @(Get-Item (Join-Path $root 'print_prep.rb'))
    $files += @(Get-ChildItem (Join-Path $root 'print_prep') -Recurse -File)
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($root.TrimEnd('\', '/').Length + 1) -replace '\\', '/'
        [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $f.FullName, $rel)
        Write-Host "  + $rel"
    }
} finally {
    $zip.Dispose()
}
Write-Host ""
Write-Host "Built: $out" -ForegroundColor Green
Write-Host "Install it in SketchUp: Extensions > Extension Manager > Install Extension"
