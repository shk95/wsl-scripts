# wsl-scripts

Windows PowerShell scripts for WSL, including Ubuntu and NixOS-WSL.
Run operational commands from **Windows PowerShell 5.1** on the Windows host,
using the Windows account that owns the target distribution. Keep the whole
repository together, preferably on a Windows local disk such as `C:\Tools\wsl-scripts`.
Running from a WSL UNC path or through a WSL-launched Windows process can block
WSL calls, and shutting down WSL disconnects guest SSH sessions.

## Layout

| Directory / file | Purpose |
| --- | --- |
| `scripts/WSL-KeepAlive.ps1` | User entry point: manage startup KeepAlive tasks |
| `scripts/Compact-WslDistro.ps1` | User entry point: inspect, trim, compact or set sparse mode |
| `scripts/WSL-PowerGuard.ps1` | User entry point: enable, restore or inspect power settings |
| `scripts/Check-WslPackage.ps1` | User entry point: inspect engine packaging and update history |
| `internal/keepalive-loop.ps1` | Installed scheduled-task worker; do not invoke manually |
| `internal/Wsl-Guest.ps1` | Shared guest command adapter |
| `internal/Wsl-KeepAliveMaintenance.ps1` | Shared KeepAlive suspension and recovery transaction |
| `tests/` | Developer validation; no live compaction or power changes |

Old root-level entry points have moved to `scripts/`; update your command paths.
No compatibility wrappers are installed at the root.

## Help

Every user entry point supports `-Help`, even without an action, distribution,
administrator privileges or a Windows host. PowerShell `Get-Help` works too.
Help includes all parameters and examples.

```powershell
Set-Location C:\Tools\wsl-scripts
.\scripts\WSL-KeepAlive.ps1 -Help
.\scripts\Compact-WslDistro.ps1 -Help
.\scripts\WSL-PowerGuard.ps1 -Help
.\scripts\Check-WslPackage.ps1 -Help
Get-Help .\scripts\Compact-WslDistro.ps1 -Full
```

Script documentation, comments, logs, errors and status labels are English.
Output forwarded from Windows utilities retains the host's language.

## Ubuntu and NixOS-WSL

No `/usr/bin/sleep` or `/sbin/fstrim` executable path is assumed. The guest adapter
boots `/bin/sh`, available on both distributions, and runs tools by name using
stable NixOS system/default profiles and conventional Linux bin/sbin directories,
followed by the inherited PATH. It does not hard-code a Nix store generation.
Guest tool output uses `LC_ALL=C`. `sleep`, `df`, `true` (coreutils) and `fstrim`
(util-linux) must be available in those paths. Trim and guest usage probes run as root.

Existing KeepAlive installations use copies in `C:\ProgramData\WSL-KeepAlive`.
Run `Install` again to update those copies and add the guest adapter; changing the
repository alone does not update installed tasks. Compact can suspend existing
legacy inline tasks and installed loops without requiring you to reinstall first.

