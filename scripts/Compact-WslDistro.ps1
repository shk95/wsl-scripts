<#
.SYNOPSIS
  Trim and compact a WSL 2 virtual disk.
.DESCRIPTION
  Status reports VHDX allocation, guest usage and available compaction methods.
  Trim runs fstrim on the guest root filesystem. Compact trims, stops the distribution,
  waits for the disk to unlock and compacts it using Optimize-VHD or diskpart.
  Sparse disks use the trim/stop path unless Force is supplied.
  Compact and SetSparse temporarily suspend installed KeepAlive tasks and restore
  their enabled/running state in finally, preserving an existing manual pause.
  Enabled but stopped tasks remain stopped. Without KeepAlive, the distribution stays
  stopped unless Restart is requested. Compact/SetSparse require administrator privileges.
  WhatIf previews the operation without trimming, suspending tasks or stopping WSL.
  Guest tools are resolved through a shell PATH including stable NixOS system profiles.
.PARAMETER Action
  Status, Trim, Compact or SetSparse.
.PARAMETER Distro
  Registered distribution name; may be omitted when only one exists.
.PARAMETER Method
  Auto (default), OptimizeVHD or Diskpart. Auto checks Hyper-V module and vmms.
.PARAMETER SkipTrim
  Skip the trim step during Compact.
.PARAMETER NoShutdown
  Fail if termination does not unlock the disk; do not shut down all WSL distributions.
.PARAMETER Restart
  Explicitly start the target after a successful Compact; does not enable KeepAlive or remove a manual pause.
.PARAMETER Force
  Attempt manual compaction even for a sparse VHDX.
.PARAMETER Sparse
  For SetSparse, specify $true or $false; sparse enabling uses --allow-unsafe.
.PARAMETER Help
  Show full help and exit without accessing Windows or WSL.
.EXAMPLE
  .\scripts\Compact-WslDistro.ps1 -Action Status -Distro NixOS
.EXAMPLE
  .\scripts\Compact-WslDistro.ps1 -Action Compact -Distro NixOS -WhatIf
.EXAMPLE
  .\scripts\Compact-WslDistro.ps1 -Action Compact -Distro NixOS
.EXAMPLE
  .\scripts\Compact-WslDistro.ps1 -Action Compact -Distro Ubuntu26.04 -Restart
.EXAMPLE
  .\scripts\Compact-WslDistro.ps1 -Help
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [ValidateSet('Status', 'Trim', 'Compact', 'SetSparse')][string]$Action,
  [string]$Distro,
  [ValidateSet('Auto', 'OptimizeVHD', 'Diskpart')][string]$Method = 'Auto',
  [switch]$SkipTrim,
  [switch]$NoShutdown,
  [switch]$Restart,
  [switch]$Force,
  [Nullable[bool]]$Sparse,
  [switch]$Help
)

if ($Help) { Get-Help -Name $PSCommandPath -Full; return }
if (-not $Action) { throw 'Specify -Action, or use -Help for usage.' }
if ($env:OS -ne 'Windows_NT') { throw 'Run this script in Windows PowerShell on the Windows host.' }

$ErrorActionPreference = 'Stop'
$WslExe      = Join-Path $env:SystemRoot 'System32\wsl.exe'
$KeepAliveDir = 'C:\ProgramData\WSL-KeepAlive'
$PauseFlag    = Join-Path $KeepAliveDir 'flags\paused'
$InternalDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'internal'
. (Join-Path $InternalDir 'Wsl-Guest.ps1')
. (Join-Path $InternalDir 'Wsl-KeepAliveMaintenance.ps1')

$__wp = $WhatIfPreference; $WhatIfPreference = $false
Import-Module Hyper-V -ErrorAction SilentlyContinue
$WhatIfPreference = $__wp

