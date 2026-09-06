<#
.SYNOPSIS
  선택한 WSL 배포판의 ext4.vhdx 를 압축(compaction)해 Windows 디스크 공간을 회수한다.

.DESCRIPTION
  Action
    Status    배포판/vhdx 경로, 파일 크기(논리·실제 할당), 게스트 사용량, 회수 예상량, sparse 여부, 사용 가능한 압축 방법
    Trim      배포판 안에서 fstrim 만 실행 (VM 유지)
    Compact   fstrim -> 배포판 종료(필요 시 wsl --shutdown) -> vhdx 압축 -> (옵션) 배포판 재시작   [관리자]
    SetSparse -Sparse $true/$false 로 vhdx sparse 모드 전환 (WSL 2.x 필요)                        [관리자]

  압축 방법(-Method)
    Auto        Hyper-V PowerShell 모듈이 있으면 OptimizeVHD, 없으면 Diskpart
    OptimizeVHD Optimize-VHD -Mode Full  (Hyper-V 관리 도구가 설치된 Pro/Enterprise/LTSC 등)
    Diskpart    diskpart: attach readonly -> compact vdisk -> detach  (Home 포함 Windows 10/11 공통)

  고려사항 (실측 기준):
    1. fstrim: 필요. vhdx 압축은 "게스트가 버렸다(discard)"고 표시된 블록만 회수한다. ext4 가 discard 옵션으로
       마운트되어 있어도 누락분이 있을 수 있으므로 압축 직전에 fstrim -a 를 한 번 돌린다. 비용은 수 초.
    2. Windows 10/11 차이: 압축 자체는 같다. 차이는 (a) Optimize-VHD 가 Hyper-V 모듈 유무(에디션/기능)에 달렸고
       (b) --set-sparse 가 Windows 버전이 아니라 WSL 버전(Store/MSI 2.x)에 달렸다는 점. 인박스(구형) WSL 은 sparse 불가.
    3. sparse: vhdx 가 sparse 모드면 fstrim 후 배포판을 종료하는 것만으로 공간이 돌아오므로 압축이 불필요하다.
       이 스크립트는 sparse 파일에는 -Force 없이는 Compact 를 하지 않는다. (sparse 는 초기 WSL 2.0.x 에서
       손상 보고가 있었으니 백업 후 적용 권장. 켠 뒤에는 이 스크립트가 없어도 자동 회수된다.)

  KeepAlive 태스크가 있으면 압축 중 배포판이 다시 뜨지 않도록 일시정지 플래그를 자동으로 만들고, 끝나면 되돌린다.

.EXAMPLE
  .\Compact-WslDistro.ps1 -Action Status  -Distro Ubuntu26.04
  .\Compact-WslDistro.ps1 -Action Compact -Distro Ubuntu26.04            # 끝나고 배포판 재시작 안 함
  .\Compact-WslDistro.ps1 -Action Compact -Distro Ubuntu26.04 -Restart   # 끝나고 배포판 재시작
  .\Compact-WslDistro.ps1 -Action Compact -Distro Ubuntu26.04 -Method Diskpart -WhatIf
  .\Compact-WslDistro.ps1 -Action SetSparse -Distro Ubuntu26.04 -Sparse $true
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [Parameter(Mandatory = $true)][ValidateSet('Status', 'Trim', 'Compact', 'SetSparse')][string]$Action,
  [string]$Distro,
  [ValidateSet('Auto', 'OptimizeVHD', 'Diskpart')][string]$Method = 'Auto',
  [switch]$SkipTrim,          # Compact 시 fstrim 생략
  [switch]$NoShutdown,        # wsl -t 로 잠금이 안 풀려도 wsl --shutdown 하지 않고 중단
  [switch]$Restart,           # Compact 후 배포판 재시작
  [switch]$Force,             # sparse vhdx 도 강제로 압축
  [Nullable[bool]]$Sparse     # SetSparse 용
)

$ErrorActionPreference = 'Stop'
$WslExe      = Join-Path $env:SystemRoot 'System32\wsl.exe'
$KeepAliveDir = 'C:\ProgramData\WSL-KeepAlive'
$PauseFlag    = Join-Path $KeepAliveDir 'flags\paused'

