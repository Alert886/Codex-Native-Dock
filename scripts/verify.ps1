$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
$paths = Get-CndPaths
$state = Read-CndState
if (-not $state) { throw 'No installed state was found.' }
$node = "$($state.nodePath)"
if ((Get-CndNodeMajor $node) -lt 22) { throw 'The recorded Node.js runtime is unavailable.' }
if (-not (Test-CndRecordedInjector $state)) { throw 'The recorded injector is not running with the expected identity.' }
& $node "$($state.injectorPath)" --verify --port ([int]$state.port) --browser-id "$($state.browserId)"
if ($LASTEXITCODE -ne 0) { throw 'Live verification failed.' }
Write-Host 'Verification PASS' -ForegroundColor Green
