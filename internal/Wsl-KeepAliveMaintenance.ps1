# Internal maintenance transaction. Suspend all managed tasks because lock recovery may
# use wsl --shutdown. Snapshot before mutation; restore only the state changed here.
function New-KeepAliveMaintenanceState {
  param([string]$PauseFlag)
  [pscustomobject]@{
    PauseFlag = $PauseFlag
    MadeFlag = $false
    Tasks = @()
    Gate = $null
  }
}

function Suspend-KeepAliveForMaintenance {
  param($State)
  # Prevent two Compact/SetSparse runs from restoring each other's task snapshots.
  $State.Gate = New-Object System.Threading.Mutex($false, 'Global\WslScripts-VhdMaintenance')
  try { $acquired = $State.Gate.WaitOne(0) }
  catch [System.Threading.AbandonedMutexException] { $acquired = $true }
  if (-not $acquired) {
    $State.Gate.Dispose(); $State.Gate = $null
    throw 'Another WSL disk maintenance operation is running.'
  }
  $tasks = @(Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.TaskName -like 'WSL-KeepAlive-*' })
  if ($tasks.Count -eq 0) { return }
  $flagDir = Split-Path -Parent $State.PauseFlag
  New-Item -ItemType Directory -Path $flagDir -Force | Out-Null
  if (-not (Test-Path -LiteralPath $State.PauseFlag)) {
    # Do not claim ownership of an existing user pause.
    New-Item -ItemType File -Path $State.PauseFlag -ErrorAction Stop | Out-Null
    $State.MadeFlag = $true
  }
  foreach ($task in $tasks) {
    $saved = [pscustomobject]@{
      Name = $task.TaskName
      Path = $task.TaskPath
      Enabled = [bool]$task.Settings.Enabled
      Running = $task.State -eq 'Running'
      Changed = $false
    }
    $State.Tasks += $saved
    # Record intent before mutation so partial failures still attempt recovery.
    $saved.Changed = $true
    Disable-ScheduledTask -TaskName $saved.Name -TaskPath $saved.Path -ErrorAction Stop | Out-Null
    Stop-ScheduledTask -TaskName $saved.Name -TaskPath $saved.Path -ErrorAction Stop
    Write-Host "Suspended KeepAlive task: $($saved.Name)"
  }
  # Legacy inline loops ignore pause flags. Also stop orphaned installed loops and
  # their wsl.exe holders; identify an exact distro argument, not a substring.
  $distros = @($tasks | ForEach-Object { $_.TaskName.Substring('WSL-KeepAlive-'.Length) })
  $processes = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='wsl.exe'" -ErrorAction Stop)
  foreach ($process in $processes) {
    $line = $process.CommandLine
    if (-not $line -or $line -notmatch "keepalive-loop\.ps1|sleep['`"]?\s+['`"]?infinity") { continue }
    foreach ($distro in $distros) {
      $escaped = [regex]::Escape($distro)
      if ($line -match ('(?i)(?:-Distro|-d|--distribution)\s+(?:"' + $escaped + '"|' + $escaped + ')(?=\s|$)')) {
        try { Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop }
        catch {
          if (Get-Process -Id $process.ProcessId -ErrorAction SilentlyContinue) { throw }
        }
        break
      }
    }
  }
}

function Restore-KeepAliveAfterMaintenance {
  param($State)
  $failures = @()
  try {
    if ($State.MadeFlag) {
      try { Remove-Item -LiteralPath $State.PauseFlag -Force -ErrorAction Stop }
      catch { $failures += "Pause flag $($State.PauseFlag): $_" }
    }
    foreach ($saved in $State.Tasks) {
      if (-not $saved.Changed) { continue }
      try {
        if ($saved.Enabled) {
          Enable-ScheduledTask -TaskName $saved.Name -TaskPath $saved.Path -ErrorAction Stop | Out-Null
          if ($saved.Running) {
            Start-ScheduledTask -TaskName $saved.Name -TaskPath $saved.Path -ErrorAction Stop
          }
        } else {
          Disable-ScheduledTask -TaskName $saved.Name -TaskPath $saved.Path -ErrorAction Stop | Out-Null
        }
        Write-Host "Restored KeepAlive task: $($saved.Name) (Enabled=$($saved.Enabled), Running=$($saved.Running))"
      } catch { $failures += "Task $($saved.Name): $_" }
    }
  } finally {
    if ($State.Gate) { $State.Gate.ReleaseMutex(); $State.Gate.Dispose(); $State.Gate = $null }
  }
  if ($failures.Count) { throw ('KeepAlive recovery incomplete. ' + ($failures -join '; ')) }
}