function Test-Admin { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
function Assert-Admin { if (-not (Test-Admin)) { throw "Action=$Action requires an elevated Windows PowerShell session." } }
function Invoke-Wsl([string[]]$CmdArgs) {
  $ErrorActionPreference = 'Continue'
  $prev = [Console]::OutputEncoding
  try { [Console]::OutputEncoding = [System.Text.Encoding]::Unicode; $o = & $WslExe @CmdArgs 2>&1; $script:LastWslExit = $LASTEXITCODE; $o | ForEach-Object { "$_".Trim() } | Where-Object { $_ } }
  finally { [Console]::OutputEncoding = $prev }
}
function Invoke-WslCmd([string]$d, [string[]]$LinuxCmd) {

  $guestArgs = @(Get-WslGuestArguments $LinuxCmd)
  $ErrorActionPreference = 'Continue'
  $prev = [Console]::OutputEncoding
  try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8; $o = & $WslExe -d $d -u root @guestArgs 2>&1; $script:LastWslExit = $LASTEXITCODE; $o | ForEach-Object { "$_" } }
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
  if ($Name) { $m = $all | Where-Object { $_ -ieq $Name } | Select-Object -First 1; if ($m) { return $m }; throw "Distribution '$Name' not found. Registered: $($all -join ', ')" }
  if ($all.Count -eq 1) { return $all[0] }
  throw "Specify -Distro. Registered: $($all -join ', ')"
}
function Get-DistroInfo([string]$d) {
  $lxss = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
  $k = Get-ChildItem $lxss | Where-Object { (Get-ItemProperty $_.PSPath).DistributionName -ieq $d } | Select-Object -First 1
  if (-not $k) { throw "Distribution '$d' not found in the registry." }
  $p = Get-ItemProperty $k.PSPath
  $base = $p.BasePath -replace '^\\\\\?\\', ''
  $vhd = Join-Path $base 'ext4.vhdx'
  if ($p.VhdFileName) { $vhd = Join-Path $base $p.VhdFileName }
  if (-not (Test-Path -LiteralPath $vhd)) { throw "VHDX not found: $vhd" }
  [pscustomobject]@{ Name = $p.DistributionName; Version = $p.Version; Vhd = $vhd; Guid = $k.PSChildName }
}

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

  $o = Invoke-WslCmd $d @('df', '-B1', '--output=used,size', '/') | Select-Object -Last 1
  if ($o -match '^\s*(\d+)\s+(\d+)') { [pscustomobject]@{ Used = [uint64]$matches[1]; Size = [uint64]$matches[2] } } else { $null }
}
function GB($b) { '{0:N1} GB' -f ($b / 1GB) }
function Test-OptimizeVhd {

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
  Write-Host ("Distribution   : {0}  (WSL{1}, {2})" -f $i.Name, $i.Version, $(if ($running) { 'Running' } else { 'Stopped' }))
  Write-Host ("vhdx           : {0}" -f $i.Vhd)
  Write-Host ("File size      : logical {0} / allocated {1}" -f (GB $logical), (GB $alloc))
  Write-Host ("Sparse mode    : {0}" -f $(if ($sparse) { 'On (trim and stop; manual compaction skipped)' } else { 'Off (manual compaction available)' }))
  if ($guest) {
    Write-Host ("Guest usage  : {0} used / {1} virtual disk" -f (GB $guest.Used), (GB $guest.Size))
    Write-Host ("Reclaim estimate: about {0} (allocated minus guest usage)" -f (GB ([math]::Max([int64]0, [int64]$alloc - [int64]$guest.Used))))
  } else { Write-Host 'Guest usage  : (shown only while the distribution is running)' }
  Write-Host ("WSL version       : {0}  -> --set-sparse {1}" -f $(if ($wslv) { $wslv } else { 'Inbox/unknown' }), $(if ($wslv -and $wslv -ge [version]'1.3.10') { 'Supported' } else { 'Unavailable' }))
  Write-Host ("Optimize-VHD   : {0}" -f $(if (Test-OptimizeVhd) { 'Available (Hyper-V module and running vmms)' } elseif (Get-Command Optimize-VHD -ErrorAction SilentlyContinue) { 'Module present, vmms unavailable -> use diskpart' } else { 'Unavailable -> use diskpart' }))
  Write-Host ("Selected method    : {0}" -f (Resolve-Method))
  $drive = (Split-Path -Qualifier $i.Vhd)
  $free = (Get-PSDrive ($drive.TrimEnd(':'))).Free
  Write-Host ("{0} Free space    : {1}" -f $drive, (GB $free))
  $keep = Get-ScheduledTask -TaskName "WSL-KeepAlive-$d" -ErrorAction SilentlyContinue
  if ($keep) { Write-Host ("KeepAlive task: {0} (automatically suspended during compaction)" -f $keep.State) }
}

