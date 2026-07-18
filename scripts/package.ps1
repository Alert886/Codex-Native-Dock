$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$version = (Get-Content -LiteralPath (Join-Path $root 'package.json') -Raw | ConvertFrom-Json).version
$dist = Join-Path $root 'dist'
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('codex-native-dock-package-' + [guid]::NewGuid().ToString('N'))
$folderName = "Codex-Native-Dock-v$version"
$stage = Join-Path $temporary $folderName
New-Item -ItemType Directory -Force -Path $stage, $dist | Out-Null
function Get-PackageSha256([string]$Path) {
  $algorithm = [Security.Cryptography.SHA256]::Create()
  $stream = [IO.File]::OpenRead($Path)
  try { return ([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
  finally { $stream.Dispose(); $algorithm.Dispose() }
}
try {
  foreach ($directory in @('src', 'scripts')) {
    Copy-Item -LiteralPath (Join-Path $root $directory) -Destination (Join-Path $stage $directory) -Recurse
  }
  foreach ($file in @('Install-Codex-Native-Dock.cmd', 'Restore-Codex-Native-Dock.cmd', 'README.md', 'LICENSE', 'NOTICE.md', 'SECURITY.md')) {
    Copy-Item -LiteralPath (Join-Path $root $file) -Destination $stage
  }
  $manifest = Get-ChildItem -LiteralPath $stage -File -Recurse | ForEach-Object {
    [pscustomobject]@{
      path = $_.FullName.Substring($stage.Length + 1).Replace('\', '/')
      sha256 = Get-PackageSha256 $_.FullName
    }
  }
  $manifest | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stage 'MANIFEST.json') -Encoding utf8
  $archive = Join-Path $dist "Codex-Native-Dock-Windows-v$version.zip"
  Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
  Compress-Archive -LiteralPath $stage -DestinationPath $archive -CompressionLevel Optimal
  Write-Host $archive
} finally {
  if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
}
