<#
.SYNOPSIS
  WSL KeepAlive 스케줄 태스크 관리 스위트.

.DESCRIPTION
  지정한 배포판을 부팅 시부터 계속 살려 두는 태스크(WSL-KeepAlive-<배포판>)를 설치/제거/활성/비활성/일시정지/재개하고 상태를 보여준다.
  루프 본체는 keepalive-loop.ps1 이며 Install 시 C:\ProgramData\WSL-KeepAlive\ 로 복사된다.

  Action
    List       등록된 배포판, 실행 중 배포판, KeepAlive 태스크 목록
    Status     태스크 상태 / 일시정지 여부 / 루프 프로세스 / VM 상태 / 최근 로그
    Install    태스크 등록(기존 동명 태스크는 교체) 후 시작           [관리자]
    Uninstall  태스크 제거, 루프 프로세스 정리                          [관리자]
    Enable     태스크 활성화 + 시작, 일시정지 해제                      [관리자]
    Disable    태스크 비활성화 + 중지, 루프/홀드 프로세스 정리            [관리자]  (-Shutdown 추가 시 wsl --shutdown)
    Pause      일시정지 플래그 생성: 이후 VM이 내려가면 다시 띄우지 않음      (-Shutdown 추가 시 지금 바로 내림)
    Resume     일시정지 해제: 루프가 10초 안에 배포판을 다시 띄움

.EXAMPLE
  .\WSL-KeepAlive.ps1 -Action Install -Distro Ubuntu26.04
  .\WSL-KeepAlive.ps1 -Action Pause -Distro Ubuntu26.04 -Shutdown
  .\WSL-KeepAlive.ps1 -Action Status
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('List', 'Status', 'Install', 'Uninstall', 'Enable', 'Disable', 'Pause', 'Resume')]
  [string]$Action,

  # 대상 배포판 이름 (wsl -l 에 보이는 이름). 배포판이 하나뿐이면 생략 가능.
  [string]$Distro,

  # Disable/Pause 시 wsl --shutdown 까지 수행
  [switch]$Shutdown,

  # Install 시 태스크 실행 계정. 생략하면 프롬프트. (WSL 배포판을 소유한 사용자여야 함)
  [System.Management.Automation.PSCredential]$Credential
)

$ErrorActionPreference = 'Stop'
$BaseDir   = 'C:\ProgramData\WSL-KeepAlive'
$FlagDir   = Join-Path $BaseDir 'flags'      # 일반 사용자 쓰기 허용 범위는 이 폴더만
$FlagPath  = Join-Path $FlagDir 'paused'
$LoopName  = 'keepalive-loop.ps1'
$LoopSrc   = Join-Path $PSScriptRoot $LoopName
$LoopDst   = Join-Path $BaseDir $LoopName
$WslExe    = Join-Path $env:SystemRoot 'System32\wsl.exe'
$PsExe     = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$TaskPrefix = 'WSL-KeepAlive-'

# ---------- helpers ----------
function Test-Admin {
  ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Assert-Admin { if (-not (Test-Admin)) { throw "Action=$Action 은 관리자 PowerShell에서 실행해야 합니다." } }

function Invoke-Wsl {
  # wsl.exe 는 UTF-16 으로 출력하므로 캡처 전에 콘솔 인코딩을 맞춘다.
  param([string[]]$CmdArgs)
  $ErrorActionPreference = 'Continue'   # PS5.1: Stop + 2> 리다이렉션이면 stderr 한 줄이 예외가 됨
  $prev = [Console]::OutputEncoding
  try {
    [Console]::OutputEncoding = [System.Text.Encoding]::Unicode
    (& $WslExe @CmdArgs 2>$null) | ForEach-Object { "$_".Trim() } | Where-Object { $_ }
  } finally { [Console]::OutputEncoding = $prev }
}
function Get-WslDistros        { @(Invoke-Wsl @('-l', '-q')) }
function Get-RunningDistros    { @(Invoke-Wsl @('-l', '-q', '--running')) }

function Resolve-Distro {
  param([string]$Name, [switch]$AllowUnregistered)
  $all = @(Get-WslDistros)
  if ($Name) {
    $m = $all | Where-Object { $_ -ieq $Name } | Select-Object -First 1
    if ($m) { return $m }
    if ($AllowUnregistered) { return $Name }
    throw "배포판 '$Name' 이 등록되어 있지 않습니다. 등록된 배포판: $($all -join ', ')"
  }
  if ($all.Count -eq 1) { return $all[0] }
  if ($all.Count -eq 0) { throw '등록된 WSL 배포판이 없습니다.' }
  throw "배포판을 -Distro 로 지정하세요. 등록된 배포판: $($all -join ', ')"
}

function Get-TaskName([string]$d) { "$TaskPrefix$d" }
function Get-KeepAliveTasks { @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like "$TaskPrefix*" }) }

