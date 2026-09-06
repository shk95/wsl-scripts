<#
.SYNOPSIS
  WSL 이 죽지 않도록 PC 절전을 막는 전원 설정 활성화/복구 스위트 (데스크톱·노트북).

.DESCRIPTION
  Enable  : 현재 전원 구성표를 백업(export)한 뒤 복제본 "WSL KeepAwake" 를 만들어 활성화하고
            AC 전원에서 절전/최대 절전/디스크 끄기를 해제한다.               [관리자]
            노트북(배터리 감지 또는 -Laptop)이면 덮개 닫기 동작을 -LidAction 으로 바꾼다.
            기본은 배터리에서는 원래 절전 정책을 유지한다. 배터리에서도 깨어 있게 하려면 -KeepAwakeOnBattery.
  Restore : 백업된 원래 구성표로 되돌리고 "WSL KeepAwake" 구성표를 삭제한다.  [관리자]
  Status  : 장치 종류, 활성 구성표, AC/DC 타임아웃, 덮개 동작, 최대 절전 여부, 현재 절전 차단 요청, 백업 유무.

.PARAMETER LidAction        노트북 덮개 닫기 동작 (DoNothing|Sleep|Hibernate|Shutdown). 기본 DoNothing.
.PARAMETER KeepAwakeOnBattery  배터리(DC)에서도 절전/최대절전 0 + 덮개 동작 적용. (배터리 소모 주의)
.PARAMETER MonitorTimeoutMinutes  AC 모니터 끄기 시간(분). 0=끄지 않음. 생략 시 현재 값 유지.
.PARAMETER DisableHibernate  powercfg /hibernate off (빠른 시작도 함께 꺼짐). Restore 시 원복.
.PARAMETER Laptop / Desktop  장치 종류 자동 감지를 덮어쓴다.

.EXAMPLE
  .\WSL-PowerGuard.ps1 -Action Enable
  .\WSL-PowerGuard.ps1 -Action Enable -Laptop -LidAction DoNothing -KeepAwakeOnBattery
  .\WSL-PowerGuard.ps1 -Action Restore
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][ValidateSet('Enable', 'Restore', 'Status')][string]$Action,
  [switch]$Laptop,
  [switch]$Desktop,
  [ValidateSet('DoNothing', 'Sleep', 'Hibernate', 'Shutdown')][string]$LidAction = 'DoNothing',
  [switch]$KeepAwakeOnBattery,
  [int]$MonitorTimeoutMinutes = -1,
  [switch]$DisableHibernate
)

$ErrorActionPreference = 'Stop'
$BaseDir    = 'C:\ProgramData\WSL-PowerGuard'
$BackupJson = Join-Path $BaseDir 'backup.json'
$BackupPow  = Join-Path $BaseDir 'original-scheme.pow'
$SchemeName = 'WSL KeepAwake'

# powercfg GUID 상수 (로캘 무관)
$SUB_SLEEP   = '238c9fa8-0aad-41ed-83f4-97be242c8f20'
$STANDBYIDLE = '29f6c1db-86da-48c5-9fdb-f2b67b1f44da'
$HIBERIDLE   = '9d7815a6-7ee4-497e-8888-515a05f02364'
$HYBRIDSLEEP = '94ac6d29-73ce-41a6-809f-6363ba21b47e'
$UNATTENDED  = '7bc4a2f9-d8fc-4469-b07b-33eb785aaca0'   # 무인 절전 시간 제한
$SUB_VIDEO   = '7516b95f-f776-4464-8c53-06167f40cc99'
$VIDEOIDLE   = '3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e'
$SUB_DISK    = '0012ee47-9041-4b5d-9b77-535fba8b1442'
$DISKIDLE    = '6738e2c4-e8a5-4a42-b16a-e040e769756e'
$SUB_BUTTONS = '4f971e89-eebd-4455-a8de-9e59040e7347'
$LID_GUID    = '5ca83367-6e45-459f-a27b-476b1d01c936'
$SUB_NONE    = 'fea3413e-7e05-4911-9a71-700331f1c294'
$CONNSTANDBY = 'f15576e8-98b7-4186-b944-eafa664402d9'   # 대기 모드 네트워크 연결(모던 스탠바이)
$LidMap = @{ DoNothing = 0; Sleep = 1; Hibernate = 2; Shutdown = 3 }
$LidNames = @{ 0 = 'DoNothing'; 1 = 'Sleep'; 2 = 'Hibernate'; 3 = 'Shutdown' }

