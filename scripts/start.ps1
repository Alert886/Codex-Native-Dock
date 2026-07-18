[CmdletBinding()]
param(
  [int]$Port = 9341,
  [switch]$RestartExisting,
  [switch]$PromptRestart
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
$paths = Get-CndPaths
if (-not (Test-Path -LiteralPath (Join-Path $paths.Engine 'src\injector.mjs'))) {
  throw 'Codex Native Dock is not installed. Run Install-Codex-Native-Dock.cmd first.'
}
$node = Get-CndNodeRuntime
if (-not $node) { throw 'Node.js 22 or newer is required. Re-run the installer to add the verified portable runtime.' }
$codex = Get-CndCodexInstall
$endpoint = Find-CndEndpoint -PreferredPort $Port
if (-not $endpoint) {
  $running = @(Get-CndCodexProcesses $codex)
  if ($running.Count -gt 0) {
    $allowed = [bool]$RestartExisting
    if (-not $allowed -and $PromptRestart) {
      Add-Type -AssemblyName PresentationFramework
      $answer = [Windows.MessageBox]::Show(
        'Codex must restart once to enable the quick dock. Unsent input may be lost. Restart now?',
        'Codex Native Dock', 'YesNo', 'Warning')
      $allowed = $answer -eq 'Yes'
    }
    if (-not $allowed) { throw 'Codex is already open without a debugging endpoint. Close it first or approve the restart.' }
    foreach ($process in $running) { Stop-Process -Id ([int]$process.ProcessId) -Force }
    Start-Sleep -Milliseconds 900
  }
  $selected = $Port
  if (-not (Test-CndPortFree $selected)) {
    $selected = 9341..9355 | Where-Object { Test-CndPortFree $_ } | Select-Object -First 1
  }
  if (-not $selected) { throw 'No free loopback debugging port was found from 9341 through 9355.' }
  $null = Start-CndCodex $codex @('--remote-debugging-address=127.0.0.1', "--remote-debugging-port=$selected")
  $deadline = (Get-Date).AddSeconds(45)
  do {
    Start-Sleep -Milliseconds 400
    $identity = Get-CndBrowserIdentity $selected
  } until ($identity -or (Get-Date) -ge $deadline)
  if (-not $identity) { throw "Codex did not expose its verified loopback endpoint on port $selected." }
  $endpoint = [pscustomobject]@{ Port = $selected; BrowserId = $identity }
}
$previous = Read-CndState
$null = Stop-CndRecordedInjector $previous
$injector = Join-Path $paths.Engine 'src\injector.mjs'
$argumentLine = "`"$injector`" --watch --port $($endpoint.Port) --browser-id $($endpoint.BrowserId)"
$process = Start-Process -FilePath $node -ArgumentList $argumentLine -WindowStyle Hidden -RedirectStandardOutput $paths.Log `
  -RedirectStandardError $paths.ErrorLog -PassThru
Start-Sleep -Milliseconds 900
if ($process.HasExited) {
  $details = if (Test-Path -LiteralPath $paths.ErrorLog) { Get-Content -LiteralPath $paths.ErrorLog -Raw } else { '' }
  throw "The injector stopped during startup. $details"
}
$startedAt = (Get-Process -Id $process.Id).StartTime.ToUniversalTime().ToString('o')
$state = [ordered]@{
  schemaVersion = 1
  version = '0.1.0'
  port = [int]$endpoint.Port
  browserId = "$($endpoint.BrowserId)"
  injectorPid = $process.Id
  injectorStartedAt = $startedAt
  injectorPath = $injector
  nodePath = $node
  codexExe = $codex.Executable
  codexVersion = $codex.Version
  createdAt = [DateTime]::UtcNow.ToString('o')
}
$state | ConvertTo-Json | Set-Content -LiteralPath $paths.State -Encoding utf8
Start-Sleep -Seconds 2
& $node $injector --verify --port $endpoint.Port --browser-id $endpoint.BrowserId
if ($LASTEXITCODE -ne 0) { throw 'Live verification failed. See the injector logs in %LOCALAPPDATA%\CodexNativeDock.' }
Write-Host 'Codex Native Dock is running and verified.' -ForegroundColor Green
