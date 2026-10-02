<#
.SYNOPSIS
  Internal scheduled-task loop. Installed to Windows ProgramData by WSL-KeepAlive.
.DESCRIPTION
  Uses a guest sleep process to keep WSL alive. A global pause flag prevents relaunch.
#>
param(
  [Parameter(Mandatory = $true)][string]$Distro,
  [string]$FlagPath = 'C:\ProgramData\WSL-KeepAlive\flags\paused',
  [int]$RetrySeconds = 5,
  [int]$PausePollSeconds = 10
)

. (Join-Path $PSScriptRoot 'Wsl-Guest.ps1')
$guestArgs = @(Get-WslGuestArguments @('sleep', 'infinity'))

$wsl    = Join-Path $env:SystemRoot 'System32\wsl.exe'
$logDir = Split-Path -Parent (Split-Path -Parent $FlagPath)
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
  Write-Log "launch: wsl -d $Distro sleep infinity (guest PATH)"
  & $wsl -d $Distro @guestArgs
  Write-Log ("wsl exited code={0}" -f $LASTEXITCODE)
  Start-Sleep -Seconds $RetrySeconds
}
