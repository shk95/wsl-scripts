<#
.SYNOPSIS
  Manage WSL KeepAlive scheduled tasks.
.DESCRIPTION
  List shows distributions and tasks. Status shows task, pause, process and log state.
  Install registers and starts a startup task (administrator); Uninstall removes it.
  Enable enables and starts a task; Disable disables and stops it (administrator).
  Pause prevents all installed loops from relaunching; Resume removes that global pause.
  Install copies the internal loop and guest command helper to Windows ProgramData.
  Reinstall existing tasks to update their copied helpers for NixOS-WSL support.
.PARAMETER Action
  List, Status, Install, Uninstall, Enable, Disable, Pause or Resume.
.PARAMETER Distro
  Registered distribution name. May be omitted when only one distribution exists. List and Status can show all.
.PARAMETER Shutdown
  For Pause or Disable, also run wsl --shutdown (stops every distribution).
.PARAMETER Credential
  Install task account credentials; must own the distribution. Prompts if omitted.
.PARAMETER Help
  Show full help and exit without accessing Windows or WSL.
.EXAMPLE
  .\scripts\WSL-KeepAlive.ps1 -Action List
.EXAMPLE
  .\scripts\WSL-KeepAlive.ps1 -Action Install -Distro NixOS
.EXAMPLE
  .\scripts\WSL-KeepAlive.ps1 -Action Pause -Distro NixOS -Shutdown
.EXAMPLE
  .\scripts\WSL-KeepAlive.ps1 -Action Resume -Distro NixOS
.EXAMPLE
  .\scripts\WSL-KeepAlive.ps1 -Help
#>
[CmdletBinding()]
param(

  [ValidateSet('List', 'Status', 'Install', 'Uninstall', 'Enable', 'Disable', 'Pause', 'Resume')]
  [string]$Action,

  [string]$Distro,

  [switch]$Shutdown,

  [System.Management.Automation.PSCredential]$Credential,
  [switch]$Help
)

if ($Help) { Get-Help -Name $PSCommandPath -Full; return }
if (-not $Action) { throw 'Specify -Action, or use -Help for usage.' }
if ($env:OS -ne 'Windows_NT') { throw 'Run this script in Windows PowerShell on the Windows host.' }

$ErrorActionPreference = 'Stop'
$BaseDir   = 'C:\ProgramData\WSL-KeepAlive'
$FlagDir   = Join-Path $BaseDir 'flags'
$FlagPath  = Join-Path $FlagDir 'paused'
$LoopName  = 'keepalive-loop.ps1'
$InternalDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'internal'
$LoopSrc   = Join-Path $InternalDir $LoopName
$GuestSrc  = Join-Path $InternalDir 'Wsl-Guest.ps1'
$GuestDst  = Join-Path $BaseDir 'Wsl-Guest.ps1'
$LoopDst   = Join-Path $BaseDir $LoopName
$WslExe    = Join-Path $env:SystemRoot 'System32\wsl.exe'
$PsExe     = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$TaskPrefix = 'WSL-KeepAlive-'

# ---------- helpers ----------
function Test-Admin {
  ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Assert-Admin { if (-not (Test-Admin)) { throw "Action=$Action requires an elevated Windows PowerShell session." } }

function Invoke-Wsl {

  param([string[]]$CmdArgs)
  $ErrorActionPreference = 'Continue'
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
    throw "Distribution '$Name' is not registered. Registered distributions: $($all -join ', ')"
  }
  if ($all.Count -eq 1) { return $all[0] }
  if ($all.Count -eq 0) { throw 'No WSL distributions are registered.' }
  throw "Specify -Distro. Registered distributions: $($all -join ', ')"
}

function Get-TaskName([string]$d) { "$TaskPrefix$d" }
function Get-KeepAliveTasks { @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like "$TaskPrefix*" }) }

