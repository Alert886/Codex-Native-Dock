$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$archive = Join-Path $root 'dist\Codex-Native-Dock-Windows-v0.1.0.zip'
if (-not (Test-Path -LiteralPath $archive)) { throw 'Build the Windows archive before this test.' }
$testRoot = Join-Path $env:TEMP ('Codex Native Dock package test ' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
  Expand-Archive -LiteralPath $archive -DestinationPath $testRoot
  $packageRoot = Get-ChildItem -LiteralPath $testRoot -Directory | Select-Object -First 1
  $manifest = Get-Content -LiteralPath (Join-Path $packageRoot.FullName 'MANIFEST.json') -Raw | ConvertFrom-Json
  foreach ($entry in $manifest) {
    $file = Join-Path $packageRoot.FullName ($entry.path -replace '/', '\')
    $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -cne $entry.sha256) { throw "Manifest mismatch: $($entry.path)" }
  }
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $packageRoot.FullName 'scripts\install.ps1')
  if ($LASTEXITCODE -ne 0) { throw "Extracted installer exited with $LASTEXITCODE." }
  powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File "$env:LOCALAPPDATA\CodexNativeDock\engine\scripts\verify.ps1"
  if ($LASTEXITCODE -ne 0) { throw "Installed runtime verification exited with $LASTEXITCODE." }
  Write-Host "Extracted package PASS ($($manifest.Count) files)" -ForegroundColor Green
} finally {
  $resolved = [IO.Path]::GetFullPath($testRoot)
  $tempPrefix = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
  if ($resolved.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -and
      [IO.Path]::GetFileName($resolved).StartsWith('Codex Native Dock package test ', [StringComparison]::Ordinal)) {
    Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
  }
}