function Invoke-Trim([string]$d) {
  $running = (Get-RunningDistros) -contains $d
  Write-Host "Running fstrim ($d)..."

  $out = Invoke-WslCmd $d @('fstrim', '-v', '/')
  if ($script:LastWslExit -ne 0) { throw "fstrim failed (exit=$script:LastWslExit): $($out -join ' ')" }
  $out | ForEach-Object { Write-Host "  $_" }
  if (-not $running) { Write-Host '  (the distribution was started for fstrim)' }
}

function Stop-DistroForVhd([string]$d, [string]$vhd) {
  Write-Host "Stopping distribution: wsl -t $d"
  & $WslExe -t $d | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "wsl --terminate failed (exit=$LASTEXITCODE)." }
  $deadline = (Get-Date).AddSeconds(30)
  while ((Test-FileLocked $vhd) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
  if (Test-FileLocked $vhd) {
    if ($NoShutdown) { throw 'VHDX is still locked. Omit -NoShutdown to allow wsl --shutdown of the entire VM.' }
    Write-Warning 'VHDX is still locked; running wsl --shutdown (also stops other distributions).'
    & $WslExe --shutdown | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "wsl --shutdown failed (exit=$LASTEXITCODE)." }
    $deadline = (Get-Date).AddSeconds(30)
    while ((Test-FileLocked $vhd) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
    if (Test-FileLocked $vhd) { throw 'VHDX remains locked after wsl --shutdown. Check backup tools, Explorer previews, or other open handles.' }
  }
}

