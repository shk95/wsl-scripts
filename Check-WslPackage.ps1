<#
.SYNOPSIS
  WSL 엔진이 Store 패키지(자동 업데이트 대상)인지 MSI 패키지(수동 업데이트)인지, 그리고 배포판이 Store 앱인지 import 된 것인지 확인한다.

.DESCRIPTION
  1) WSL 엔진 설치 형태: AppX(Store 서명) / MSI / 인박스
  2) Microsoft Store 자동 업데이트 정책
  3) 최근 WSL 패키지 설치 이력 (Windows 이벤트 로그)  — 자동 업데이트로 인한 VM 재시작 시각 확인용
  4) 등록된 배포판의 출처 (Store 앱 배포판 / import 또는 수동 등록)

.EXAMPLE
  .\Check-WslPackage.ps1
  .\Check-WslPackage.ps1 -Distro Ubuntu26.04 -HistoryDays 180
#>
[CmdletBinding()]
param(
  [string]$Distro,
  [int]$HistoryDays = 90
)
$ErrorActionPreference = 'SilentlyContinue'
$WslExe = Join-Path $env:SystemRoot 'System32\wsl.exe'
$AppxName = 'MicrosoftCorporationII.WindowsSubsystemForLinux'

function Section($t) { Write-Host ''; Write-Host "== $t ==" -ForegroundColor Cyan }
function Invoke-Wsl([string[]]$CmdArgs) {
  $prev = [Console]::OutputEncoding
  try { [Console]::OutputEncoding = [System.Text.Encoding]::Unicode; (& $WslExe @CmdArgs 2>$null) | ForEach-Object { "$_".Trim() } | Where-Object { $_ } }
  finally { [Console]::OutputEncoding = $prev }
}

# ---------- 1. WSL 엔진 ----------
Section 'WSL 엔진'
$ver = Invoke-Wsl @('--version')
if ($ver) { $ver | ForEach-Object { Write-Host "  $_" } } else { Write-Host '  wsl --version 실패 (구형 인박스 WSL 이거나 미설치)' }

$appx = Get-AppxPackage -Name $AppxName
$msi  = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' |
        Where-Object { $_.DisplayName -eq 'Windows Subsystem for Linux' } | Select-Object -First 1
$pfWsl = Test-Path 'C:\Program Files\WSL\wsl.exe'

Write-Host ''
if ($appx) {
  Write-Host ("  AppX 패키지     : {0}  v{1}  SignatureKind={2}" -f $appx.Name, $appx.Version, $appx.SignatureKind)
  Write-Host ("  설치 위치       : {0}" -f $appx.InstallLocation)
} else { Write-Host '  AppX 패키지     : 없음' }
if ($msi) {
  Write-Host ("  MSI 등록 항목   : {0} v{1}" -f $msi.DisplayName, $msi.DisplayVersion)
  Write-Host ("  MSI 설치 원본   : {0}" -f $msi.InstallSource)
} else { Write-Host '  MSI 등록 항목   : 없음' }
Write-Host ("  C:\Program Files\WSL\wsl.exe : {0}" -f $(if ($pfWsl) { '있음' } else { '없음' }))

$verdict = ''
$autoUpdate = $false
if ($appx -and $appx.SignatureKind -eq 'Store') {
  $verdict = 'STORE 패키지 - Microsoft Store 자동 업데이트 대상. 업데이트 설치 시 WSL VM 이 예고 없이 종료/재시작될 수 있음.'
  $autoUpdate = $true
} elseif ($appx) {
  $verdict = "AppX 사이드로드 (SignatureKind=$($appx.SignatureKind)) - Store 자동 업데이트 대상 아님. 업데이트는 수동."
} elseif ($msi -or $pfWsl) {
  $verdict = 'MSI 패키지 - 수동 업데이트 상태. 업데이트는 직접 실행할 때만 적용됨:  wsl --update --web-download'
} else {
  $verdict = '인박스(구형) WSL 또는 미설치 - Store 자동 업데이트 대상 아님.'
}
Write-Host ''
Write-Host "  판정: $verdict" -ForegroundColor $(if ($autoUpdate) { 'Yellow' } else { 'Green' })

