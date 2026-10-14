# Copies the extension straight into SketchUp's Plugins folder(s), no .rbz needed.
# Restart SketchUp afterwards to load the new version.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

$base = Join-Path $env:APPDATA 'SketchUp'
$targets = @()
if (Test-Path $base) {
    $targets = Get-ChildItem $base -Directory -Filter 'SketchUp 20*' |
        ForEach-Object { Join-Path $_.FullName 'SketchUp\Plugins' } |
        Where-Object { Test-Path $_ }
}
if (-not $targets) {
    Write-Host "Could not find a SketchUp Plugins folder under $base" -ForegroundColor Red
    Write-Host "Open SketchUp once, then run this again."
    exit 1
}

foreach ($t in $targets) {
    Copy-Item (Join-Path $root 'print_prep.rb') $t -Force
    $dest = Join-Path $t 'print_prep'
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    Copy-Item (Join-Path $root 'print_prep') $dest -Recurse -Force
    Write-Host "Installed into: $t" -ForegroundColor Green
}
Write-Host ""
Write-Host "Restart SketchUp, then open Extensions > Print Prep..."
