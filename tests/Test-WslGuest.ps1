<#
.SYNOPSIS
  Developer smoke test for guest command resolution on a real Windows WSL host.
.DESCRIPTION
  Starts the target if needed, but does not trim, terminate, compact or change tasks.
  Run from a Windows local copy of this repository, outside the guest SSH session.
.PARAMETER Distro
  Registered WSL distribution name, for example Ubuntu26.04 or NixOS.
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-WslGuest.ps1 -Distro NixOS
#>
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Distro)
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'This smoke test requires a Windows WSL host.' }
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'internal/Wsl-Guest.ps1')
$wsl = Join-Path $env:SystemRoot 'System32/wsl.exe'
$previousEncoding = [Console]::OutputEncoding
try {
  [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
  foreach ($command in @(@('true'), @('sleep', '0'), @('df', '-B1', '--output=used,size', '/'), @('fstrim', '--version'))) {
    $guest = @(Get-WslGuestArguments $command)
    # PS 5.1 converts stderr redirection into error records; inspect the native exit code.
    $ErrorActionPreference = 'Continue'
    $output = @(& $wsl -d $Distro -u root @guest 2>&1)
    $code = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($code -ne 0) { throw "Guest probe $($command[0]) failed (exit=$code): $($output -join ' ')" }
    Write-Host "PASS: $Distro / $($command -join ' ')"
    $output | ForEach-Object { Write-Host "  $_" }
  }
} finally { [Console]::OutputEncoding = $previousEncoding }