# Hyper-V 모듈을 미리 로드 (-WhatIf 상태에서 자동 로드되면 모듈 내부 New-Alias 가 What if 메시지를 쏟아낸다)
$__wp = $WhatIfPreference; $WhatIfPreference = $false
Import-Module Hyper-V -ErrorAction SilentlyContinue
$WhatIfPreference = $__wp

function Test-Admin { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
function Assert-Admin { if (-not (Test-Admin)) { throw "Action=$Action 은 관리자 PowerShell에서 실행해야 합니다." } }
function Invoke-Wsl([string[]]$CmdArgs) {
  $ErrorActionPreference = 'Continue'   # PS5.1: Stop + 2> 리다이렉션이면 stderr 한 줄이 예외가 됨
  $prev = [Console]::OutputEncoding
  try { [Console]::OutputEncoding = [System.Text.Encoding]::Unicode; $o = & $WslExe @CmdArgs 2>&1; $script:LastWslExit = $LASTEXITCODE; $o | ForEach-Object { "$_".Trim() } | Where-Object { $_ } }
  finally { [Console]::OutputEncoding = $prev }
}
function Invoke-WslCmd([string]$d, [string[]]$LinuxCmd) {
  # 배포판 안 명령의 출력은 UTF-8 (wsl.exe 자체 메시지는 UTF-16 이라 Invoke-Wsl 과 구분)
  $ErrorActionPreference = 'Continue'
  $prev = [Console]::OutputEncoding
  try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8; $o = & $WslExe -d $d -u root -e @LinuxCmd 2>&1; $script:LastWslExit = $LASTEXITCODE; $o | ForEach-Object { "$_" } }
  finally { [Console]::OutputEncoding = $prev }
}
function Get-WslDistros     { @(Invoke-Wsl @('-l', '-q')) }
function Get-RunningDistros { @(Invoke-Wsl @('-l', '-q', '--running')) }
function Get-WslVersion {
  $l = (Invoke-Wsl @('--version')) | Where-Object { $_ -match '^WSL[^:]*:\s*([\d.]+)' } | Select-Object -First 1
  if ($l) { [version]([regex]::Match($l, '([\d.]+)').Groups[1].Value) } else { $null }
}
function Resolve-Distro([string]$Name) {
  $all = @(Get-WslDistros)
  if ($Name) { $m = $all | Where-Object { $_ -ieq $Name } | Select-Object -First 1; if ($m) { return $m }; throw "배포판 '$Name' 없음. 등록됨: $($all -join ', ')" }
  if ($all.Count -eq 1) { return $all[0] }
  throw "배포판을 -Distro 로 지정하세요. 등록됨: $($all -join ', ')"
}
function Get-DistroInfo([string]$d) {
  $lxss = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
  $k = Get-ChildItem $lxss | Where-Object { (Get-ItemProperty $_.PSPath).DistributionName -ieq $d } | Select-Object -First 1
  if (-not $k) { throw "레지스트리에 배포판 '$d' 가 없습니다." }
  $p = Get-ItemProperty $k.PSPath
  $base = $p.BasePath -replace '^\\\\\?\\', ''
  $vhd = Join-Path $base 'ext4.vhdx'
  if ($p.VhdFileName) { $vhd = Join-Path $base $p.VhdFileName }
  if (-not (Test-Path -LiteralPath $vhd)) { throw "vhdx 를 찾을 수 없습니다: $vhd" }
  [pscustomobject]@{ Name = $p.DistributionName; Version = $p.Version; Vhd = $vhd; Guid = $k.PSChildName }
}

