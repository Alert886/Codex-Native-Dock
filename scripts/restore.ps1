[CmdletBinding()]
param([switch]$RemoveFiles)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
$paths = Get-CndPaths
$state = Read-CndState
$node = if ($state -and $state.nodePath -and (Test-Path -LiteralPath "$($state.nodePath)")) { "$($state.nodePath)" } else { Get-CndNodeRuntime }
if ($state -and $node -and (Test-Path -LiteralPath "$($state.injectorPath)")) {
  & $node "$($state.injectorPath)" --remove --port ([int]$state.port) --browser-id "$($state.browserId)" 2>$null
}
$null = Stop-CndRecordedInjector $state
$shortcuts = @(
  (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Codex Native Dock.lnk'),
  (Join-Path ([Environment]::GetFolderPath('Programs')) 'Codex Native Dock.lnk')
)
foreach ($shortcut in $shortcuts) { Remove-Item -LiteralPath $shortcut -Force -ErrorAction SilentlyContinue }
Remove-Item -LiteralPath $paths.State -Force -ErrorAction SilentlyContinue
if ($RemoveFiles) {
  if (-not (Test-CndPathWithin $paths.Root $env:LOCALAPPDATA) -or [IO.Path]::GetFileName($paths.Root) -cne 'CodexNativeDock') {
    throw 'Refusing to remove an unexpected directory.'
  }
  Remove-Item -LiteralPath $paths.Root -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host 'Codex Native Dock was removed. Codex itself was not modified.' -ForegroundColor Green
