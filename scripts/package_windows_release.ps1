param(
  [string]$Version = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

if ([string]::IsNullOrWhiteSpace($Version)) {
  $pubspecVersion = Select-String -Path "pubspec.yaml" -Pattern "^version:\s+(.+)$" |
    Select-Object -First 1
  if ($null -eq $pubspecVersion) {
    throw "Could not find version in pubspec.yaml."
  }
  $Version = $pubspecVersion.Matches[0].Groups[1].Value.Split("+")[0]
}

$ReleaseDir = Join-Path $RepoRoot "dist/releases/v$Version"
$BuildDir = Join-Path $RepoRoot "build/windows/x64/runner/Release"
$ZipName = "BenchVault-Windows-v$Version-prerelease.zip"
$ZipPath = Join-Path $ReleaseDir $ZipName
$ChecksumName = "SHA256SUMS-Windows.txt"
$ChecksumPath = Join-Path $ReleaseDir $ChecksumName

flutter build windows

if (!(Test-Path $BuildDir)) {
  throw "Windows release build output was not found at $BuildDir."
}

New-Item -ItemType Directory -Force -Path $ReleaseDir | Out-Null
if (Test-Path $ZipPath) {
  Remove-Item $ZipPath -Force
}

Compress-Archive -Path (Join-Path $BuildDir "*") -DestinationPath $ZipPath

$Hash = Get-FileHash -Algorithm SHA256 -Path $ZipPath
$Line = "$($Hash.Hash.ToLowerInvariant())  $ZipName"
Set-Content -Path $ChecksumPath -Value $Line -NoNewline

Write-Output $ZipPath
Write-Output $Line