# 실제 디스크 할당 크기 (sparse/압축 파일은 논리 크기보다 작다)
if (-not ('WslTools.Native' -as [type])) {
  Add-Type -Namespace WslTools -Name Native -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
public static extern uint GetCompressedFileSizeW(string lpFileName, out uint lpFileSizeHigh);
'@
}
function Get-AllocatedBytes([string]$path) {
  $hi = [uint32]0; $lo = [WslTools.Native]::GetCompressedFileSizeW($path, [ref]$hi)
  ([uint64]$hi -shl 32) -bor [uint64]$lo
}
function Test-SparseFile([string]$path) { ((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::SparseFile) -ne 0 }
function Test-FileLocked([string]$path) {
  try { $fs = [IO.File]::Open($path, 'Open', 'ReadWrite', 'None'); $fs.Close(); $false } catch { $true }
}
function Get-GuestUsage([string]$d) {
  # df 출력: used size (bytes)
  $o = Invoke-WslCmd $d @('df', '-B1', '--output=used,size', '/') | Select-Object -Last 1
  if ($o -match '^\s*(\d+)\s+(\d+)') { [pscustomobject]@{ Used = [uint64]$matches[1]; Size = [uint64]$matches[2] } } else { $null }
}
function GB($b) { '{0:N1} GB' -f ($b / 1GB) }
function Test-OptimizeVhd {
  # 모듈만 있고 Hyper-V 플랫폼(vmms)이 없는 "관리 도구만 설치" 상태면 Optimize-VHD 가 실패한다
  [bool](Get-Command Optimize-VHD -ErrorAction SilentlyContinue) -and ((Get-Service vmms -ErrorAction SilentlyContinue).Status -eq 'Running')
}
function Resolve-Method {
  if ($Method -ne 'Auto') { return $Method }
  if (Test-OptimizeVhd) { 'OptimizeVHD' } else { 'Diskpart' }
}

function Show-Status([string]$d) {
  $i = Get-DistroInfo $d
  $running = (Get-RunningDistros) -contains $d
  $logical = (Get-Item -LiteralPath $i.Vhd).Length
  $alloc   = Get-AllocatedBytes $i.Vhd
  $sparse  = Test-SparseFile $i.Vhd
  $wslv    = Get-WslVersion
  $guest   = if ($running) { Get-GuestUsage $d } else { $null }
  Write-Host ("배포판         : {0}  (WSL{1}, {2})" -f $i.Name, $i.Version, $(if ($running) { '실행 중' } else { '중지' }))
  Write-Host ("vhdx           : {0}" -f $i.Vhd)
  Write-Host ("파일 크기      : 논리 {0} / 실제 할당 {1}" -f (GB $logical), (GB $alloc))
  Write-Host ("sparse 모드    : {0}" -f $(if ($sparse) { '켬 (fstrim + 종료만으로 자동 회수)' } else { '끔 (압축 필요)' }))
  if ($guest) {
    Write-Host ("게스트 사용량  : {0} 사용 / {1} 가상 디스크" -f (GB $guest.Used), (GB $guest.Size))
    Write-Host ("회수 예상      : 약 {0}  (실제 할당 - 게스트 사용량)" -f (GB ([math]::Max([int64]0, [int64]$alloc - [int64]$guest.Used))))
  } else { Write-Host '게스트 사용량  : (배포판이 실행 중일 때만 표시)' }
  Write-Host ("WSL 버전       : {0}  -> --set-sparse {1}" -f $(if ($wslv) { $wslv } else { '인박스/불명' }), $(if ($wslv -and $wslv -ge [version]'1.3.10') { '지원' } else { '미지원' }))
  Write-Host ("Optimize-VHD   : {0}" -f $(if (Test-OptimizeVhd) { '사용 가능 (Hyper-V 모듈 + vmms 실행 중)' } elseif (Get-Command Optimize-VHD -ErrorAction SilentlyContinue) { '모듈은 있으나 vmms 서비스 없음 -> diskpart 사용' } else { '없음 -> diskpart 사용' }))
  Write-Host ("선택될 방법    : {0}" -f (Resolve-Method))
  $drive = (Split-Path -Qualifier $i.Vhd)
  $free = (Get-PSDrive ($drive.TrimEnd(':'))).Free
  Write-Host ("{0} 여유 공간    : {1}" -f $drive, (GB $free))
  $keep = Get-ScheduledTask -TaskName "WSL-KeepAlive-$d" -ErrorAction SilentlyContinue
  if ($keep) { Write-Host ("KeepAlive 태스크: {0} (압축 중 자동 일시정지됨)" -f $keep.State) }
}

function Invoke-Trim([string]$d) {
  $running = (Get-RunningDistros) -contains $d
  Write-Host "fstrim 실행 중 ($d)..."
  # 루트(vhdx)만 trim. -a 는 /mnt/c 같은 drvfs 마운트까지 시도해 실패할 수 있다.
  $out = Invoke-WslCmd $d @('/sbin/fstrim', '-v', '/')   # -e 는 로그인 PATH 가 아니라 절대 경로 사용
  if ($script:LastWslExit -ne 0) { throw "fstrim 실패 (exit=$script:LastWslExit): $($out -join ' ')" }
  $out | ForEach-Object { Write-Host "  $_" }
  if (-not $running) { Write-Host '  (fstrim 을 위해 배포판을 잠시 띄웠습니다)' }
}

function Stop-DistroForVhd([string]$d, [string]$vhd) {
  Write-Host "배포판 종료: wsl -t $d"
  & $WslExe -t $d | Out-Null
  $deadline = (Get-Date).AddSeconds(30)
  while ((Test-FileLocked $vhd) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
  if (Test-FileLocked $vhd) {
    if ($NoShutdown) { throw 'vhdx 잠금이 풀리지 않았습니다. -NoShutdown 을 빼면 wsl --shutdown 으로 전체 VM 을 내립니다.' }
    Write-Warning 'vhdx 가 아직 잠겨 있어 wsl --shutdown 으로 전체 VM 을 내립니다 (다른 배포판도 종료됨).'
    & $WslExe --shutdown | Out-Null
    $deadline = (Get-Date).AddSeconds(30)
    while ((Test-FileLocked $vhd) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
    if (Test-FileLocked $vhd) { throw 'wsl --shutdown 후에도 vhdx 가 잠겨 있습니다. 다른 프로그램(백업, 탐색기 미리보기 등)이 열고 있는지 확인하세요.' }
  }
}

function Invoke-CompactVhd([string]$vhd, [string]$how) {
  switch ($how) {
    'OptimizeVHD' {
      Write-Host "Optimize-VHD -Mode Full 실행 중 (수 분 걸릴 수 있음)..."
      Optimize-VHD -Path $vhd -Mode Full
    }
    'Diskpart' {
      # diskpart /s 는 ANSI(시스템 코드페이지) 텍스트를 읽는다. 경로에 한글이 있을 수 있으므로 ASCII 로 쓰지 않는다.
      $enc = try { [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage) } catch { [System.Text.Encoding]::Default }
      $script = Join-Path $env:TEMP ("wsl-compact-{0}.txt" -f [guid]::NewGuid())
      $detach = Join-Path $env:TEMP ("wsl-detach-{0}.txt" -f [guid]::NewGuid())
      [IO.File]::WriteAllLines($script, [string[]]@("select vdisk file=`"$vhd`"", 'attach vdisk readonly', 'compact vdisk', 'detach vdisk', 'exit'), $enc)
      [IO.File]::WriteAllLines($detach, [string[]]@("select vdisk file=`"$vhd`"", 'detach vdisk', 'exit'), $enc)
      Write-Host "diskpart compact vdisk 실행 중 (수 분 걸릴 수 있음)..."
      Write-Host "  참고: 읽기 전용으로 붙는 동안 탐색기가 '디스크를 포맷하시겠습니까' 를 띄울 수 있습니다. 취소하세요 (읽기 전용이라 포맷은 불가)."
      $ErrorActionPreference = 'Continue'
      try {
        $out = & diskpart.exe /s $script 2>&1
        $rc = $LASTEXITCODE
        $out | ForEach-Object { Write-Host "  $_" }
        if ($rc -ne 0) {
          # compact 단계에서 실패하면 diskpart 가 스크립트를 중단해 vhdx 가 붙은 채 남는다 -> 반드시 detach
          Write-Warning "diskpart 실패 (exit=$rc). vhdx 를 detach 합니다."
          & diskpart.exe /s $detach 2>&1 | ForEach-Object { Write-Host "  $_" }
          throw "diskpart compact 실패 (exit=$rc)"
        }
      } finally {
        $ErrorActionPreference = 'Stop'
        Remove-Item -LiteralPath $script, $detach -Force -ErrorAction SilentlyContinue
      }
    }
  }
}

switch ($Action) {
  'Status' { Show-Status (Resolve-Distro $Distro) }

  'Trim'   { Invoke-Trim (Resolve-Distro $Distro) }

  'Compact' {
    Assert-Admin
    $d = Resolve-Distro $Distro
    $i = Get-DistroInfo $d
    $how = Resolve-Method
    if ($how -eq 'OptimizeVHD' -and -not (Test-OptimizeVhd)) { throw 'Optimize-VHD 를 쓸 수 없습니다 (Hyper-V 모듈 없음 또는 vmms 서비스 미실행). -Method Diskpart 를 사용하세요.' }
    $isSparse = Test-SparseFile $i.Vhd
    if ($isSparse -and -not $Force) {
      Write-Warning "vhdx 가 sparse 모드입니다. fstrim + 배포판 종료만으로 공간이 회수되므로 압축을 생략합니다 (강제하려면 -Force)."
      if (-not $SkipTrim) { Invoke-Trim $d }
      if ($PSCmdlet.ShouldProcess($d, '배포판 종료(wsl -t)')) { & $WslExe -t $d | Out-Null; Start-Sleep -Seconds 3 }
      Show-Status $d; return
    }
    Show-Status $d
    $before = Get-AllocatedBytes $i.Vhd
    if (-not $PSCmdlet.ShouldProcess($i.Vhd, "vhdx 압축 ($how)")) { return }

    # KeepAlive 일시정지 (이 스크립트가 만든 경우에만 해제)
    $madeFlag = $false
    if ((Test-Path -LiteralPath $KeepAliveDir) -and -not (Test-Path -LiteralPath $PauseFlag)) {
      New-Item -ItemType File -Path $PauseFlag -Force | Out-Null; $madeFlag = $true
      Write-Host "KeepAlive 일시정지 플래그 생성: $PauseFlag"
    }
    try {
      if (-not $SkipTrim) { Invoke-Trim $d }
      Stop-DistroForVhd $d $i.Vhd
      $sw = [Diagnostics.Stopwatch]::StartNew()
      Invoke-CompactVhd $i.Vhd $how
      $sw.Stop()
      $after = Get-AllocatedBytes $i.Vhd
      Write-Host ''
      Write-Host ("완료 ({0:N0}s): {1} -> {2}  (회수 {3})" -f $sw.Elapsed.TotalSeconds, (GB $before), (GB $after), (GB ([math]::Max([int64]0, [int64]$before - [int64]$after)))) -ForegroundColor Green
    } finally {
      if ($madeFlag) { Remove-Item -LiteralPath $PauseFlag -Force -ErrorAction SilentlyContinue; Write-Host 'KeepAlive 일시정지 해제' }
    }
    if ($Restart) { Write-Host "배포판 재시작: $d"; & $WslExe -d $d -e true | Out-Null }
    elseif (-not (Test-Path -LiteralPath $KeepAliveDir)) { Write-Host "배포판은 중지 상태입니다. 시작: wsl -d $d" }
    else { Write-Host 'KeepAlive 루프가 곧 배포판을 다시 띄웁니다 (-Restart 로 즉시 시작 가능).' }
  }

  'SetSparse' {
    Assert-Admin
    if ($null -eq $Sparse) { throw '-Sparse $true 또는 $false 를 지정하세요.' }
    $d = Resolve-Distro $Distro
    $i = Get-DistroInfo $d
    $wslv = Get-WslVersion
    if (-not $wslv -or $wslv -lt [version]'1.3.10') { throw "이 WSL($wslv)은 --set-sparse 를 지원하지 않습니다. Store/MSI 2.x WSL 로 업데이트하세요." }
    if ($Sparse) { Write-Warning 'WSL 2.0.5 이후 sparse 는 기본 비활성(손상 가능성 경고)이라 --allow-unsafe 로 켭니다. 적용 전 vhdx 백업을 권장합니다.' }
    if (-not $PSCmdlet.ShouldProcess($d, "set-sparse $Sparse")) { return }
    $madeFlag = $false
    if ((Test-Path -LiteralPath $KeepAliveDir) -and -not (Test-Path -LiteralPath $PauseFlag)) { New-Item -ItemType File -Path $PauseFlag -Force | Out-Null; $madeFlag = $true }
    try {
      Stop-DistroForVhd $d $i.Vhd
      $cmd = @('--manage', $d, '--set-sparse', $(if ($Sparse) { 'true' } else { 'false' }))
      if ($Sparse) { $cmd += '--allow-unsafe' }
      $out = Invoke-Wsl $cmd
      $out | ForEach-Object { Write-Host "  $_" }
      if ($script:LastWslExit -ne 0) { throw "wsl --manage --set-sparse 실패 (exit=$script:LastWslExit): $($out -join ' ')" }
    } finally { if ($madeFlag) { Remove-Item -LiteralPath $PauseFlag -Force -ErrorAction SilentlyContinue } }
    Show-Status $d
  }
}
