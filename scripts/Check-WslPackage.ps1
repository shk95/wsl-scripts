<#
.SYNOPSIS
  Inspect WSL engine packaging, update policy and distribution origins.
.DESCRIPTION
  Shows Store/AppX, MSI or legacy inbox engine packaging, Store update policy,
  recent installation events and registered distribution origins. Read-only.
  Installation history alone does not establish that a VM restarted.
.PARAMETER Distro
  Optional registered distribution name to filter the distribution listing.
.PARAMETER HistoryDays
  Number of days of installation history to inspect (default 90).
.PARAMETER Help
  Show full help and exit without accessing Windows or WSL.
.EXAMPLE
  .\scripts\Check-WslPackage.ps1
.EXAMPLE
  .\scripts\Check-WslPackage.ps1 -Distro NixOS -HistoryDays 180
.EXAMPLE
  .\scripts\Check-WslPackage.ps1 -Help
#>
[CmdletBinding()]
param(
  [string]$Distro,
  [int]$HistoryDays = 90,
  [switch]$Help
)

if ($Help) { Get-Help -Name $PSCommandPath -Full; return }
if ($env:OS -ne 'Windows_NT') { throw 'Run this script in Windows PowerShell on the Windows host.' }

$ErrorActionPreference = 'SilentlyContinue'
$WslExe = Join-Path $env:SystemRoot 'System32\wsl.exe'
$AppxName = 'MicrosoftCorporationII.WindowsSubsystemForLinux'

function Section($t) { Write-Host ''; Write-Host "== $t ==" -ForegroundColor Cyan }
function Invoke-Wsl([string[]]$CmdArgs) {
  $prev = [Console]::OutputEncoding
  try { [Console]::OutputEncoding = [System.Text.Encoding]::Unicode; (& $WslExe @CmdArgs 2>$null) | ForEach-Object { "$_".Trim() } | Where-Object { $_ } }
  finally { [Console]::OutputEncoding = $prev }
}

Section 'WSL engine'
$ver = Invoke-Wsl @('--version')
if ($ver) { $ver | ForEach-Object { Write-Host "  $_" } } else { Write-Host '  wsl --version failed (legacy inbox WSL or not installed)' }

$appx = Get-AppxPackage -Name $AppxName
$msi  = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' |
        Where-Object { $_.DisplayName -eq 'Windows Subsystem for Linux' } | Select-Object -First 1
$pfWsl = Test-Path 'C:\Program Files\WSL\wsl.exe'

Write-Host ''
if ($appx) {
  Write-Host ("  AppX package     : {0}  v{1}  SignatureKind={2}" -f $appx.Name, $appx.Version, $appx.SignatureKind)
  Write-Host ("  Install location       : {0}" -f $appx.InstallLocation)
} else { Write-Host '  AppX package     : None' }
if ($msi) {
  Write-Host ("  MSI registration   : {0} v{1}" -f $msi.DisplayName, $msi.DisplayVersion)
  Write-Host ("  MSI install source   : {0}" -f $msi.InstallSource)
} else { Write-Host '  MSI registration   : None' }
Write-Host ("  C:\Program Files\WSL\wsl.exe : {0}" -f $(if ($pfWsl) { 'Present' } else { 'None' }))

$verdict = ''
$autoUpdate = $false
if ($appx -and $appx.SignatureKind -eq 'Store') {
  $verdict = 'STORE package - eligible for Microsoft Store automatic updates. An engine update may stop/restart the WSL VM.'
  $autoUpdate = $true
} elseif ($appx) {
  $verdict = "Sideloaded AppX (SignatureKind=$($appx.SignatureKind)) - not eligible for Store automatic updates."
} elseif ($msi -or $pfWsl) {
  $verdict = 'MSI package detected. To request an update: wsl --update --web-download'
} else {
  $verdict = 'Legacy inbox WSL or not installed - not eligible for Store automatic updates.'
}
Write-Host ''
Write-Host "  Assessment: $verdict" -ForegroundColor $(if ($autoUpdate) { 'Yellow' } else { 'Green' })

