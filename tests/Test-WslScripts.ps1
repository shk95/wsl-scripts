# Developer tests. No live Windows tasks, disk compaction or power changes are performed.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$script:checks = 0
function Assert([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "FAIL: $Message" }
  $script:checks++
}
function Assert-Throws([scriptblock]$Body, [string]$Pattern) {
  $caught = $null
  try { & $Body } catch { $caught = $_ }
  Assert ($null -ne $caught -and "$caught" -match $Pattern) "Expected error matching $Pattern; got $caught"
}

$files = @(Get-ChildItem (Join-Path $root 'scripts'), (Join-Path $root 'internal'), $PSScriptRoot -Filter '*.ps1')
foreach ($file in $files) {
  $tokens = $null; $errors = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
  Assert ($errors.Count -eq 0) "Parse $($file.Name): $errors"
  Assert ((Get-Content $file.FullName -Raw) -notmatch '[\uac00-\ud7a3]') "English source: $($file.Name)"
}
foreach ($file in Get-ChildItem (Join-Path $root 'scripts') -Filter '*.ps1') {
  $helpText = (& $file.FullName -Help | Out-String)
  Assert ($helpText -match 'Manage WSL|Manage a Windows|Inspect WSL|Trim and compact' -and $helpText -match 'Distro|LidAction') "Full help: $($file.Name)"
  $help = Get-Help $file.FullName -Full
  foreach ($parameter in (Get-Command $file.FullName).Parameters.Keys) {
    if ($parameter -in 'Verbose','Debug','ErrorAction','WarningAction','InformationAction','ProgressAction','ErrorVariable','WarningVariable','InformationVariable','OutVariable','OutBuffer','PipelineVariable','WhatIf','Confirm') { continue }
    Assert ($help.parameters.parameter.name -contains $parameter) "Help for $parameter in $($file.Name)"
  }
}

. (Join-Path $root 'internal/Wsl-Guest.ps1')
$guest = @(Get-WslGuestArguments @('fstrim', '-v', '/'))
Assert ($guest[0] -eq '--exec' -and $guest[1] -eq '/bin/sh') 'Portable shell bootstrap'
if ($env:OS -ne 'Windows_NT') {
  # PS 5.1 uses legacy native argument serialization. Verify quoting in that mode.
  $PSNativeCommandArgumentPassing = 'Legacy'
  foreach ($arguments in @(@('true'), @('df', '-P', '/'), @('sleep', '0'))) {
    $guest = @(Get-WslGuestArguments $arguments)
    $output = & /bin/sh -c $guest[3] 2>&1
    Assert ($LASTEXITCODE -eq 0) "Guest command $($arguments[0]) resolves on this Unix host: $output"
  }
  # macOS lacks fstrim. An executable fixture verifies inherited PATH fallback
  # and argument forwarding, without invoking any disk discard operation.
  $fixture = Join-Path ([IO.Path]::GetTempPath()) ('wsl-tool-' + [guid]::NewGuid())
  $oldPath = $env:PATH
  try {
    New-Item -ItemType Directory -Path $fixture | Out-Null
    $fakeTrim = Join-Path $fixture 'wsl-test-trim'
    [IO.File]::WriteAllText($fakeTrim, "#!/bin/sh`nprintf '%s\n' `"`$@`"`n")
    & chmod +x $fakeTrim
    $env:PATH = $fixture + ':' + $oldPath
    $guest = @(Get-WslGuestArguments @('wsl-test-trim', '-v', '/'))
    $output = @(& /bin/sh -c $guest[3])
    Assert ($LASTEXITCODE -eq 0 -and $output[0] -eq '-v' -and $output[1] -eq '/') 'Tool lookup and trim argument forwarding'
  } finally {
    $env:PATH = $oldPath
    Remove-Item $fixture -Recurse -Force
  }
  $guest = @(Get-WslGuestArguments @('printf', '%s', "space and quote's; literal `$HOME"))
  $output = & /bin/sh -c $guest[3]
  Assert ($output -eq "space and quote's; literal `$HOME") 'Guest arguments do not become shell code'
}

. (Join-Path $root 'internal/Wsl-KeepAliveMaintenance.ps1')
# Load actual compact function definitions without running Windows initialization.
$tokens = $null; $errors = $null
$compact = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'scripts/Compact-WslDistro.ps1'), [ref]$tokens, [ref]$errors)
foreach ($node in $compact.EndBlock.Statements) {
  if ($node -is [System.Management.Automation.Language.FunctionDefinitionAst]) { Invoke-Expression $node.Extent.Text }
  if ($node -is [System.Management.Automation.Language.SwitchStatementAst]) { $script:ActionBody = [scriptblock]::Create($node.Extent.Text) }
}

