<#
.SYNOPSIS
  Manage a Windows power scheme that keeps WSL awake.
.DESCRIPTION
  Enable backs up the active scheme, creates a WSL KeepAwake copy and disables AC sleep.
  Battery settings are retained unless KeepAwakeOnBattery is requested.
  Restore activates the original scheme and removes the copy. Enable/Restore require
  administrator privileges. Status shows power settings and backup state.
.PARAMETER Action
  Enable, Restore or Status.
.PARAMETER Laptop
  Override automatic detection and use laptop settings.
.PARAMETER Desktop
  Override automatic detection and use desktop settings.
.PARAMETER LidAction
  Laptop lid action: DoNothing (default), Sleep, Hibernate or Shutdown.
.PARAMETER KeepAwakeOnBattery
  Also disable sleep on battery and apply the lid action; increases battery drain.
.PARAMETER MonitorTimeoutMinutes
  AC display timeout in minutes; 0 means never, omitted means unchanged.
.PARAMETER DisableHibernate
  Disable hibernation and Fast Startup; Restore restores prior hibernation state.
.PARAMETER Help
  Show full help and exit without accessing Windows or WSL.
.EXAMPLE
  .\scripts\WSL-PowerGuard.ps1 -Action Status
.EXAMPLE
  .\scripts\WSL-PowerGuard.ps1 -Action Enable -Laptop -LidAction DoNothing
.EXAMPLE
  .\scripts\WSL-PowerGuard.ps1 -Action Restore
.EXAMPLE
  .\scripts\WSL-PowerGuard.ps1 -Help
#>
[CmdletBinding()]
param(
  [ValidateSet('Enable', 'Restore', 'Status')][string]$Action,
  [switch]$Laptop,
  [switch]$Desktop,
  [ValidateSet('DoNothing', 'Sleep', 'Hibernate', 'Shutdown')][string]$LidAction = 'DoNothing',
  [switch]$KeepAwakeOnBattery,
  [int]$MonitorTimeoutMinutes = -1,
  [switch]$DisableHibernate,
  [switch]$Help
)

if ($Help) { Get-Help -Name $PSCommandPath -Full; return }
if (-not $Action) { throw 'Specify -Action, or use -Help for usage.' }
if ($env:OS -ne 'Windows_NT') { throw 'Run this script in Windows PowerShell on the Windows host.' }

$ErrorActionPreference = 'Stop'
$BaseDir    = 'C:\ProgramData\WSL-PowerGuard'
$BackupJson = Join-Path $BaseDir 'backup.json'
$BackupPow  = Join-Path $BaseDir 'original-scheme.pow'
$SchemeName = 'WSL KeepAwake'

$SUB_SLEEP   = '238c9fa8-0aad-41ed-83f4-97be242c8f20'
$STANDBYIDLE = '29f6c1db-86da-48c5-9fdb-f2b67b1f44da'
$HIBERIDLE   = '9d7815a6-7ee4-497e-8888-515a05f02364'
$HYBRIDSLEEP = '94ac6d29-73ce-41a6-809f-6363ba21b47e'
$UNATTENDED  = '7bc4a2f9-d8fc-4469-b07b-33eb785aaca0'
$SUB_VIDEO   = '7516b95f-f776-4464-8c53-06167f40cc99'
$VIDEOIDLE   = '3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e'
$SUB_DISK    = '0012ee47-9041-4b5d-9b77-535fba8b1442'
$DISKIDLE    = '6738e2c4-e8a5-4a42-b16a-e040e769756e'
$SUB_BUTTONS = '4f971e89-eebd-4455-a8de-9e59040e7347'
$LID_GUID    = '5ca83367-6e45-459f-a27b-476b1d01c936'
$SUB_NONE    = 'fea3413e-7e05-4911-9a71-700331f1c294'
$CONNSTANDBY = 'f15576e8-98b7-4186-b944-eafa664402d9'
$LidMap = @{ DoNothing = 0; Sleep = 1; Hibernate = 2; Shutdown = 3 }
$LidNames = @{ 0 = 'DoNothing'; 1 = 'Sleep'; 2 = 'Hibernate'; 3 = 'Shutdown' }