Section 'Microsoft Store automatic update policy'
$pol  = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' -Name AutoDownload).AutoDownload
$user = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsStore\WindowsUpdate' -Name AutoDownload).AutoDownload
function Describe-AutoDownload($v) { switch ($v) { 2 { 'Off (2)' } 4 { 'On (4)' } $null { 'Not configured (default=on)' } default { "Value=$v" } } }
Write-Host ("  Group policy(HKLM\Policies)          : {0}" -f (Describe-AutoDownload $pol))
Write-Host ("  Store app setting(WindowsStore\WU)    : {0}" -f (Describe-AutoDownload $user))
if ($autoUpdate -and $pol -ne 2 -and $user -ne 2) {
  Write-Host '  -> Store automatic updates appear enabled for the WSL engine package.' -ForegroundColor Yellow
}

Section "WSL package installation history (last $HistoryDays days)"
$since = (Get-Date).AddDays(-$HistoryDays)
$wu = Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WindowsUpdateClient'; Id = 19, 43; StartTime = $since } |
      Where-Object { $_.Message -match 'WindowsSubsystemforLinux' }
$mi = Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'MsiInstaller'; Id = 1033; StartTime = $since } |
      Where-Object { $_.Message -match 'Windows Subsystem for Linux' }
if (-not $wu -and -not $mi) { Write-Host '  No records' }
foreach ($e in ($wu | Sort-Object TimeCreated)) {
  $kind = if ($e.Id -eq 43) { 'Store/WU install started' } else { 'Store/WU install completed' }
  Write-Host ("  {0:yyyy-MM-dd HH:mm:ss}  {1}" -f $e.TimeCreated, $kind)
}
foreach ($e in ($mi | Sort-Object TimeCreated)) {
  $v = [regex]::Match($e.Message, 'Product Version: ([\d.]+)').Groups[1].Value
  Write-Host ("  {0:yyyy-MM-dd HH:mm:ss}  MSI install completed v{1}" -f $e.TimeCreated, $v)
}
if ($wu) { Write-Host '  -> Installation events show package update times; they do not prove that the VM restarted.' }

Section 'Registered distributions'
$lxss = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
$defaultGuid = (Get-ItemProperty $lxss -Name DefaultDistribution).DefaultDistribution
$running = @(Invoke-Wsl @('-l', '-q', '--running'))
$items = Get-ChildItem $lxss | ForEach-Object {
  $p = Get-ItemProperty $_.PSPath
  [pscustomobject]@{
    Name    = $p.DistributionName
    Guid    = $_.PSChildName
    Version = $p.Version
    Package = $p.PackageFamilyName
    Path    = $p.BasePath
    Default = ($_.PSChildName -eq $defaultGuid)
    Running = ($running -contains $p.DistributionName)
  }
}
if ($Distro) { $items = $items | Where-Object { $_.Name -ieq $Distro }; if (-not $items) { Write-Host "  Distribution '$Distro' not found. Registered: $((Get-ChildItem $lxss | ForEach-Object { (Get-ItemProperty $_.PSPath).DistributionName }) -join ', ')" } }
foreach ($i in $items) {
  $src = if ($i.Package) { "Store app distribution ($($i.Package))" } else { 'Imported / manually registered (tar or vhdx) - independent of Store' }
  Write-Host ("  [{0}]{1}{2}" -f $i.Name, $(if ($i.Default) { ' (default)' } else { '' }), $(if ($i.Running) { ' (running)' } else { '' }))
  Write-Host ("    WSL {0}  Source: {1}" -f $i.Version, $src)
  Write-Host ("    Path: {0}" -f $i.Path)
}
Write-Host ''
Write-Host '  Note: engine packaging and distribution packaging are separate. Engine updates may affect all distributions.'
