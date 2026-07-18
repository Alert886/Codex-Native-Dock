[CmdletBinding()]
param([switch]$RestartExisting)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
$sourceRoot = Split-Path -Parent $PSScriptRoot
$paths = Get-CndPaths
New-Item -ItemType Directory -Force -Path $paths.Root | Out-Null
$staged = Join-Path $paths.Root ('engine-new-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $staged | Out-Null
try {
  Copy-Item -LiteralPath (Join-Path $sourceRoot 'src') -Destination (Join-Path $staged 'src') -Recurse
  Copy-Item -LiteralPath (Join-Path $sourceRoot 'scripts') -Destination (Join-Path $staged 'scripts') -Recurse
  foreach ($file in @('README.md', 'LICENSE', 'Install-Codex-Native-Dock.cmd', 'Restore-Codex-Native-Dock.cmd')) {
    $candidate = Join-Path $sourceRoot $file
    if (Test-Path -LiteralPath $candidate) { Copy-Item -LiteralPath $candidate -Destination $staged }
  }
  if (Test-Path -LiteralPath $paths.Engine) {
    if (-not (Test-CndPathWithin $paths.Engine $paths.Root)) { throw 'Refusing to replace an unmanaged engine path.' }
    $old = Join-Path $paths.Root ('engine-old-' + [guid]::NewGuid().ToString('N'))
    Move-Item -LiteralPath $paths.Engine -Destination $old
    Move-Item -LiteralPath $staged -Destination $paths.Engine
    Remove-Item -LiteralPath $old -Recurse -Force
  } else {
    Move-Item -LiteralPath $staged -Destination $paths.Engine
  }
} finally {
  if ((Test-Path -LiteralPath $staged) -and (Test-CndPathWithin $staged $paths.Root)) {
    Remove-Item -LiteralPath $staged -Recurse -Force -ErrorAction SilentlyContinue
  }
}
$node = Get-CndNodeRuntime
if (-not $node) {
  Write-Host 'Node.js 22+ was not found. Downloading the official portable runtime and verifying SHA-256...'
  $node = Install-CndPortableNode
}
& $node --check (Join-Path $paths.Engine 'src\injector.mjs')
if ($LASTEXITCODE -ne 0) { throw 'The installed injector failed JavaScript syntax validation.' }
$null = Get-CndCodexInstall
$shell = New-Object -ComObject WScript.Shell
$powershell = (Get-Command powershell.exe).Source
$startScript = Join-Path $paths.Engine 'scripts\start.ps1'
foreach ($shortcutPath in @(
  (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Codex Native Dock.lnk'),
  (Join-Path ([Environment]::GetFolderPath('Programs')) 'Codex Native Dock.lnk')
)) {
  $shortcut = $shell.CreateShortcut($shortcutPath)
  $shortcut.TargetPath = $powershell
  $shortcut.Arguments = "-NoProfile -ExecutionPolicy RemoteSigned -File `"$startScript`" -PromptRestart"
  $shortcut.WorkingDirectory = $paths.Engine
  $shortcut.Description = 'Start Codex with Native Dock'
  $shortcut.Save()
}
Write-Host 'Managed files and shortcuts installed. Starting live verification...'
& (Join-Path $paths.Engine 'scripts\start.ps1') -PromptRestart -RestartExisting:$RestartExisting
Write-Host 'Installation complete. You can move or delete the extracted package.' -ForegroundColor Green
