$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

function Get-CndPaths {
  $root = Join-Path $env:LOCALAPPDATA 'CodexNativeDock'
  [pscustomobject]@{
    Root = $root
    Engine = Join-Path $root 'engine'
    Runtime = Join-Path $root 'runtime'
    State = Join-Path $root 'state.json'
    Log = Join-Path $root 'injector.log'
    ErrorLog = Join-Path $root 'injector-error.log'
  }
}

function Assert-CndPort([int]$Port) {
  if ($Port -lt 1024 -or $Port -gt 65535) { throw 'Port must be between 1024 and 65535.' }
}

function Test-CndPathWithin([string]$Path, [string]$Root) {
  $resolvedPath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
  $resolvedRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
  return $resolvedPath.StartsWith($resolvedRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or
    $resolvedPath.Equals($resolvedRoot, [StringComparison]::OrdinalIgnoreCase)
}

function Get-CndNodeMajor([string]$NodePath) {
  try {
    $value = & $NodePath --version 2>$null
    if ($LASTEXITCODE -ne 0 -or "$value" -notmatch '^v(?<major>\d+)\.') { return 0 }
    return [int]$Matches.major
  } catch { return 0 }
}

function Get-CndNodeRuntime {
  $command = Get-Command node -ErrorAction SilentlyContinue
  if ($command -and (Get-CndNodeMajor $command.Source) -ge 22) { return $command.Source }
  $paths = Get-CndPaths
  $portable = Get-ChildItem -LiteralPath $paths.Runtime -Filter node.exe -File -Recurse -ErrorAction SilentlyContinue |
    Select-Object -First 1
  if ($portable -and (Get-CndNodeMajor $portable.FullName) -ge 22) { return $portable.FullName }
  return $null
}

function Install-CndPortableNode {
  $paths = Get-CndPaths
  New-Item -ItemType Directory -Force -Path $paths.Root | Out-Null
  $architecture = if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq [Runtime.InteropServices.Architecture]::Arm64) { 'arm64' } else { 'x64' }
  $base = 'https://nodejs.org/dist/latest-v22.x'
  $checksums = (Invoke-WebRequest -UseBasicParsing -Uri "$base/SHASUMS256.txt" -TimeoutSec 30).Content
  $match = [regex]::Match($checksums, "(?m)^(?<sha>[a-f0-9]{64})\s+(?<name>node-v22\.[0-9.]+-win-$architecture\.zip)$")
  if (-not $match.Success) { throw "No official Node.js 22 Windows $architecture archive was listed." }
  $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("codex-native-dock-node-" + [guid]::NewGuid().ToString('N'))
  $archive = Join-Path $temporaryRoot $match.Groups['name'].Value
  $expanded = Join-Path $temporaryRoot 'expanded'
  New-Item -ItemType Directory -Force -Path $expanded | Out-Null
  try {
    Invoke-WebRequest -UseBasicParsing -Uri "$base/$($match.Groups['name'].Value)" -OutFile $archive -TimeoutSec 180
    $actual = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -cne $match.Groups['sha'].Value) { throw 'The downloaded Node.js SHA-256 did not match nodejs.org.' }
    Expand-Archive -LiteralPath $archive -DestinationPath $expanded -Force
    $nodeRoot = Get-ChildItem -LiteralPath $expanded -Directory | Select-Object -First 1
    if (-not $nodeRoot -or -not (Test-Path -LiteralPath (Join-Path $nodeRoot.FullName 'node.exe'))) {
      throw 'The official Node.js archive did not contain node.exe.'
    }
    $newRuntime = Join-Path $paths.Root ('runtime-new-' + [guid]::NewGuid().ToString('N'))
    Move-Item -LiteralPath $nodeRoot.FullName -Destination $newRuntime
    if (Test-Path -LiteralPath $paths.Runtime) {
      if (-not (Test-CndPathWithin $paths.Runtime $paths.Root)) { throw 'Refusing to replace an unmanaged runtime path.' }
      Remove-Item -LiteralPath $paths.Runtime -Recurse -Force
    }
    Move-Item -LiteralPath $newRuntime -Destination $paths.Runtime
  } finally {
    if ((Test-Path -LiteralPath $temporaryRoot) -and (Test-CndPathWithin $temporaryRoot ([IO.Path]::GetTempPath()))) {
      Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
  $node = Join-Path $paths.Runtime 'node.exe'
  if ((Get-CndNodeMajor $node) -lt 22) { throw 'Portable Node.js 22 validation failed.' }
  return $node
}

function Get-CndCodexInstall {
  $package = Get-AppxPackage -Name OpenAI.Codex | Sort-Object Version -Descending | Select-Object -First 1
  if (-not $package) { throw 'The official OpenAI Codex Windows app is not installed.' }
  $manifestPath = Join-Path $package.InstallLocation 'AppxManifest.xml'
  [xml]$manifest = Get-Content -LiteralPath $manifestPath -Raw
  $application = @($manifest.Package.Applications.Application) |
    Where-Object { "$($_.Executable)" -replace '/', '\' -ieq 'app\ChatGPT.exe' } | Select-Object -First 1
  if (-not $application -or "$($application.Id)" -notmatch '^[A-Za-z0-9._-]{1,64}$') {
    throw 'The registered Codex application identity could not be validated.'
  }
  $executable = Join-Path $package.InstallLocation 'app\ChatGPT.exe'
  if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { throw 'The registered Codex executable was not found.' }
  [pscustomobject]@{
    Executable = $executable
    PackageRoot = $package.InstallLocation
    PackageFullName = $package.PackageFullName
    PackageFamilyName = $package.PackageFamilyName
    AppUserModelId = "$($package.PackageFamilyName)!$($application.Id)"
    Version = "$($package.Version)"
  }
}

function Initialize-CndPackageLauncher {
  if ('CodexNativeDock.PackageLauncher' -as [type]) { return }
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace CodexNativeDock {
  [ComImport, Guid("2e941141-7f97-4756-ba1d-9decde894a3d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IApplicationActivationManager {
    [PreserveSig] int ActivateApplication(
      [MarshalAs(UnmanagedType.LPWStr)] string appUserModelId,
      [MarshalAs(UnmanagedType.LPWStr)] string arguments,
      uint options,
      out uint processId);
  }
  [ComImport, Guid("45ba127d-10a8-46ea-8ab7-56ea9078943c")]
  class ApplicationActivationManager {}
  public static class PackageLauncher {
    public static uint Launch(string appUserModelId, string arguments) {
      var manager = (IApplicationActivationManager)new ApplicationActivationManager();
      try {
        uint processId;
        int result = manager.ActivateApplication(appUserModelId, arguments ?? "", 0, out processId);
        Marshal.ThrowExceptionForHR(result);
        return processId;
      } finally {
        if (Marshal.IsComObject(manager)) Marshal.FinalReleaseComObject(manager);
      }
    }
  }
}
'@
}

function Start-CndCodex([object]$Codex, [string[]]$Arguments) {
  Initialize-CndPackageLauncher
  foreach ($argument in $Arguments) {
    if ($argument -match '["\r\n]') { throw 'Unsafe Codex launch argument.' }
  }
  $line = ($Arguments -join ' ')
  return [CodexNativeDock.PackageLauncher]::Launch($Codex.AppUserModelId, $line)
}

function Get-CndCodexProcesses([object]$Codex) {
  @(Get-CimInstance Win32_Process -Filter "Name = 'ChatGPT.exe'" -ErrorAction SilentlyContinue | Where-Object {
    $_.ExecutablePath -and [IO.Path]::GetFullPath($_.ExecutablePath).Equals(
      [IO.Path]::GetFullPath($Codex.Executable), [StringComparison]::OrdinalIgnoreCase)
  })
}

function Get-CndBrowserIdentity([int]$Port) {
  Assert-CndPort $Port
  try {
    $version = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/version" -TimeoutSec 2 -MaximumRedirection 0
    $uri = [Uri]"$($version.webSocketDebuggerUrl)"
    if ($uri.Scheme -ne 'ws' -or $uri.Host -notin @('127.0.0.1', 'localhost', '::1') -or $uri.Port -ne $Port -or
      $uri.UserInfo -or $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -notmatch '^/devtools/browser/(?<id>[A-Za-z0-9._:-]{1,256})$') {
      return $null
    }
    $targets = @(Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/list" -TimeoutSec 2 -MaximumRedirection 0)
    $page = $targets | Where-Object { $_.type -eq 'page' -and $_.url -in @('app://-/index.html', 'app://codex/') } | Select-Object -First 1
    if (-not $page) { return $null }
    return $Matches.id
  } catch { return $null }
}

function Find-CndEndpoint([int]$PreferredPort = 9341) {
  $paths = Get-CndPaths
  $candidates = [Collections.Generic.List[int]]::new()
  if (Test-Path -LiteralPath $paths.State) {
    try { $candidates.Add([int]((Get-Content -LiteralPath $paths.State -Raw | ConvertFrom-Json).port)) } catch {}
  }
  $candidates.Add($PreferredPort)
  foreach ($value in 9335..9355) { $candidates.Add($value) }
  foreach ($port in ($candidates | Select-Object -Unique)) {
    if ($port -lt 1024 -or $port -gt 65535) { continue }
    $identity = Get-CndBrowserIdentity $port
    if ($identity) { return [pscustomobject]@{ Port = $port; BrowserId = $identity } }
  }
  return $null
}

function Test-CndPortFree([int]$Port) {
  try {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port)
    $listener.Start(); $listener.Stop(); return $true
  } catch { return $false }
}

function Read-CndState {
  $path = (Get-CndPaths).State
  if (-not (Test-Path -LiteralPath $path)) { return $null }
  try { Get-Content -LiteralPath $path -Raw | ConvertFrom-Json } catch { $null }
}

function Test-CndRecordedInjector([object]$State) {
  if (-not $State -or -not $State.injectorPid -or -not $State.injectorPath -or -not $State.injectorStartedAt) { return $false }
  try {
    $process = Get-CimInstance Win32_Process -Filter "ProcessId = $([int]$State.injectorPid)"
    if (-not $process -or $process.Name -ine 'node.exe') { return $false }
    $expected = [IO.Path]::GetFullPath("$($State.injectorPath)")
    if (-not $process.CommandLine -or $process.CommandLine.IndexOf($expected, [StringComparison]::OrdinalIgnoreCase) -lt 0 -or
      $process.CommandLine -notmatch '(?i)--watch') { return $false }
    $actualStart = (Get-Process -Id ([int]$State.injectorPid)).StartTime.ToUniversalTime()
    $savedStart = [DateTime]::Parse("$($State.injectorStartedAt)").ToUniversalTime()
    return [Math]::Abs(($actualStart - $savedStart).TotalSeconds) -lt 2
  } catch { return $false }
}

function Stop-CndRecordedInjector([object]$State) {
  if (Test-CndRecordedInjector $State) {
    Stop-Process -Id ([int]$State.injectorPid) -Force
    return $true
  }
  return $false
}
