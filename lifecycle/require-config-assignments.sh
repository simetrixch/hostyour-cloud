# =============================================================================
# require-config-assignments.sh — the check every launcher makes on its config
# before the file is read by a shell. SOURCED, NEVER RUN: each launcher reads it
# with `.` and calls require_config_assignments on the config it was given.
#
#   require_config_assignments <file> [<keys>]
#                                       0 when every line is blank, a comment or
#                                       NAME='value'; 1 otherwise, with BAD_LINES
#                                       set to the first three lines that are not,
#                                       as "line 12 (SECRET_X), line 14"; <keys>
#                                       is the blank-separated list of the names
#                                       that may be printed, none where it is left out
#
# THE CONFIG IS READ BY THE SHELL, on the workstation and again on the machine, so
# a line that is not a comment or NAME='value' is a command that would run.
#
# A REFUSED LINE IS NEVER QUOTED. The line an operator mistypes is often a
# credential's (a closing quote forgotten on a password), and a refusal that
# quotes it puts the credential on the terminal and into any log the operator
# keeps with `tee`. BAD_LINES carries the line number and nothing else, except
# the name where the line begins with a name in capitals directly followed by `=`
# AND that name is one of <keys>. A token that is no key is never printed, because
# a line that holds a value, a line inside a quote opened on an earlier line and a
# bare token such as GEZDGNBVGY3TQOJQ==== can all begin that way.
#
# THE KEYS ARE THE LAUNCHER'S. The launchers read them from config.example.env
# beside this file, in CONFIG_EXAMPLE_KEYS below, and hand them over; with the
# example missing they hand over none and name numbers only. The five drivers run
# on the machine, where no example can be read, so they hand over none and name
# line numbers only.
#
# THE PIPELINE RUNS IN C, so that the answer does not depend on the locale of
# the caller: under a UTF-8 locale grep cannot match a value of Latin-1 bytes
# with `[^']` and would refuse a line that is accepted under C. grep reads with -a
# because it answers a line with a NUL as "Binary file matches"; tr then drops the
# NUL, because BusyBox awk ends a record at a NUL and would print the text after it,
# up to its first colon, as a line number.
#
# THE SENTENCE STAYS THE CALLER'S. The five drivers run on the machine, where the
# launcher sends one script over one ssh session and no sibling can be read, so
# each carries this function inline, and test.sh holds every copy byte-equal to
# the function below. Change them together.
# =============================================================================

require_config_assignments() {
  local file="$1" keys="${2:-}"
  BAD_LINES=$(
    export LC_ALL=C
    grep -anvE "^[[:space:]]*(#.*)?$|^[A-Z][A-Z0-9_]*='[^']*'[[:space:]]*(#.*)?$" "$file" \
      | tr -d '\000' \
      | head -3 \
      | awk -v keys=" $keys " '{
          number = substr($0, 1, index($0, ":") - 1)
          name = ""
          if (match(substr($0, index($0, ":") + 1), /^[A-Z][A-Z0-9_]*=/)) {
            name = substr($0, index($0, ":") + 1, RLENGTH - 1)
            if (index(keys, " " name " ") == 0) name = ""
          }
          printf "%sline %s%s", (NR > 1 ? ", " : ""), number, (name == "" ? "" : " (" name ")")
        }'
  )
  [ -z "$BAD_LINES" ]
}

CONFIG_EXAMPLE_KEYS=$(LC_ALL=C grep -aoE "^[A-Z][A-Z0-9_]*=" "${BASH_SOURCE[0]%/*}/config.example.env" 2>/dev/null | tr -d = | paste -sd' ' -) || true
