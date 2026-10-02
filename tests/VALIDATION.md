# Validation record

Date: 2026-10-02 (Asia/Seoul).

## Passed locally

Environment: macOS with PowerShell 7.6.6.
Command: `pwsh -NoProfile -File tests/Test-WslScripts.ps1`.
Result: **113 checks passed**.

- PowerShell syntax parsing for all user, internal and developer scripts.
- English script source and full help for every user parameter.
- Guest shell command execution and argument quoting using legacy native argument
  serialization (the mode relevant to Windows PowerShell 5.1).
- Actual local `true`, `sleep 0` and `df -P /` invocation; executable fixture checks
  inherited PATH fallback and trim-shaped argument forwarding. No discard operation.
- Simulated Windows task suspension and recovery for running, enabled/stopped and
  disabled tasks; existing manual pause content is preserved.
- Recovery after trim, termination, compaction, SetSparse and partial suspension failures.
- Remaining tasks recover even when another task fails recovery; original operation
  errors remain visible when recovery also fails.
- Sparse trim/stop, Force, SkipTrim and Restart behavior.
- Compact, Trim and SetSparse WhatIf perform no guest probes or mutations.
- Legacy/current worker and holder matching rejects similar distribution names.
- Maintenance without an installed KeepAlive task.

`git diff --check` passed. No Korean script/documentation text remains.

## Remote verification unavailable

The supplied SSH aliases were tried repeatedly with batch authentication and a
10-second connection timeout:

| Alias | Expected guest | Result |
| --- | --- | --- |
| `homewslu` | Ubuntu26.04 | Connection reset by peer before SSH key exchange |
| `homewsl` | NixOS | Connection reset by peer before SSH key exchange |

No remote files, tasks, power settings or disks were changed. Consequently, this
record does **not** claim native Windows PowerShell 5.1 execution, real guest fstrim
resolution, installed task recovery or live VHDX compaction passed.

## Ready for native verification

Copy the complete repository to a Windows local directory. From Windows PowerShell,
run these read-only guest probes (they can start a stopped guest):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-WslGuest.ps1 -Distro Ubuntu26.04
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-WslGuest.ps1 -Distro NixOS
.\scripts\WSL-KeepAlive.ps1 -Help
.\scripts\Compact-WslDistro.ps1 -Help
.\scripts\WSL-PowerGuard.ps1 -Help
.\scripts\Check-WslPackage.ps1 -Help
.\scripts\Compact-WslDistro.ps1 -Action Status -Distro NixOS
.\scripts\Compact-WslDistro.ps1 -Action Compact -Distro NixOS -WhatIf
```

The developer suite can also run with Windows PowerShell 5.1:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-WslScripts.ps1
```

Live Compact must be invoked from the Windows host, outside the SSH session in the
target guest, because termination closes that guest connection. After native guest
probes pass, use the README one-command examples and compare KeepAlive Status before
and after for running, stopped, disabled and manually paused configurations.
