# =============================================================================
# require-config-assignments.sh — the check every launcher makes on its config
# before the file is read by a shell. SOURCED, NEVER RUN: each launcher reads it
# with `.` and calls require_config_assignments on the config it was given.
#
#   require_config_assignments <file>   0 when every line is blank, a comment or
#                                       NAME='value'; 1 otherwise, with BAD_LINES
#                                       set to the first three lines that are not,
#                                       as "line 12 (SECRET_X), line 14"
#
# THE CONFIG IS READ BY THE SHELL, on the workstation and again on the machine, so
# a line that is not a comment or NAME='value' is a command that would run.
#
# A REFUSED LINE IS NEVER QUOTED. The line an operator mistypes is often a
# credential's (a closing quote forgotten on a password), and a refusal that
# quotes it puts the credential on the terminal and into any log the operator
# keeps with `tee`. BAD_LINES carries the line number and, where the line begins
# with a name in capitals directly followed by `=`, that name, and nothing else.
#
# THE CEILINGS, stated where they bind. A name is read by its shape, so a token
# in capitals followed by `=` is named even when it was never a name. A lowercase
# name, a name behind a space, or a name with a space before its `=` is named by
# its line number only.
#
# THE PIPELINE RUNS IN C. Under a UTF-8 locale GNU sed cannot match `.` against a
# byte that is not valid UTF-8 and passes the line through whole, and without -a
# grep answers a line with a NUL as "Binary file matches".
#
# THE SENTENCE STAYS THE CALLER'S. The five drivers run on the machine, where the
# launcher sends one script over one ssh session and no sibling can be read, so
# each carries this function inline, and test.sh holds every copy byte-equal to
# the function below. Change them together.
# =============================================================================

require_config_assignments() {
  local file="$1"
  BAD_LINES=$(
    export LC_ALL=C
    grep -anvE "^[[:space:]]*(#.*)?$|^[A-Z][A-Z0-9_]*='[^']*'[[:space:]]*(#.*)?$" "$file" \
      | head -3 \
      | sed -E -e 's/^([0-9]+):([A-Z][A-Z0-9_]*)=.*/line \1 (\2)/' -e 's/^([0-9]+):.*/line \1/' \
      | paste -sd, - | sed 's/,/, /g'
  )
  [ -z "$BAD_LINES" ]
}