NixOS background: [NixOS filesystem design](https://edolstra.github.io/pubs/nixos-jfp-final.pdf).
WSL commands: [Microsoft documentation](https://learn.microsoft.com/en-us/windows/wsl/basic-commands).

## KeepAlive

Use an elevated Windows PowerShell session for Install, Uninstall, Enable and Disable.
The Install credential must belong to the Windows user who owns the distribution.

```powershell
.\scripts\WSL-KeepAlive.ps1 -Action List
.\scripts\WSL-KeepAlive.ps1 -Action Install -Distro NixOS
.\scripts\WSL-KeepAlive.ps1 -Action Status -Distro NixOS
.\scripts\WSL-KeepAlive.ps1 -Action Pause -Distro NixOS -Shutdown
.\scripts\WSL-KeepAlive.ps1 -Action Resume -Distro NixOS
.\scripts\WSL-KeepAlive.ps1 -Action Disable -Distro NixOS -Shutdown
.\scripts\WSL-KeepAlive.ps1 -Action Enable -Distro NixOS
.\scripts\WSL-KeepAlive.ps1 -Action Uninstall -Distro NixOS
```

Pause/Resume use the existing global `C:\ProgramData\WSL-KeepAlive\flags\paused`
flag. A pause affects **all** installed loops. `-Shutdown` stops **all** WSL distributions.
Only the flags directory is made writable by ordinary users. Logs remain at
`C:\ProgramData\WSL-KeepAlive\keepalive-<distribution>.log`.

## Compact in one command

Compact and SetSparse require elevation. Status and Trim do not.
No separate KeepAlive Pause, Disable, Resume or Enable command is needed.

```powershell
.\scripts\Compact-WslDistro.ps1 -Action Status -Distro NixOS
.\scripts\Compact-WslDistro.ps1 -Action Compact -Distro NixOS -WhatIf
.\scripts\Compact-WslDistro.ps1 -Action Compact -Distro NixOS
.\scripts\Compact-WslDistro.ps1 -Action Compact -Distro Ubuntu26.04 -Restart
.\scripts\Compact-WslDistro.ps1 -Action Trim -Distro NixOS
.\scripts\Compact-WslDistro.ps1 -Action SetSparse -Distro NixOS -Sparse $false
```

Compact performs this transaction:

1. Acquire a host-wide maintenance lock; overlapping Compact/SetSparse runs fail.
2. Preserve a manual pause, or create a temporary global pause if tasks exist.
3. Snapshot, disable and stop all `WSL-KeepAlive-*` tasks and stop matching workers/holders,
   including legacy inline loops. All managed tasks are suspended because disk unlock
   recovery may need a global WSL shutdown.
4. Trim the root filesystem (unless `-SkipTrim`), terminate the target and wait for
   the VHDX to unlock. If necessary, shut down all WSL distributions; `-NoShutdown`
   instead fails if target termination does not unlock the disk.
5. Compact using Optimize-VHD when the Hyper-V module and running vmms are available;
   otherwise use diskpart. Sparse VHDX files use trim/stop without manual compaction
   unless `-Force` is specified.
6. In `finally`, remove only the pause created by this invocation and restore task
   enabled/running state, including on trim, termination or compaction failure.
   Disabled tasks stay disabled; enabled but stopped tasks stay stopped. A preexisting
   manual pause remains. Recovery failures are reported explicitly.

Previously running KeepAlive tasks resume automatically; unpaused loops relaunch their
respective distributions. Without active KeepAlive, the target remains stopped.
`-Restart` explicitly starts the target after success, even if KeepAlive is paused or
disabled; it does not change that KeepAlive setting. Other distributions without
KeepAlive are not restarted after a global shutdown.

`-WhatIf` performs host-side discovery and reports the planned operation without guest
probes, trimming, task changes, termination or compaction. It also applies to Trim and
SetSparse. Process termination or host failure can interrupt `finally`; check KeepAlive
Status and restore task settings manually if the script itself is forcibly killed.

SetSparse also uses the suspension/recovery transaction. Enabling sparse passes
`--allow-unsafe`; back up the VHDX before changing this setting. Sparse support depends
on the WSL engine version, not just the Windows edition.

## PowerGuard

Enable and Restore require elevation. Enable exports the original scheme to
`C:\ProgramData\WSL-PowerGuard\original-scheme.pow`, modifies a copy named
`WSL KeepAwake`, and preserves battery policy unless explicitly overridden.

```powershell
.\scripts\WSL-PowerGuard.ps1 -Action Status
.\scripts\WSL-PowerGuard.ps1 -Action Enable
.\scripts\WSL-PowerGuard.ps1 -Action Enable -Laptop -LidAction DoNothing
.\scripts\WSL-PowerGuard.ps1 -Action Enable -Laptop -KeepAwakeOnBattery
.\scripts\WSL-PowerGuard.ps1 -Action Restore
```

## Package inspection

```powershell
.\scripts\Check-WslPackage.ps1
.\scripts\Check-WslPackage.ps1 -Distro Ubuntu26.04 -HistoryDays 180
```

Engine packaging and distribution packaging are separate. Installation events
provide update timestamps; they do not by themselves prove that the VM restarted.

## Validation

```powershell
pwsh -NoProfile -File .\tests\Test-WslScripts.ps1
```

The tests parse all scripts, exercise help, run the guest adapter with legacy native
argument passing on Unix hosts, and simulate task suspension, partial failures,
manual pause preservation, sparse handling and WhatIf without modifying Windows state.
To probe a real Windows host without trimming or compacting:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-WslGuest.ps1 -Distro Ubuntu26.04
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-WslGuest.ps1 -Distro NixOS
```

See `tests/VALIDATION.md` for the latest verification scope and remote results.
