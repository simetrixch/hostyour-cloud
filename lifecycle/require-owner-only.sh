# =============================================================================
# require-owner-only.sh — the guard every launcher puts on its config before the
# file leaves this workstation. SOURCED, NEVER RUN: each launcher reads it with
# `.` and calls require_owner_only on the config it was given.
#
#   require_owner_only <file>   0 when nobody but the owner can reach the file;
#                               1 otherwise, with REACH and OWNER_ONLY_COMMAND set
#
# ON WINDOWS THE ANSWER IS AN ACCESS LIST, NOT A MODE. Git Bash mounts every
# drive `noacl` (`mount` prints it), so `stat -c '%a'` answers 644 for every
# writable file and `chmod 600` changes nothing: a launcher judging the mode
# there refuses every config and prints a command that cannot be obeyed. The
# file's real guard is its access list, which is what the PowerShell twins read
# with Get-Acl: the owner, `NT AUTHORITY\SYSTEM` and `BUILTIN\Administrators`
# are admitted, and any other principal holding a right refuses the file. This
# reads the same list with icacls and applies the same rule, so the two
# spellings refuse the same files for the same reason. A principal admitted in
# one is admitted in the other in the same change.
#
# EVERYWHERE ELSE THE ANSWER IS THE MODE, 600 or 400. `stat` spells its
# arguments differently on Linux and on macOS, and both are asked rather than
# one being assumed.
#
# THE SENTENCE STAYS THE CALLER'S. What this leaves behind is the two pieces a
# refusal is built from: REACH says who can read the file ("is mode 644", "can
# be read by Everyone") and OWNER_ONLY_COMMAND is the one command that makes it
# owner-only on this platform. Which credentials the file carries is the
# caller's to say.
# =============================================================================

require_owner_only() {
  local file="$1"
  REACH=''
  OWNER_ONLY_COMMAND=''
  if [ -n "${MSYSTEM:-}" ] || [ "$(uname -o 2>/dev/null)" = 'Msys' ]; then
    local win owner acl line principal strangers='' seen=0 nocase
    win="$(cygpath -aw "$file")"
    # icacls names every principal but never the owner, and stat on MSYS answers
    # the owner's account name without its domain: a principal is the owner when
    # it is that name, or a domain, a backslash and that name.
    owner="$(stat -c '%U' "$file" 2>/dev/null)"
    acl="$(icacls "$win" 2>/dev/null)"
    OWNER_ONLY_COMMAND="icacls \"$win\" /inheritance:r /grant:r \"${USERNAME:-$owner}:(F)\""
    # Account names are matched the way Windows compares them, without case.
    nocase="$(shopt -p nocasematch)"
    shopt -s nocasematch
    while IFS= read -r line; do
      # The first line opens with the path; each entry is <principal>:(rights),
      # and a principal may carry a space (NT AUTHORITY\SYSTEM).
      line="${line#"$win"}"
      line="${line#"${line%%[![:space:]]*}"}"
      case "$line" in *:\(*\)) ;; *) continue ;; esac
      seen=1
      principal="${line%%:\(*}"
      case "$principal" in
        "$owner"|*\\"$owner"|*\\SYSTEM|*\\Administrators) ;;
        *) case "$strangers, " in *", $principal, "*) ;; *) strangers="$strangers, $principal" ;; esac ;;
      esac
    done <<< "$acl"
    $nocase
    # NO ENTRY AT ALL IS A REFUSAL, not a pass: an icacls that answered nothing
    # readable proves nothing about who can reach the file.
    [ "$seen" = 1 ] || { REACH='has an access list icacls did not answer'; return 1; }
    [ -n "$strangers" ] || return 0
    REACH="can be read by ${strangers#, }"
    return 1
  fi
  local mode
  mode="$(stat -c '%a' "$file" 2>/dev/null || stat -f '%Lp' "$file" 2>/dev/null)"
  case "$mode" in 600|400) return 0 ;; esac
  REACH="is mode ${mode:-unknown}"
  OWNER_ONLY_COMMAND="chmod 600 $file"
  return 1
}