function Get-LoopProcesses([string]$d) {
  # 새 루프(keepalive-loop.ps1)와 구형 인라인 루프(-Command "while...sleep infinity") 모두 매칭
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object {
    $_.CommandLine -and ($_.CommandLine -match 'keepalive-loop\.ps1' -or $_.CommandLine -match 'sleep infinity') -and
    (-not $d -or $_.CommandLine -match [regex]::Escape($d))
  }
}
function Get-HoldProcesses([string]$d) {
  Get-CimInstance Win32_Process -Filter "Name='wsl.exe'" | Where-Object {
    $_.CommandLine -and $_.CommandLine -match 'sleep infinity' -and (-not $d -or $_.CommandLine -match [regex]::Escape($d))
  }
}
function Stop-LoopAndHold([string]$d) {
  foreach ($p in @(Get-LoopProcesses $d) + @(Get-HoldProcesses $d)) {
    Write-Host ("  프로세스 종료: {0} PID={1}" -f $p.Name, $p.ProcessId)
    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
  }
}
function Test-Paused { Test-Path -LiteralPath $FlagPath }

function Show-Status([string]$d) {
  $tasks = if ($d) { @(Get-ScheduledTask -TaskName (Get-TaskName $d) -ErrorAction SilentlyContinue) } else { Get-KeepAliveTasks }
  $running = Get-RunningDistros
  Write-Host ("실행 중 배포판 : {0}" -f $(if ($running) { $running -join ', ' } else { '(없음)' }))
  Write-Host ("일시정지 플래그 : {0}  ({1})" -f $(if (Test-Paused) { 'PAUSED' } else { '없음' }), $FlagPath)
  if (-not $tasks) { Write-Host 'KeepAlive 태스크 : 없음'; return }
  foreach ($t in $tasks) {
    $name = $t.TaskName; $dn = $name.Substring($TaskPrefix.Length)
    $info = Get-ScheduledTaskInfo -TaskName $name -ErrorAction SilentlyContinue
    $loop = @(Get-LoopProcesses $dn); $hold = @(Get-HoldProcesses $dn)
    $legacy = ($t.Actions | ForEach-Object { $_.Arguments }) -join ' ' -notmatch 'keepalive-loop\.ps1'
    Write-Host ''
    Write-Host ("[{0}]" -f $name)
    Write-Host ("  상태        : {0}   Enabled={1}   {2}" -f $t.State, $t.Settings.Enabled, $(if ($legacy) { '(구형 인라인 루프: Install 로 교체 권장)' } else { '' }))
    Write-Host ("  마지막 실행 : {0}   결과=0x{1:X}" -f $info.LastRunTime, $info.LastTaskResult)
    Write-Host ("  루프 프로세스: {0}" -f $(if ($loop) { ($loop | ForEach-Object { "PID=$($_.ProcessId)" }) -join ', ' } else { '없음' }))
    Write-Host ("  홀드 wsl.exe : {0}" -f $(if ($hold) { ($hold | ForEach-Object { "PID=$($_.ProcessId)" }) -join ', ' } else { '없음' }))
    $log = Join-Path $BaseDir "keepalive-$dn.log"
    if (Test-Path -LiteralPath $log) {
      Write-Host '  최근 로그   :'
      Get-Content -LiteralPath $log -Tail 5 | ForEach-Object { Write-Host "    $_" }
    }
  }
}