# ---------- 2. Store 정책 ----------
Section 'Microsoft Store 자동 업데이트 정책'
$pol  = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' -Name AutoDownload).AutoDownload
$user = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsStore\WindowsUpdate' -Name AutoDownload).AutoDownload
function Describe-AutoDownload($v) { switch ($v) { 2 { '끔(2)' } 4 { '켬(4)' } $null { '미설정(기본=켬)' } default { "값=$v" } } }
Write-Host ("  그룹 정책(HKLM\Policies)          : {0}" -f (Describe-AutoDownload $pol))
Write-Host ("  Store 앱 설정(WindowsStore\WU)    : {0}" -f (Describe-AutoDownload $user))
if ($autoUpdate -and $pol -ne 2 -and $user -ne 2) {
  Write-Host '  -> 자동 업데이트가 켜져 있고 WSL 이 Store 패키지이므로, WSL 만 제외하려면 MSI 배포판으로 교체해야 합니다 (Store 에는 앱별 제외 기능이 없음).' -ForegroundColor Yellow
}

# ---------- 3. 최근 WSL 패키지 설치 이력 ----------
Section "최근 $HistoryDays 일간 WSL 패키지 설치 이력"
$since = (Get-Date).AddDays(-$HistoryDays)
$wu = Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WindowsUpdateClient'; Id = 19, 43; StartTime = $since } |
      Where-Object { $_.Message -match 'WindowsSubsystemforLinux' }
$mi = Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'MsiInstaller'; Id = 1033; StartTime = $since } |
      Where-Object { $_.Message -match 'Windows Subsystem for Linux' }
if (-not $wu -and -not $mi) { Write-Host '  기록 없음' }
foreach ($e in ($wu | Sort-Object TimeCreated)) {
  $kind = if ($e.Id -eq 43) { 'Store/WU 설치 시작' } else { 'Store/WU 설치 완료' }
  Write-Host ("  {0:yyyy-MM-dd HH:mm:ss}  {1}" -f $e.TimeCreated, $kind)
}
foreach ($e in ($mi | Sort-Object TimeCreated)) {
  $v = [regex]::Match($e.Message, 'Product Version: ([\d.]+)').Groups[1].Value
  Write-Host ("  {0:yyyy-MM-dd HH:mm:ss}  MSI 설치 완료 v{1}" -f $e.TimeCreated, $v)
}
if ($wu) { Write-Host '  -> "Store/WU 설치" 기록이 있으면 그 시각에 WSL VM 이 자동 재시작된 것입니다.' }

# ---------- 4. 배포판 출처 ----------
Section '등록된 배포판'
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
if ($Distro) { $items = $items | Where-Object { $_.Name -ieq $Distro }; if (-not $items) { Write-Host "  배포판 '$Distro' 없음. 등록됨: $((Get-ChildItem $lxss | ForEach-Object { (Get-ItemProperty $_.PSPath).DistributionName }) -join ', ')" } }
foreach ($i in $items) {
  $src = if ($i.Package) { "Store 앱 배포판 ($($i.Package))" } else { 'import / 수동 등록 (tar·vhdx) - Store 와 무관' }
  Write-Host ("  [{0}]{1}{2}" -f $i.Name, $(if ($i.Default) { ' (기본)' } else { '' }), $(if ($i.Running) { ' (실행 중)' } else { '' }))
  Write-Host ("    WSL {0}  출처: {1}" -f $i.Version, $src)
  Write-Host ("    경로: {0}" -f $i.Path)
}
Write-Host ''
Write-Host '  참고: 배포판이 Store 앱이어도 rootfs 데이터는 Store 업데이트로 바뀌지 않습니다. VM 재시작을 일으키는 것은 WSL 엔진 패키지 업데이트입니다.'