function Invoke-CompactVhd([string]$vhd, [string]$how) {
  switch ($how) {
    'OptimizeVHD' {
      Write-Host "Running Optimize-VHD -Mode Full (may take several minutes)..."
      Optimize-VHD -Path $vhd -Mode Full
    }
    'Diskpart' {

      $enc = try { [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage) } catch { [System.Text.Encoding]::Default }
      $script = Join-Path $env:TEMP ("wsl-compact-{0}.txt" -f [guid]::NewGuid())
      $detach = Join-Path $env:TEMP ("wsl-detach-{0}.txt" -f [guid]::NewGuid())
      [IO.File]::WriteAllLines($script, [string[]]@("select vdisk file=`"$vhd`"", 'attach vdisk readonly', 'compact vdisk', 'detach vdisk', 'exit'), $enc)
      [IO.File]::WriteAllLines($detach, [string[]]@("select vdisk file=`"$vhd`"", 'detach vdisk', 'exit'), $enc)
      Write-Host "Running diskpart compact vdisk (may take several minutes)..."
      Write-Host "  Note: cancel any Explorer prompt to format the attached disk."
      $ErrorActionPreference = 'Continue'
      try {
        $out = & diskpart.exe /s $script 2>&1
        $rc = $LASTEXITCODE
        $out | ForEach-Object { Write-Host "  $_" }
        if ($rc -ne 0) {

          Write-Warning "diskpart failed (exit=$rc). Detaching the VHDX."
          & diskpart.exe /s $detach 2>&1 | ForEach-Object { Write-Host "  $_" }
          throw "diskpart compact failed (exit=$rc)"
        }
      } finally {
        $ErrorActionPreference = 'Stop'
        Remove-Item -LiteralPath $script, $detach -Force -ErrorAction SilentlyContinue
      }
    }
  }
}

function Invoke-DiskMaintenance {
  param([string]$d, $Info, [string]$Operation, [string]$How)
  $state = New-KeepAliveMaintenanceState $PauseFlag
  $operationError = $null
  $recoveryError = $null
  try {
    Suspend-KeepAliveForMaintenance $state
    if ($Operation -eq 'Compact' -and -not $SkipTrim) { Invoke-Trim $d }
    Stop-DistroForVhd $d $Info.Vhd
    if ($Operation -eq 'Compact') {
      if ((Test-SparseFile $Info.Vhd) -and -not $Force) {
        Write-Host 'Sparse VHDX: completed trim/stop; manual compaction skipped. Use -Force to compact explicitly.'
      } else { Invoke-CompactVhd $Info.Vhd $How }
    } else {
      $cmd = @('--manage', $d, '--set-sparse', $(if ($Sparse) { 'true' } else { 'false' }))
      if ($Sparse) { $cmd += '--allow-unsafe' }
      $out = Invoke-Wsl $cmd
      $out | ForEach-Object { Write-Host "  $_" }
      if ($script:LastWslExit -ne 0) { throw "wsl --manage --set-sparse failed (exit=$script:LastWslExit): $($out -join ' ')" }
    }
  } catch { $operationError = $_ }
  finally {
    try { Restore-KeepAliveAfterMaintenance $state }
    catch { $recoveryError = $_ }
  }
  if ($operationError) {
    if ($recoveryError) { Write-Warning "KeepAlive recovery also failed: $recoveryError" }
    throw $operationError
  }
  if ($recoveryError) { throw $recoveryError }
}

switch ($Action) {
  'Status' { Show-Status (Resolve-Distro $Distro) }
  'Trim' {
    $d = Resolve-Distro $Distro
    if ($PSCmdlet.ShouldProcess($d, 'Trim guest root filesystem')) { Invoke-Trim $d }
  }
  'Compact' {
    if (-not $WhatIfPreference) { Assert-Admin }
    $d = Resolve-Distro $Distro
    $i = Get-DistroInfo $d
    if ($i.Version -ne 2) { throw 'Compaction requires a WSL 2 distribution.' }
    $how = Resolve-Method
    $manual = -not (Test-SparseFile $i.Vhd) -or $Force
    if ($manual -and $how -eq 'OptimizeVHD' -and -not (Test-OptimizeVhd)) {
      throw 'Optimize-VHD is unavailable (Hyper-V module or running vmms missing). Use -Method Diskpart.'
    }
    # ShouldProcess precedes guest probes, trim and every maintenance mutation.
    $trimPlan = if ($SkipTrim) { 'skip trim' } else { 'trim root filesystem' }
    $stopPlan = if ($NoShutdown) { 'terminate target only' } else { 'terminate target; global shutdown if needed' }
    $compactPlan = if ($manual) { "compact ($how)" } else { 'sparse trim/stop only' }
    $restartPlan = if ($Restart) { '; start target' } else { '' }
    $description = "Suspend KeepAlive; $trimPlan; $stopPlan; $compactPlan; restore KeepAlive$restartPlan"
    if (-not $PSCmdlet.ShouldProcess($i.Vhd, $description)) { return }
    $before = Get-AllocatedBytes $i.Vhd
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Invoke-DiskMaintenance $d $i 'Compact' $how
    $sw.Stop()
    $after = Get-AllocatedBytes $i.Vhd
    Write-Host ("Completed ({0:N0}s): {1} -> {2} (reclaimed {3})" -f $sw.Elapsed.TotalSeconds, (GB $before), (GB $after), (GB ([math]::Max([int64]0, [int64]$before - [int64]$after)))) -ForegroundColor Green
    if ($Restart) {
      Write-Host "Starting distribution: $d"
      $out = Invoke-WslCmd $d @('true')
      if ($script:LastWslExit -ne 0) { throw "Restart failed (exit=$script:LastWslExit): $($out -join ' ')" }
    }
    Write-Host "Prior KeepAlive state restored. Without an active KeepAlive task or -Restart, the target remains stopped. Start manually: wsl -d $d"
  }
  'SetSparse' {
    if (-not $WhatIfPreference) { Assert-Admin }
    if ($null -eq $Sparse) { throw 'Specify -Sparse $true or $false.' }
    $d = Resolve-Distro $Distro
    $i = Get-DistroInfo $d
    if ($i.Version -ne 2) { throw 'SetSparse requires a WSL 2 distribution.' }
    $wslv = Get-WslVersion
    if (-not $wslv -or $wslv -lt [version]'1.3.10') { throw "WSL ($wslv) does not support --set-sparse. Update WSL." }
    if ($Sparse) { Write-Warning 'Enabling sparse uses --allow-unsafe. Back up the VHDX before changing this setting.' }
    if (-not $PSCmdlet.ShouldProcess($d, "Suspend KeepAlive; stop WSL; set-sparse $Sparse; restore KeepAlive")) { return }
    Invoke-DiskMaintenance $d $i 'SetSparse' ''
    Write-Host "Sparse setting updated; prior KeepAlive state restored for $d."
  }
}