# ---------- actions ----------
switch ($Action) {

  'List' {
    Write-Host ('등록된 배포판 : ' + ((Get-WslDistros) -join ', '))
    Write-Host ('실행 중 배포판: ' + ((Get-RunningDistros) -join ', '))
    $tasks = Get-KeepAliveTasks
    Write-Host ('KeepAlive 태스크: ' + $(if ($tasks) { ($tasks | ForEach-Object { "$($_.TaskName)[$($_.State)]" }) -join ', ' } else { '없음' }))
  }

  'Status' {
    $d = if ($Distro) { Resolve-Distro $Distro -AllowUnregistered } else { $null }
    Show-Status $d
  }

  'Install' {
    Assert-Admin
    $d = Resolve-Distro $Distro
    if (-not (Test-Path -LiteralPath $LoopSrc)) { throw "루프 스크립트가 없습니다: $LoopSrc" }
    if (-not $Credential) {
      $Credential = Get-Credential -UserName "$env:USERDOMAIN\$env:USERNAME" -Message "KeepAlive 태스크 실행 계정 (배포판 '$d' 의 소유자)"
      if (-not $Credential) { throw '자격 증명이 필요합니다.' }
    }
    New-Item -ItemType Directory -Force -Path $BaseDir, $FlagDir | Out-Null
    # Pause/Resume 을 일반 권한으로 할 수 있도록 flags\ 에만 Users(S-1-5-32-545) 수정 권한 부여.
    # (BaseDir 전체에 주면 관리자 권한으로 부팅 시 실행되는 keepalive-loop.ps1 을 일반 사용자가 고칠 수 있게 됨)
    $acl  = Get-Acl -LiteralPath $FlagDir
    $sid  = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545')
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($sid, 'Modify', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
    $acl.AddAccessRule($rule); Set-Acl -LiteralPath $FlagDir -AclObject $acl
    Copy-Item -LiteralPath $LoopSrc -Destination $LoopDst -Force

    $name = Get-TaskName $d
    if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
      Write-Host "기존 태스크 $name 을 교체합니다."
      Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
      Unregister-ScheduledTask -TaskName $name -Confirm:$false
      Stop-LoopAndHold $d
    }
    $arg = "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$LoopDst`" -Distro `"$d`" -FlagPath `"$FlagPath`""
    # 주의: $Action 파라미터와 대소문자 무시 충돌하므로 다른 이름 사용
    $taskAction = New-ScheduledTaskAction -Execute $PsExe -Argument $arg
    $trigger  = New-ScheduledTaskTrigger -AtStartup
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                  -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    $settings.ExecutionTimeLimit = 'PT0S'   # 실행 시간 제한 없음 (기본 3일 제한 해제)
    Register-ScheduledTask -TaskName $name -Action $taskAction -Trigger $trigger -Settings $settings `
      -User $Credential.UserName -Password $Credential.GetNetworkCredential().Password -RunLevel Highest | Out-Null
    Remove-Item -LiteralPath $FlagPath -Force -ErrorAction SilentlyContinue
    Start-ScheduledTask -TaskName $name
    Write-Host "설치 완료: $name"
    Start-Sleep -Seconds 3
    Show-Status $d
  }

  'Uninstall' {
    Assert-Admin
    $d = Resolve-Distro $Distro -AllowUnregistered
    $name = Get-TaskName $d
    if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
      Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
      Unregister-ScheduledTask -TaskName $name -Confirm:$false
      Write-Host "태스크 제거: $name"
    } else { Write-Host "태스크 없음: $name" }
    Stop-LoopAndHold $d
    if (-not (Get-KeepAliveTasks)) {
      Remove-Item -LiteralPath $LoopDst, $FlagPath -Force -ErrorAction SilentlyContinue
      Write-Host "남은 KeepAlive 태스크가 없어 $LoopDst 를 제거했습니다. (로그는 $BaseDir 에 남김)"
    }
    Write-Host 'VM 자체는 건드리지 않았습니다. 지금 내리려면: wsl --shutdown'
  }

  'Enable' {
    Assert-Admin
    $d = Resolve-Distro $Distro -AllowUnregistered
    $name = Get-TaskName $d
    if (-not (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue)) { throw "태스크가 없습니다: $name  (먼저 -Action Install)" }
    Remove-Item -LiteralPath $FlagPath -Force -ErrorAction SilentlyContinue
    Enable-ScheduledTask -TaskName $name | Out-Null
    Start-ScheduledTask  -TaskName $name
    Write-Host "활성화 + 시작: $name"
    Start-Sleep -Seconds 3
    Show-Status $d
  }

  'Disable' {
    Assert-Admin
    $d = Resolve-Distro $Distro -AllowUnregistered
    $name = Get-TaskName $d
    if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
      Disable-ScheduledTask -TaskName $name | Out-Null
      Stop-ScheduledTask    -TaskName $name -ErrorAction SilentlyContinue
      Write-Host "비활성화 + 중지: $name"
    } else { Write-Host "태스크 없음: $name" }
    Stop-LoopAndHold $d
    if ($Shutdown) { & $WslExe --shutdown; Write-Host 'wsl --shutdown 실행' }
    else { Write-Host '루프는 멈췄습니다. VM을 지금 내리려면 -Shutdown 을 추가하거나 wsl --shutdown 을 실행하세요.' }
    Show-Status $d
  }

  'Pause' {
    $d = Resolve-Distro $Distro -AllowUnregistered
    if (-not (Test-Path -LiteralPath $FlagDir)) { throw "$FlagDir 이 없습니다. 먼저 -Action Install 을 하세요." }
    New-Item -ItemType File -Force -Path $FlagPath | Out-Null
    Write-Host "일시정지 플래그 생성: $FlagPath  (모든 KeepAlive 루프에 적용)"
    if ($Shutdown) { & $WslExe --shutdown; Write-Host 'wsl --shutdown 실행. Resume 전까지 다시 뜨지 않습니다.' }
    else { Write-Host 'VM은 지금 살아 있습니다. 다음에 내려가면 다시 띄우지 않습니다. 바로 내리려면 -Shutdown.' }
    Show-Status $d
  }

  'Resume' {
    $d = Resolve-Distro $Distro -AllowUnregistered
    Remove-Item -LiteralPath $FlagPath -Force -ErrorAction SilentlyContinue
    Write-Host '일시정지 해제.'
    $name = Get-TaskName $d
    $t = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    if ($t -and $t.State -ne 'Running') {
      try { Start-ScheduledTask -TaskName $name; Write-Host "태스크 시작: $name" }
      catch { Write-Warning "태스크가 실행 중이 아닙니다. 관리자 PowerShell에서 -Action Enable 을 실행하세요. ($_)" }
    } elseif ($t) { Write-Host '루프가 10초 안에 배포판을 다시 띄웁니다.' }
    else { Write-Warning "태스크가 없습니다: $name  (-Action Install 필요)" }
    Show-Status $d
  }
}