function Test-Admin { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
function Assert-Admin { if (-not (Test-Admin)) { throw "Action=$Action 은 관리자 PowerShell에서 실행해야 합니다." } }
function Pc {
  param([string[]]$CmdArgs)
  $ErrorActionPreference = 'Continue'   # PS5.1: Stop + 2>&1 이면 stderr 한 줄이 예외가 되어 exit code 검사에 못 미침
  $o = & powercfg.exe @CmdArgs 2>&1
  if ($LASTEXITCODE -ne 0) { throw "powercfg $($CmdArgs -join ' ') 실패: $o" }
  $o
}
function Pc-Try {   # 실패해도 무시 (숨김 설정, 모던 스탠바이 전용 설정 등)
  param([string[]]$CmdArgs)
  $ErrorActionPreference = 'Continue'
  & powercfg.exe @CmdArgs 2>&1 | Out-Null
}

function Test-Laptop {
  if ($Laptop) { return $true }; if ($Desktop) { return $false }
  if (Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue) { return $true }
  $ct = (Get-CimInstance Win32_SystemEnclosure -ErrorAction SilentlyContinue).ChassisTypes
  return [bool]($ct | Where-Object { $_ -in 8, 9, 10, 11, 14, 30, 31, 32 })
}
function Get-ActiveScheme {
  $line = (Pc @('/getactivescheme')) -join ' '
  $m = [regex]::Match($line, '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\s*\((.*)\)')
  [pscustomobject]@{ Guid = $m.Groups[1].Value; Name = $m.Groups[2].Value.Trim() }
}
function Get-SchemeList { (Pc @('/list')) | ForEach-Object { $m = [regex]::Match($_, '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\s*\((.*)\)'); if ($m.Success) { [pscustomobject]@{ Guid = $m.Groups[1].Value; Name = $m.Groups[2].Value } } } }
function Get-SettingIndex([string]$sub, [string]$setting) {
  # 로캘 무관: "... AC ...: 0x00000000" / "... DC ...: 0x..." 패턴만 사용
  $ErrorActionPreference = 'Continue'
  $out = (& powercfg.exe /q SCHEME_CURRENT $sub $setting 2>&1) -join "`n"
  $ac = [regex]::Match($out, '(?im)AC[^\n]*:\s*0x([0-9a-f]+)').Groups[1].Value
  $dc = [regex]::Match($out, '(?im)DC[^\n]*:\s*0x([0-9a-f]+)').Groups[1].Value
  [pscustomobject]@{ AC = $(if ($ac) { [convert]::ToInt64($ac, 16) } else { $null }); DC = $(if ($dc) { [convert]::ToInt64($dc, 16) } else { $null }) }
}
function Format-Timeout($sec) { if ($null -eq $sec) { 'n/a' } elseif ($sec -eq 0) { '안 함(0)' } else { "{0}분" -f [int]($sec / 60) } }
function Get-HibernateEnabled { (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -Name HibernateEnabled -ErrorAction SilentlyContinue).HibernateEnabled -eq 1 }

function Show-Status {
  $isLaptop = Test-Laptop
  $act = Get-ActiveScheme
  Write-Host ("장치 종류        : {0}" -f $(if ($isLaptop) { '노트북(배터리 감지)' } else { '데스크톱' }))
  Write-Host ("활성 구성표      : {0}  ({1})" -f $act.Name, $act.Guid)
  Write-Host ("PowerGuard 백업  : {0}" -f $(if (Test-Path $BackupJson) { "있음 -> Enable 적용 상태 ($BackupJson)" } else { '없음 (원본 상태)' }))
  $sb = Get-SettingIndex $SUB_SLEEP $STANDBYIDLE; $hb = Get-SettingIndex $SUB_SLEEP $HIBERIDLE
  $vd = Get-SettingIndex $SUB_VIDEO $VIDEOIDLE;   $dk = Get-SettingIndex $SUB_DISK $DISKIDLE
  $hy = Get-SettingIndex $SUB_SLEEP $HYBRIDSLEEP; $ua = Get-SettingIndex $SUB_SLEEP $UNATTENDED
  $ld = Get-SettingIndex $SUB_BUTTONS $LID_GUID
  Write-Host ''
  Write-Host ('{0,-18}{1,-16}{2}' -f '설정', 'AC(전원)', 'DC(배터리)')
  Write-Host ('{0,-18}{1,-16}{2}' -f '절전 진입', (Format-Timeout $sb.AC), (Format-Timeout $sb.DC))
  Write-Host ('{0,-18}{1,-16}{2}' -f '최대 절전 진입', (Format-Timeout $hb.AC), (Format-Timeout $hb.DC))
  Write-Host ('{0,-18}{1,-16}{2}' -f '무인 절전 제한', (Format-Timeout $ua.AC), (Format-Timeout $ua.DC))
  Write-Host ('{0,-18}{1,-16}{2}' -f '모니터 끄기', (Format-Timeout $vd.AC), (Format-Timeout $vd.DC))
  Write-Host ('{0,-18}{1,-16}{2}' -f '디스크 끄기', (Format-Timeout $dk.AC), (Format-Timeout $dk.DC))
  Write-Host ('{0,-18}{1,-16}{2}' -f '하이브리드 절전', $(if ($hy.AC -eq 0) { '끔' } else { '켬' }), $(if ($hy.DC -eq 0) { '끔' } else { '켬' }))
  if ($isLaptop) { Write-Host ('{0,-18}{1,-16}{2}' -f '덮개 닫기', $LidNames[[int]$ld.AC], $LidNames[[int]$ld.DC]) }
  Write-Host ''
  Write-Host ("최대 절전(hibernate) : {0}" -f $(if (Get-HibernateEnabled) { '사용' } else { '사용 안 함' }))
  Write-Host '현재 절전 차단 요청(powercfg /requests):'
  $ErrorActionPreference = 'Continue'
  $req = & powercfg.exe /requests 2>&1
  $ErrorActionPreference = 'Stop'
  if ($LASTEXITCODE -eq 0) { $req | ForEach-Object { Write-Host "  $_" } } else { Write-Host '  (관리자 권한 필요)' }
  $ok = ($sb.AC -eq 0 -and $hb.AC -eq 0)
  Write-Host ''
  Write-Host ("판정: AC 전원에서 {0}" -f $(if ($ok) { '절전에 들어가지 않음 - WSL 유지 가능' } else { '절전 타임아웃이 설정되어 있어 WSL 이 끊길 수 있음 -> -Action Enable' })) -ForegroundColor $(if ($ok) { 'Green' } else { 'Yellow' })
  if ($isLaptop -and ($ld.AC -ne 0)) { Write-Host '      노트북: AC 상태에서 덮개를 닫으면 절전/종료됨 -> -Action Enable -LidAction DoNothing' -ForegroundColor Yellow }
}

switch ($Action) {
  'Status' { Show-Status }

  'Enable' {
    Assert-Admin
    $isLaptop = Test-Laptop
    if (Test-Path $BackupJson) {
      Write-Warning "이미 Enable 이 적용된 상태입니다 (백업: $BackupJson). 설정만 다시 적용하고 원본 백업은 유지합니다."
      $bk = Get-Content $BackupJson -Raw | ConvertFrom-Json
      $target = $bk.NewGuid
      if (-not (Get-SchemeList | Where-Object Guid -eq $target)) { throw "백업에 기록된 구성표 $target 이 없습니다. -Action Restore 로 정리 후 다시 시도하세요." }
    } else {
      New-Item -ItemType Directory -Force -Path $BaseDir | Out-Null
      $orig = Get-ActiveScheme
      Pc @('/export', $BackupPow, $orig.Guid) | Out-Null
      $dupOut = (Pc @('/duplicatescheme', $orig.Guid)) -join ' '
      $target = [regex]::Match($dupOut, '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}').Value
      if (-not $target) { throw "구성표 복제 실패: $dupOut" }
      Pc @('/changename', $target, "$SchemeName (원본: $($orig.Name))") | Out-Null
      [pscustomobject]@{
        OriginalGuid = $orig.Guid; OriginalName = $orig.Name; NewGuid = $target
        HibernateWasEnabled = (Get-HibernateEnabled); AppliedAt = (Get-Date -Format 's'); IsLaptop = $isLaptop
      } | ConvertTo-Json | Set-Content -Path $BackupJson -Encoding UTF8
      Write-Host "원본 구성표 백업: $($orig.Name) -> $BackupPow"
    }
    Pc @('/setactive', $target) | Out-Null

    # --- AC: 절전 관련 전부 해제 ---
    Pc @('/setacvalueindex', $target, $SUB_SLEEP, $STANDBYIDLE, '0') | Out-Null
    Pc @('/setacvalueindex', $target, $SUB_SLEEP, $HIBERIDLE,   '0') | Out-Null
    Pc @('/setacvalueindex', $target, $SUB_SLEEP, $HYBRIDSLEEP, '0') | Out-Null
    Pc-Try @('/setacvalueindex', $target, $SUB_SLEEP, $UNATTENDED, '0')       # 숨김 설정: 실패 무시
    Pc @('/setacvalueindex', $target, $SUB_DISK,  $DISKIDLE,    '0') | Out-Null
    Pc-Try @('/setacvalueindex', $target, $SUB_NONE, $CONNSTANDBY, '1')       # 모던 스탠바이 기기만 존재, 실패 무시
    if ($MonitorTimeoutMinutes -ge 0) { Pc @('/setacvalueindex', $target, $SUB_VIDEO, $VIDEOIDLE, [string]($MonitorTimeoutMinutes * 60)) | Out-Null }

    # --- 노트북 ---
    if ($isLaptop) {
      Pc @('/setacvalueindex', $target, $SUB_BUTTONS, $LID_GUID, [string]$LidMap[$LidAction]) | Out-Null
      if ($KeepAwakeOnBattery) {
        Pc @('/setdcvalueindex', $target, $SUB_SLEEP, $STANDBYIDLE, '0') | Out-Null
        Pc @('/setdcvalueindex', $target, $SUB_SLEEP, $HIBERIDLE,   '0') | Out-Null
        Pc-Try @('/setdcvalueindex', $target, $SUB_SLEEP, $UNATTENDED, '0')   # 숨김 설정: 실패 무시
        Pc @('/setdcvalueindex', $target, $SUB_BUTTONS, $LID_GUID, [string]$LidMap[$LidAction]) | Out-Null
        Write-Host "노트북: 배터리에서도 절전 안 함 + 덮개 닫기=$LidAction  (배터리 소모 주의)"
      } else {
        Write-Host "노트북: AC 에서 덮개 닫기=$LidAction. 배터리 정책은 원본 유지 (배터리에서도 유지하려면 -KeepAwakeOnBattery)"
      }
    }
    if ($DisableHibernate) { Pc @('/hibernate', 'off') | Out-Null; Write-Host '최대 절전 사용 안 함 (빠른 시작도 꺼짐)' }
    Pc @('/setactive', $target) | Out-Null
    Write-Host "적용 완료: 구성표 '$SchemeName' 활성."
    Write-Host ''
    Show-Status
  }

  'Restore' {
    Assert-Admin
    if (-not (Test-Path $BackupJson)) { throw "백업이 없습니다 ($BackupJson). Enable 이 적용된 적이 없거나 이미 복구되었습니다." }
    $bk = Get-Content $BackupJson -Raw | ConvertFrom-Json
    $list = Get-SchemeList
    if ($list | Where-Object Guid -eq $bk.OriginalGuid) {
      Pc @('/setactive', $bk.OriginalGuid) | Out-Null
      Write-Host "원본 구성표 활성화: $($bk.OriginalName)"
    } elseif (Test-Path $BackupPow) {
      $imp = (Pc @('/import', $BackupPow)) -join ' '
      $g = [regex]::Match($imp, '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}').Value
      if (-not $g) { throw "백업 import 실패: $imp" }
      Pc @('/changename', $g, $bk.OriginalName) | Out-Null
      Pc @('/setactive', $g) | Out-Null
      Write-Host "원본 구성표가 없어 백업 파일에서 복원: $($bk.OriginalName) ($g)"
    } else { throw '원본 구성표도 백업 파일도 없어 복구할 수 없습니다.' }
    if ($list | Where-Object Guid -eq $bk.NewGuid) { Pc @('/delete', $bk.NewGuid) | Out-Null; Write-Host "구성표 삭제: $SchemeName" }
    if ($bk.HibernateWasEnabled -and -not (Get-HibernateEnabled)) { Pc @('/hibernate', 'on') | Out-Null; Write-Host '최대 절전 원복(사용)' }
    Move-Item -Force $BackupJson (Join-Path $BaseDir ("restored-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss')))
    Remove-Item -Force $BackupPow -ErrorAction SilentlyContinue
    Write-Host '복구 완료.'
    Write-Host ''
    Show-Status
  }
}