# Simulate the Windows boundary. Preserve actual orchestration and transaction functions.
function Get-ScheduledTask { [CmdletBinding()]param(); $script:MockTasks }
function Disable-ScheduledTask {
  [CmdletBinding()]param($TaskName, $TaskPath)
  $script:events.Add("disable:$TaskName")
  ($script:MockTasks | Where-Object TaskName -eq $TaskName).Settings.Enabled = $false
  if ($script:FailDisable -eq $TaskName) { throw 'injected disable failure' }
}
function Enable-ScheduledTask {
  [CmdletBinding()]param($TaskName, $TaskPath)
  $script:events.Add("enable:$TaskName")
  if ($script:FailEnable -eq $TaskName) { throw 'injected enable failure' }
  ($script:MockTasks | Where-Object TaskName -eq $TaskName).Settings.Enabled = $true
}
function Stop-ScheduledTask {
  [CmdletBinding()]param($TaskName, $TaskPath)
  $script:events.Add("stop:$TaskName")
  ($script:MockTasks | Where-Object TaskName -eq $TaskName).State = 'Ready'
}
function Start-ScheduledTask {
  [CmdletBinding()]param($TaskName, $TaskPath)
  $script:events.Add("start:$TaskName")
  ($script:MockTasks | Where-Object TaskName -eq $TaskName).State = 'Running'
}
function Get-CimInstance { [CmdletBinding()]param($ClassName, $Filter); $script:MockProcesses }
function Stop-Process { [CmdletBinding()]param($Id, [switch]$Force); $script:events.Add("kill:$Id") }
function Resolve-Distro { param($Name); 'NixOS' }
function Get-DistroInfo { param($d); [pscustomobject]@{Vhd='mock.vhdx'; Version=2} }
function Resolve-Method { 'Diskpart' }
function Test-SparseFile { param($Path); $script:IsSparse }
function Get-AllocatedBytes { param($Path); $script:events.Add('allocation'); 1GB }
function Assert-Admin { $script:events.Add('admin') }
function Invoke-Trim {
  param($d)
  $script:events.Add('trim')
  Assert (-not ($script:MockTasks | Where-Object { $_.Settings.Enabled -or $_.State -eq 'Running' })) 'All KeepAlive tasks suspended before trim'
  if ($script:FailAt -eq 'trim') { throw 'injected trim failure' }
}
function Stop-DistroForVhd { param($d,$Path); $script:events.Add('terminate'); if ($script:FailAt -eq 'terminate') { throw 'injected terminate failure' } }
function Invoke-CompactVhd { param($Path,$How); $script:events.Add('compact'); if ($script:FailAt -eq 'compact') { throw 'injected compact failure' } }
function Get-WslVersion { [version]'2.5.0' }
function Invoke-Wsl { param($CmdArgs); $script:events.Add('set-sparse'); $script:LastWslExit = 0; if ($script:FailAt -eq 'set-sparse') { $script:LastWslExit = 1 } }
function Invoke-WslCmd { param($d, $LinuxCmd); $script:events.Add('restart'); $script:LastWslExit = 0 }
function Invoke-MockCompact {
  [CmdletBinding(SupportsShouldProcess=$true)]
  param($Action='Compact', $Distro='NixOS', [switch]$SkipTrim, [switch]$Force, [switch]$Restart, [Nullable[bool]]$Sparse)
  . $script:ActionBody
}
function Reset-Mocks {
  $script:events = New-Object 'System.Collections.Generic.List[string]'
  $script:FailAt = ''; $script:FailDisable = ''; $script:FailEnable = ''; $script:IsSparse = $false
  $script:MockProcesses = @()
  $script:MockTasks = @(
    [pscustomobject]@{TaskName='WSL-KeepAlive-NixOS'; TaskPath='\'; State='Running'; Settings=[pscustomobject]@{Enabled=$true}},
    [pscustomobject]@{TaskName='WSL-KeepAlive-Ubuntu26.04'; TaskPath='\'; State='Ready'; Settings=[pscustomobject]@{Enabled=$true}},
    [pscustomobject]@{TaskName='WSL-KeepAlive-Disabled'; TaskPath='\'; State='Disabled'; Settings=[pscustomobject]@{Enabled=$false}}
  )
}
function Assert-Restored {
  Assert ($script:MockTasks[0].Settings.Enabled -and $script:MockTasks[0].State -eq 'Running') 'Running task restored'
  Assert ($script:MockTasks[1].Settings.Enabled -and $script:events -notcontains 'start:WSL-KeepAlive-Ubuntu26.04') 'Enabled stopped task stays stopped'
  Assert (-not $script:MockTasks[2].Settings.Enabled -and $script:events -notcontains 'start:WSL-KeepAlive-Disabled') 'Disabled task stays disabled'
}

$work = Join-Path ([IO.Path]::GetTempPath()) ('wsl-tests-' + [guid]::NewGuid())
$PauseFlag = Join-Path $work 'flags/paused'
try {
  foreach ($failure in '', 'trim', 'terminate', 'compact') {
    Reset-Mocks
    $script:FailAt = $failure
    if ($failure) { Assert-Throws { Invoke-MockCompact } "injected $failure failure" }
    else { Invoke-MockCompact }
    Assert-Restored
    Assert (-not (Test-Path $PauseFlag)) 'Temporary pause removed on success/failure'
  }
  Reset-Mocks
  New-Item -ItemType File -Path $PauseFlag -Value 'manual pause' -Force | Out-Null
  Invoke-MockCompact
  Assert-Restored
  Assert ((Get-Content $PauseFlag -Raw) -eq 'manual pause') 'Manual pause preserved byte-for-byte'
  Remove-Item $PauseFlag

  Reset-Mocks; $script:IsSparse = $true
  Invoke-MockCompact
  Assert-Restored
  Assert ($script:events -contains 'trim' -and $script:events -contains 'terminate' -and $script:events -notcontains 'compact') 'Sparse path trims/stops with KeepAlive coordination'
  Reset-Mocks; $script:IsSparse = $true
  Invoke-MockCompact -Force -SkipTrim -Restart
  Assert ($script:events -contains 'compact' -and $script:events -notcontains 'trim' -and $script:events -contains 'restart') 'Force/SkipTrim/Restart honored'

  foreach ($action in 'Compact','Trim','SetSparse') {
    Reset-Mocks
    Invoke-MockCompact -Action $action -Sparse $false -WhatIf
    Assert ($script:events.Count -eq 0) "WhatIf $action performs no mutations or guest probes"
    Assert (-not (Test-Path $PauseFlag)) 'WhatIf creates no pause flag'
  }
  foreach ($failure in '', 'set-sparse') {
    Reset-Mocks; $script:FailAt = $failure
    if ($failure) { Assert-Throws { Invoke-MockCompact -Action SetSparse -Sparse $false } 'set-sparse failed' }
    else { Invoke-MockCompact -Action SetSparse -Sparse $false }
    Assert-Restored
  }

  Reset-Mocks; $script:FailDisable = 'WSL-KeepAlive-NixOS'
  Assert-Throws { Invoke-MockCompact } 'injected disable failure'
  Assert ($script:MockTasks[0].Settings.Enabled -and $script:MockTasks[0].State -eq 'Running') 'Partial suspension failure recovered'
  Assert ($script:events -notcontains 'trim') 'Suspension failure aborts disk work'
  Reset-Mocks; $script:FailEnable = 'WSL-KeepAlive-NixOS'; $script:FailAt = 'compact'
  Assert-Throws { Invoke-MockCompact -WarningAction SilentlyContinue } 'injected compact failure'
  Assert ($script:MockTasks[1].Settings.Enabled) 'Other tasks recovered despite one recovery failure'
  Reset-Mocks; $script:FailEnable = 'WSL-KeepAlive-NixOS'
  Assert-Throws { Invoke-MockCompact } 'KeepAlive recovery incomplete'

  Reset-Mocks
  $script:MockProcesses = @(
    [pscustomobject]@{ProcessId=101; CommandLine='powershell.exe -File keepalive-loop.ps1 -Distro "NixOS"'},
    [pscustomobject]@{ProcessId=102; CommandLine='wsl.exe -d NixOS --exec /usr/bin/sleep infinity'},
    [pscustomobject]@{ProcessId=103; CommandLine="wsl.exe -d NixOS --exec /bin/sh -c exec 'sleep' 'infinity'"},
    [pscustomobject]@{ProcessId=104; CommandLine='wsl.exe -d NixOS-Other sleep infinity'}
  )
  Invoke-MockCompact
  Assert ($script:events -contains 'kill:101' -and $script:events -contains 'kill:102' -and $script:events -contains 'kill:103') 'Legacy and current worker/holder matching'
  Assert ($script:events -notcontains 'kill:104') 'Similar distro name is not matched'

  Reset-Mocks; $script:MockTasks = @()
  Invoke-MockCompact
  Assert (-not (Test-Path $PauseFlag)) 'No-task maintenance needs no pause directory'
} finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host "PASS: $script:checks checks. Live Windows operations were not executed."
