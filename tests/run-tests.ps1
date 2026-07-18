$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
foreach ($script in Get-ChildItem -LiteralPath (Join-Path $root 'scripts') -Filter '*.ps1') {
  $null = [scriptblock]::Create((Get-Content -LiteralPath $script.FullName -Raw))
}
$common = Get-Content -LiteralPath (Join-Path $root 'scripts\common.ps1') -Raw
$installer = Get-Content -LiteralPath (Join-Path $root 'scripts\install.ps1') -Raw
$restore = Get-Content -LiteralPath (Join-Path $root 'scripts\restore.ps1') -Raw
if ($common -notmatch 'https://nodejs\.org/dist/latest-v22\.x') { throw 'Official Node.js source is missing.' }
if ($common -notmatch 'Get-FileHash.+SHA256') { throw 'Portable Node.js checksum verification is missing.' }
if ($common -notmatch 'remote-debugging-address=127\.0\.0\.1' -and
    (Get-Content -LiteralPath (Join-Path $root 'scripts\start.ps1') -Raw) -notmatch 'remote-debugging-address=127\.0\.0\.1') {
  throw 'Loopback-only debugging is missing.'
}
foreach ($content in @($common, $installer, $restore)) {
  if ($content -match '(?i)app\.asar|Set-Content.+WindowsApps|Copy-Item.+WindowsApps') {
    throw 'An installer script appears to modify Codex application files.'
  }
}
if ($restore -notmatch 'Stop-CndRecordedInjector' -or $common -notmatch 'Test-CndRecordedInjector') {
  throw 'Exact injector identity cleanup is missing.'
}
Write-Host 'PowerShell contract tests PASS' -ForegroundColor Green
