# =============================================================================
# require-owner-only.sh — the guard every launcher puts on its config before the
# file leaves this workstation. SOURCED, NEVER RUN: each launcher reads it with
# `.` and calls require_owner_only on the config it was given.
#
#   require_owner_only <file>   0 when nobody but the owner can reach the file;
#                               1 otherwise, with REACH and OWNER_ONLY_COMMAND set
#
# THE ANSWER IS THE MODE, 600 or 400. `stat` spells its arguments differently
# on Linux and on macOS, and both are asked rather than one being assumed.
#
# THE SENTENCE STAYS THE CALLER'S. What this leaves behind is the two pieces a
# refusal is built from: REACH says who can read the file ("is mode 644") and
# OWNER_ONLY_COMMAND is the one command that makes it owner-only. Which
# credentials the file carries is the caller's to say.
# =============================================================================

require_owner_only() {
  local file="$1"
  REACH=''
  OWNER_ONLY_COMMAND=''
  local mode
  mode="$(stat -c '%a' "$file" 2>/dev/null || stat -f '%Lp' "$file" 2>/dev/null)"
  case "$mode" in 600|400) return 0 ;; esac
  REACH="is mode ${mode:-unknown}"
  OWNER_ONLY_COMMAND="chmod 600 $file"
  return 1
}