function Test-Admin { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
function Assert-Admin { if (-not (Test-Admin)) { throw "Action=$Action requires an elevated Windows PowerShell session." } }
function Pc {
  param([string[]]$CmdArgs)
  $ErrorActionPreference = 'Continue'
  $o = & powercfg.exe @CmdArgs 2>&1
  if ($LASTEXITCODE -ne 0) { throw "powercfg $($CmdArgs -join ' ') failed: $o" }
  $o
}
function Pc-Try {
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

  $ErrorActionPreference = 'Continue'
  $out = (& powercfg.exe /q SCHEME_CURRENT $sub $setting 2>&1) -join "`n"
  $ac = [regex]::Match($out, '(?im)AC[^\n]*:\s*0x([0-9a-f]+)').Groups[1].Value
  $dc = [regex]::Match($out, '(?im)DC[^\n]*:\s*0x([0-9a-f]+)').Groups[1].Value
  [pscustomobject]@{ AC = $(if ($ac) { [convert]::ToInt64($ac, 16) } else { $null }); DC = $(if ($dc) { [convert]::ToInt64($dc, 16) } else { $null }) }
}
function Format-Timeout($sec) { if ($null -eq $sec) { 'n/a' } elseif ($sec -eq 0) { 'Never (0)' } else { "{0} min" -f [int]($sec / 60) } }
function Get-HibernateEnabled { (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -Name HibernateEnabled -ErrorAction SilentlyContinue).HibernateEnabled -eq 1 }

function Show-Status {
  $isLaptop = Test-Laptop
  $act = Get-ActiveScheme
  Write-Host ("Device type        : {0}" -f $(if ($isLaptop) { 'Laptop (battery detected)' } else { 'Desktop' }))
  Write-Host ("Active scheme      : {0}  ({1})" -f $act.Name, $act.Guid)
  Write-Host ("PowerGuard backup  : {0}" -f $(if (Test-Path $BackupJson) { "Present -> Enable applied ($BackupJson)" } else { 'None (original state)' }))
  $sb = Get-SettingIndex $SUB_SLEEP $STANDBYIDLE; $hb = Get-SettingIndex $SUB_SLEEP $HIBERIDLE
  $vd = Get-SettingIndex $SUB_VIDEO $VIDEOIDLE;   $dk = Get-SettingIndex $SUB_DISK $DISKIDLE
  $hy = Get-SettingIndex $SUB_SLEEP $HYBRIDSLEEP; $ua = Get-SettingIndex $SUB_SLEEP $UNATTENDED
  $ld = Get-SettingIndex $SUB_BUTTONS $LID_GUID
  Write-Host ''
  Write-Host ('{0,-18}{1,-16}{2}' -f 'Setting', 'AC (plugged in)', 'DC (battery)')
  Write-Host ('{0,-18}{1,-16}{2}' -f 'Sleep timeout', (Format-Timeout $sb.AC), (Format-Timeout $sb.DC))
  Write-Host ('{0,-18}{1,-16}{2}' -f 'Hibernate timeout', (Format-Timeout $hb.AC), (Format-Timeout $hb.DC))
  Write-Host ('{0,-18}{1,-16}{2}' -f 'Unattended sleep', (Format-Timeout $ua.AC), (Format-Timeout $ua.DC))
  Write-Host ('{0,-18}{1,-16}{2}' -f 'Display timeout', (Format-Timeout $vd.AC), (Format-Timeout $vd.DC))
  Write-Host ('{0,-18}{1,-16}{2}' -f 'Disk timeout', (Format-Timeout $dk.AC), (Format-Timeout $dk.DC))
  Write-Host ('{0,-18}{1,-16}{2}' -f 'Hybrid sleep', $(if ($hy.AC -eq 0) { 'Off' } else { 'On' }), $(if ($hy.DC -eq 0) { 'Off' } else { 'On' }))
  if ($isLaptop) { Write-Host ('{0,-18}{1,-16}{2}' -f 'Lid action', $LidNames[[int]$ld.AC], $LidNames[[int]$ld.DC]) }
  Write-Host ''
  Write-Host ("Hibernation : {0}" -f $(if (Get-HibernateEnabled) { 'Enabled' } else { 'Disabled' }))
  Write-Host 'Current power requests (powercfg /requests):'
  $ErrorActionPreference = 'Continue'
  $req = & powercfg.exe /requests 2>&1
  $ErrorActionPreference = 'Stop'
  if ($LASTEXITCODE -eq 0) { $req | ForEach-Object { Write-Host "  $_" } } else { Write-Host '  (administrator privileges required)' }
  $ok = ($sb.AC -eq 0 -and $hb.AC -eq 0)
  Write-Host ''
  Write-Host ("Assessment on AC power: {0}" -f $(if ($ok) { 'Sleep disabled - WSL can stay running' } else { 'Sleep timeout configured; WSL may stop -> -Action Enable' })) -ForegroundColor $(if ($ok) { 'Green' } else { 'Yellow' })
  if ($isLaptop -and ($ld.AC -ne 0)) { Write-Host '      Laptop: closing the lid on AC may sleep/shutdown -> -Action Enable -LidAction DoNothing' -ForegroundColor Yellow }
}

switch ($Action) {
  'Status' { Show-Status }

  'Enable' {
    Assert-Admin
    $isLaptop = Test-Laptop
    if (Test-Path $BackupJson) {
      Write-Warning "Enable is already applied (backup: $BackupJson). Reapplying settings while preserving the original backup."
      $bk = Get-Content $BackupJson -Raw | ConvertFrom-Json
      $target = $bk.NewGuid
      if (-not (Get-SchemeList | Where-Object Guid -eq $target)) { throw "Scheme $target recorded in the backup is missing. Run -Action Restore and retry." }
    } else {
      New-Item -ItemType Directory -Force -Path $BaseDir | Out-Null
      $orig = Get-ActiveScheme
      Pc @('/export', $BackupPow, $orig.Guid) | Out-Null
      $dupOut = (Pc @('/duplicatescheme', $orig.Guid)) -join ' '
      $target = [regex]::Match($dupOut, '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}').Value
      if (-not $target) { throw "Failed to duplicate scheme: $dupOut" }
      Pc @('/changename', $target, "$SchemeName (Original: $($orig.Name))") | Out-Null
      [pscustomobject]@{
        OriginalGuid = $orig.Guid; OriginalName = $orig.Name; NewGuid = $target
        HibernateWasEnabled = (Get-HibernateEnabled); AppliedAt = (Get-Date -Format 's'); IsLaptop = $isLaptop
      } | ConvertTo-Json | Set-Content -Path $BackupJson -Encoding UTF8
      Write-Host "Original scheme backed up: $($orig.Name) -> $BackupPow"
    }
    Pc @('/setactive', $target) | Out-Null

    Pc @('/setacvalueindex', $target, $SUB_SLEEP, $STANDBYIDLE, '0') | Out-Null
    Pc @('/setacvalueindex', $target, $SUB_SLEEP, $HIBERIDLE,   '0') | Out-Null
    Pc @('/setacvalueindex', $target, $SUB_SLEEP, $HYBRIDSLEEP, '0') | Out-Null
    Pc-Try @('/setacvalueindex', $target, $SUB_SLEEP, $UNATTENDED, '0')
    Pc @('/setacvalueindex', $target, $SUB_DISK,  $DISKIDLE,    '0') | Out-Null
    Pc-Try @('/setacvalueindex', $target, $SUB_NONE, $CONNSTANDBY, '1')
    if ($MonitorTimeoutMinutes -ge 0) { Pc @('/setacvalueindex', $target, $SUB_VIDEO, $VIDEOIDLE, [string]($MonitorTimeoutMinutes * 60)) | Out-Null }

    if ($isLaptop) {
      Pc @('/setacvalueindex', $target, $SUB_BUTTONS, $LID_GUID, [string]$LidMap[$LidAction]) | Out-Null
      if ($KeepAwakeOnBattery) {
        Pc @('/setdcvalueindex', $target, $SUB_SLEEP, $STANDBYIDLE, '0') | Out-Null
        Pc @('/setdcvalueindex', $target, $SUB_SLEEP, $HIBERIDLE,   '0') | Out-Null
        Pc-Try @('/setdcvalueindex', $target, $SUB_SLEEP, $UNATTENDED, '0')
        Pc @('/setdcvalueindex', $target, $SUB_BUTTONS, $LID_GUID, [string]$LidMap[$LidAction]) | Out-Null
        Write-Host "Laptop: sleep disabled on battery; lid action=$LidAction (increases battery drain)"
      } else {
        Write-Host "Laptop: AC lid action=$LidAction. Original battery policy retained; use -KeepAwakeOnBattery to override."
      }
    }
    if ($DisableHibernate) { Pc @('/hibernate', 'off') | Out-Null; Write-Host 'Hibernation disabled (Fast Startup also disabled)' }
    Pc @('/setactive', $target) | Out-Null
    Write-Host "Applied: scheme '$SchemeName' is active."
    Write-Host ''
    Show-Status
  }

  'Restore' {
    Assert-Admin
    if (-not (Test-Path $BackupJson)) { throw "No backup found ($BackupJson). Enable has not been applied or Restore has already completed." }
    $bk = Get-Content $BackupJson -Raw | ConvertFrom-Json
    $list = Get-SchemeList
    if ($list | Where-Object Guid -eq $bk.OriginalGuid) {
      Pc @('/setactive', $bk.OriginalGuid) | Out-Null
      Write-Host "Original scheme activated: $($bk.OriginalName)"
    } elseif (Test-Path $BackupPow) {
      $imp = (Pc @('/import', $BackupPow)) -join ' '
      $g = [regex]::Match($imp, '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}').Value
      if (-not $g) { throw "Backup import failed: $imp" }
      Pc @('/changename', $g, $bk.OriginalName) | Out-Null
      Pc @('/setactive', $g) | Out-Null
      Write-Host "Original scheme missing; restored from backup: $($bk.OriginalName) ($g)"
    } else { throw 'Cannot restore: neither the original scheme nor its backup file exists.' }
    if ($list | Where-Object Guid -eq $bk.NewGuid) { Pc @('/delete', $bk.NewGuid) | Out-Null; Write-Host "Scheme deleted: $SchemeName" }
    if ($bk.HibernateWasEnabled -and -not (Get-HibernateEnabled)) { Pc @('/hibernate', 'on') | Out-Null; Write-Host 'Hibernation restored (enabled)' }
    Move-Item -Force $BackupJson (Join-Path $BaseDir ("restored-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss')))
    Remove-Item -Force $BackupPow -ErrorAction SilentlyContinue
    Write-Host 'Restore completed.'
    Write-Host ''
    Show-Status
  }
}