function Get-LoopProcesses([string]$d) {

  Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object {
    $_.CommandLine -and ($_.CommandLine -match 'keepalive-loop\.ps1' -or $_.CommandLine -match "sleep['`"]?\s+['`"]?infinity") -and
    (-not $d -or $_.CommandLine -match ('(?i)(?:-Distro|-d|--distribution)\s+(?:"' + [regex]::Escape($d) + '"|' + [regex]::Escape($d) + ')(?=\s|$)'))
  }
}
function Get-HoldProcesses([string]$d) {
  Get-CimInstance Win32_Process -Filter "Name='wsl.exe'" | Where-Object {
    $_.CommandLine -and $_.CommandLine -match "sleep['`"]?\s+['`"]?infinity" -and (-not $d -or $_.CommandLine -match ('(?i)(?:-Distro|-d|--distribution)\s+(?:"' + [regex]::Escape($d) + '"|' + [regex]::Escape($d) + ')(?=\s|$)'))
  }
}
function Stop-LoopAndHold([string]$d) {
  foreach ($p in @(Get-LoopProcesses $d) + @(Get-HoldProcesses $d)) {
    Write-Host ("  Stopping process: {0} PID={1}" -f $p.Name, $p.ProcessId)
    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
  }
}
function Test-Paused { Test-Path -LiteralPath $FlagPath }

function Show-Status([string]$d) {
  $tasks = if ($d) { @(Get-ScheduledTask -TaskName (Get-TaskName $d) -ErrorAction SilentlyContinue) } else { Get-KeepAliveTasks }
  $running = Get-RunningDistros
  Write-Host ("Running distributions : {0}" -f $(if ($running) { $running -join ', ' } else { '(None)' }))
  Write-Host ("Pause flag : {0}  ({1})" -f $(if (Test-Paused) { 'PAUSED' } else { 'None' }), $FlagPath)
  if (-not $tasks) { Write-Host 'KeepAlive task : None'; return }
  foreach ($t in $tasks) {
    $name = $t.TaskName; $dn = $name.Substring($TaskPrefix.Length)
    $info = Get-ScheduledTaskInfo -TaskName $name -ErrorAction SilentlyContinue
    $loop = @(Get-LoopProcesses $dn); $hold = @(Get-HoldProcesses $dn)
    $legacy = ($t.Actions | ForEach-Object { $_.Arguments }) -join ' ' -notmatch 'keepalive-loop\.ps1'
    Write-Host ''
    Write-Host ("[{0}]" -f $name)
    Write-Host ("  State        : {0}   Enabled={1}   {2}" -f $t.State, $t.Settings.Enabled, $(if ($legacy) { '(legacy inline loop: reinstall using Install)' } else { '' }))
    Write-Host ("  Last run : {0}   Result=0x{1:X}" -f $info.LastRunTime, $info.LastTaskResult)
    Write-Host ("  Loop process: {0}" -f $(if ($loop) { ($loop | ForEach-Object { "PID=$($_.ProcessId)" }) -join ', ' } else { 'None' }))
    Write-Host ("  Hold wsl.exe : {0}" -f $(if ($hold) { ($hold | ForEach-Object { "PID=$($_.ProcessId)" }) -join ', ' } else { 'None' }))
    $log = Join-Path $BaseDir "keepalive-$dn.log"
    if (Test-Path -LiteralPath $log) {
      Write-Host '  Recent log   :'
      Get-Content -LiteralPath $log -Tail 5 | ForEach-Object { Write-Host "    $_" }
    }
  }
}

# ---------- actions ----------
switch ($Action) {

  'List' {
    Write-Host ('Registered distributions : ' + ((Get-WslDistros) -join ', '))
    Write-Host ('Running distributions: ' + ((Get-RunningDistros) -join ', '))
    $tasks = Get-KeepAliveTasks
    Write-Host ('KeepAlive task: ' + $(if ($tasks) { ($tasks | ForEach-Object { "$($_.TaskName)[$($_.State)]" }) -join ', ' } else { 'None' }))
  }

  'Status' {
    $d = if ($Distro) { Resolve-Distro $Distro -AllowUnregistered } else { $null }
    Show-Status $d
  }

  'Install' {
    Assert-Admin
    $d = Resolve-Distro $Distro
    if (-not (Test-Path -LiteralPath $LoopSrc)) { throw "Loop script not found: $LoopSrc" }
    if (-not (Test-Path -LiteralPath $GuestSrc)) { throw "Guest helper not found: $GuestSrc" }
    if (-not $Credential) {
      $Credential = Get-Credential -UserName "$env:USERDOMAIN\$env:USERNAME" -Message "KeepAlive task account (owner of distribution '$d')"
      if (-not $Credential) { throw 'Credentials are required.' }
    }
    New-Item -ItemType Directory -Force -Path $BaseDir, $FlagDir | Out-Null

    # Only flags are user-writable; elevated task code must remain protected.
    $acl  = Get-Acl -LiteralPath $FlagDir
    $sid  = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545')
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($sid, 'Modify', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
    $acl.AddAccessRule($rule); Set-Acl -LiteralPath $FlagDir -AclObject $acl
    Copy-Item -LiteralPath $GuestSrc -Destination $GuestDst -Force
    Copy-Item -LiteralPath $LoopSrc -Destination $LoopDst -Force

    $name = Get-TaskName $d
    if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
      Write-Host "Replacing existing task $name."
      Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
      Unregister-ScheduledTask -TaskName $name -Confirm:$false
      Stop-LoopAndHold $d
    }
    $arg = "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$LoopDst`" -Distro `"$d`" -FlagPath `"$FlagPath`""

    $taskAction = New-ScheduledTaskAction -Execute $PsExe -Argument $arg
    $trigger  = New-ScheduledTaskTrigger -AtStartup
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                  -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    $settings.ExecutionTimeLimit = 'PT0S'
    Register-ScheduledTask -TaskName $name -Action $taskAction -Trigger $trigger -Settings $settings `
      -User $Credential.UserName -Password $Credential.GetNetworkCredential().Password -RunLevel Highest | Out-Null
    Remove-Item -LiteralPath $FlagPath -Force -ErrorAction SilentlyContinue
    Start-ScheduledTask -TaskName $name
    Write-Host "Installed: $name"
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
      Write-Host "Task removed: $name"
    } else { Write-Host "Task not found: $name" }
    Stop-LoopAndHold $d
    if (-not (Get-KeepAliveTasks)) {
      Remove-Item -LiteralPath $LoopDst, $GuestDst, $FlagPath -Force -ErrorAction SilentlyContinue
      Write-Host "Removed $LoopDst because no KeepAlive tasks remain. Logs remain in $BaseDir."
    }
    Write-Host 'The VM was left running. To stop it now: wsl --shutdown'
  }

  'Enable' {
    Assert-Admin
    $d = Resolve-Distro $Distro -AllowUnregistered
    $name = Get-TaskName $d
    if (-not (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue)) { throw "Task not found: $name (run -Action Install first)" }
    Remove-Item -LiteralPath $FlagPath -Force -ErrorAction SilentlyContinue
    Enable-ScheduledTask -TaskName $name | Out-Null
    Start-ScheduledTask  -TaskName $name
    Write-Host "Enabled and started: $name"
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
      Write-Host "Disabled and stopped: $name"
    } else { Write-Host "Task not found: $name" }
    Stop-LoopAndHold $d
    if ($Shutdown) { & $WslExe --shutdown; Write-Host 'Ran wsl --shutdown' }
    else { Write-Host 'The loop is stopped. Add -Shutdown or run wsl --shutdown to stop the VM now.' }
    Show-Status $d
  }

  'Pause' {
    $d = Resolve-Distro $Distro -AllowUnregistered
    if (-not (Test-Path -LiteralPath $FlagDir)) { throw "$FlagDir does not exist. Run -Action Install first." }
    New-Item -ItemType File -Force -Path $FlagPath | Out-Null
    Write-Host "Created pause flag: $FlagPath (applies to all KeepAlive loops)"
    if ($Shutdown) { & $WslExe --shutdown; Write-Host 'Ran wsl --shutdown. KeepAlive will not restart distributions until Resume.' }
    else { Write-Host 'The VM is running. KeepAlive will not restart it after it stops. Use -Shutdown to stop it now.' }
    Show-Status $d
  }

  'Resume' {
    $d = Resolve-Distro $Distro -AllowUnregistered
    Remove-Item -LiteralPath $FlagPath -Force -ErrorAction SilentlyContinue
    Write-Host 'Pause cleared.'
    $name = Get-TaskName $d
    $t = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    if ($t -and $t.State -ne 'Running') {
      try { Start-ScheduledTask -TaskName $name; Write-Host "Task started: $name" }
      catch { Write-Warning "The task is not running. Run -Action Enable in elevated Windows PowerShell. ($_)" }
    } elseif ($t) { Write-Host 'The loop will restart the distribution within 10 seconds.' }
    else { Write-Warning "Task not found: $name (run -Action Install)" }
    Show-Status $d
  }
}
