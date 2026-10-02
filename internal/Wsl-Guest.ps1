# Internal guest command adapter. /bin/sh is the bootstrap shell on both NixOS and FHS Linux.
# Tools are resolved by the shell using stable profile paths, never immutable Nix store paths.
function Get-WslGuestArguments {
  param([Parameter(Mandatory = $true)][string[]]$LinuxCommand)
  if ($LinuxCommand.Count -eq 0) { throw 'A guest command is required.' }
  # Callers supply fixed tool names and arguments, not shell programs or user input.
  $quoted = foreach ($arg in $LinuxCommand) {
    if ($arg -match '["\r\n\x00]') { throw 'Unsupported character in guest argument.' }
    "'" + $arg.Replace("'", "'\''") + "'"
  }
  $program = 'PATH=/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH; export PATH; LC_ALL=C; export LC_ALL; exec ' + ($quoted -join ' ')
  @('--exec', '/bin/sh', '-c', $program)
}
