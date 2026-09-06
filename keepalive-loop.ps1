<#
.SYNOPSIS
  WSL KeepAlive 루프 본체. 스케줄 태스크가 실행하며, 지정 배포판에 sleep infinity 를 붙잡아 VM을 유지한다.
  WSL-KeepAlive.ps1 -Action Install 이 이 파일을 C:\ProgramData\WSL-KeepAlive\ 로 복사해 등록한다.
  (WSL 안의 경로를 태스크가 직접 가리키면 WSL이 꺼져 있을 때 스크립트를 읽을 수 없으므로 반드시 복사본을 쓴다.)

  일시정지: $FlagPath 파일이 존재하면 배포판을 다시 띄우지 않고 대기한다.
#>
param(
  [Parameter(Mandatory = $true)][string]$Distro,
  [string]$FlagPath = 'C:\ProgramData\WSL-KeepAlive\flags\paused',
  [int]$RetrySeconds = 5,
  [int]$PausePollSeconds = 10
)

$wsl    = Join-Path $env:SystemRoot 'System32\wsl.exe'
$logDir = Split-Path -Parent (Split-Path -Parent $FlagPath)   # flags\ 의 상위 = C:\ProgramData\WSL-KeepAlive
$log    = Join-Path $logDir ("keepalive-{0}.log" -f $Distro)

function Write-Log([string]$msg) {
  try {
    if ((Test-Path -LiteralPath $log) -and ((Get-Item -LiteralPath $log).Length -gt 1MB)) {
      $tail = Get-Content -LiteralPath $log -Tail 200
      Set-Content -LiteralPath $log -Value $tail
    }
    Add-Content -LiteralPath $log -Value ("{0} {1}" -f (Get-Date -Format 's'), $msg)
  } catch { }
}

Write-Log "loop start (pid=$PID distro=$Distro)"
while ($true) {
  if (Test-Path -LiteralPath $FlagPath) { Start-Sleep -Seconds $PausePollSeconds; continue }
  Write-Log "launch: wsl -d $Distro --exec /usr/bin/sleep infinity"
  & $wsl -d $Distro --exec /usr/bin/sleep infinity
  Write-Log ("wsl exited code={0}" -f $LASTEXITCODE)
  Start-Sleep -Seconds $RetrySeconds
}
