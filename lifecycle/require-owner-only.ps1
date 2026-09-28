# =============================================================================
# require-owner-only.ps1 — the PowerShell spelling of require-owner-only.sh, the
# guard every launcher puts on its config before the file leaves this
# workstation. SOURCED, NEVER RUN: each launcher reads it with `.` and asks
# Test-OwnerOnly about the config it was given.
#
#   Test-OwnerOnly <file>   $true when nobody but the owner can reach the file;
#                           $false otherwise, with $script:Reach and
#                           $script:OwnerOnlyCommand set
#
# ON WINDOWS THE ANSWER IS AN ACCESS LIST, read with Get-Acl: the owner,
# `NT AUTHORITY\SYSTEM` and `BUILTIN\Administrators` are admitted, and any other
# principal holding a right refuses the file. require-owner-only.sh reads the
# same list with icacls and applies the same rule; a principal admitted in one
# is admitted in the other in the same change.
#
# EVERYWHERE ELSE THE ANSWER IS THE MODE, 600 or 400, read with the same `stat`
# the bash guard asks, in both of its spellings, so the two guards answer from
# one source. Get-Acl exists on Windows alone.
#
# THE SENTENCE STAYS THE CALLER'S, as in the bash guard: $script:Reach says who
# can read the file and $script:OwnerOnlyCommand is the one command that makes
# it owner-only on this platform.
# =============================================================================

$script:Reach = ''
$script:OwnerOnlyCommand = ''
function Test-OwnerOnly([string] $File) {
  $script:Reach = ''
  $script:OwnerOnlyCommand = ''
  $resolved = (Resolve-Path -LiteralPath $File).Path
  if ($IsWindows) {
    $acl = Get-Acl -Path $resolved
    $owner = $acl.Owner
    $strangers = @($acl.Access | Where-Object {
      $who = $_.IdentityReference.Value
      $who -ne $owner -and
      $who -notmatch '(?i)\\SYSTEM$' -and
      $who -notmatch '(?i)\\Administrators$'
    } | ForEach-Object { $_.IdentityReference.Value } | Sort-Object -Unique)
    $script:OwnerOnlyCommand = "icacls `"$resolved`" /inheritance:r /grant:r `"$($env:USERNAME):(F)`""
    if ($strangers.Count -eq 0) { return $true }
    $script:Reach = "can be read by $($strangers -join ', ')"
    return $false
  }
  $mode = & stat -c '%a' $resolved 2>$null
  if ($LASTEXITCODE -ne 0) { $mode = & stat -f '%Lp' $resolved 2>$null }
  if ($mode -eq '600' -or $mode -eq '400') { return $true }
  $script:Reach = "is mode $(if ($mode) { $mode } else { 'unknown' })"
  $script:OwnerOnlyCommand = "chmod 600 $File"
  return $false
}
