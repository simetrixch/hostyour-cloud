#!/usr/bin/env bash
# =============================================================================
# install.sh — install a first master, from Linux or macOS.
# =============================================================================
#
#   ./install.sh                 reads ./config.env
#   ./install.sh other.env       reads that instead
#
# A FIRST MASTER AND NOTHING ELSE. Everything after it — adopting a machine,
# deploying a slave, onboarding a consumer or a tenant — is the Manager's, and
# this deliberately cannot do any of it. What it installs is the one machine that
# has to exist before the Manager does.
#
# NO OPTIONS. Forty-five values reach the five programs, and a command line long
# enough to carry them is one nobody can read back, nobody can diff, and whose
# every value stands in this machine's process listing. One file states the whole
# installation; this reads it and starts.
#
# KEY=VALUE AND NOT JSON, for the reason this organisation's board tooling is the
# same shape: a shell reads it with one `.` and needs no parser, no jq and no
# Python. JSON would cost every operator a dependency, and it cannot carry the
# one thing that file needs most — a sentence saying what a value is.
#
# THE TWIN OF install.ps1, doing the same four things in the same order: refuse a
# config anyone else can read, carry it over, open one session, keep every line
# that comes back. The installation itself is driver.sh and it runs ON THE
# MACHINE — nothing is fetched here and nothing is carried from this disk, so what
# stands on the machine afterwards is what the repositories say rather than what
# this checkout happened to hold.
# =============================================================================

set -uo pipefail

readonly FILE="${1:-./config.env}"
readonly HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly DRIVER="$HERE/driver.sh"

fail() { printf '\n  %s\n\n' "$*" >&2; exit "${2:-65}"; }

[ -r "$DRIVER" ] || fail 'driver.sh is not beside this file — it IS the installation, and this only starts it' 66
[ -r "$FILE" ]   || fail "there is no config at $FILE. Copy config.example.env, fill it in, then chmod 600 it" 66

# ------------------------------------------------------- the file, and its guards
# OWNER-ONLY OR NOTHING. `stat` spells its arguments differently on Linux and on
# macOS, and both are asked rather than one being assumed.
MODE=$(stat -c '%a' "$FILE" 2>/dev/null || stat -f '%Lp' "$FILE" 2>/dev/null)
case "$MODE" in
  600|400) ;;
  *) fail "$FILE is mode ${MODE:-unknown} and carries ten credentials, four of them tokens with WRITE access to your repositories. Run: chmod 600 $FILE" 77 ;;
esac

# INSIDE A GIT TREE AND NOT IGNORED BY IT is refused: the mistake is made once and
# cannot be taken back, because a token that reached a remote must be rotated.
# IGNORED IS ENOUGH — what this stops is `git add .` sweeping the file up, and a
# file the tree ignores takes a deliberate `git add -f`, which is somebody choosing.
if git -C "$(dirname "$FILE")" rev-parse --show-toplevel >/dev/null 2>&1; then
  if ! git -C "$(dirname "$FILE")" check-ignore -q "$FILE" 2>/dev/null; then
    tree=$(git -C "$(dirname "$FILE")" rev-parse --show-toplevel)
    fail "$FILE stands inside the git working tree at $tree and that tree does not ignore it. A file of credentials belongs nowhere a commit can reach it — move it out, or name it in that tree's .gitignore" 77
  fi
fi

# NOTHING BUT ASSIGNMENTS AND COMMENTS, checked BEFORE this file is read, because
# reading it is running it. A shell `.` executes every line, so a config carrying a
# command would run it with the operator's own rights — and an operator who edited
# a file by hand at two in the morning is exactly who this protects. Every line
# must be blank, a comment, or NAME='value' with no single quote inside the value.
BAD=$(grep -nvE "^[[:space:]]*(#.*)?$|^[A-Z][A-Z0-9_]*='[^']*'[[:space:]]*$" "$FILE" | head -3)
if [ -n "$BAD" ]; then
  fail "$FILE carries lines that are neither a comment nor NAME='value', and this file is READ BY THE SHELL — a line that is not an assignment is a command that would run:
$BAD" 65
fi

# shellcheck disable=SC1090
. "$FILE"

for named in FQDN OPERATOR_USER STAGE CATALOG_REPO PLATFORM_REPO; do
  [ -n "${!named:-}" ] || fail "$FILE states no $named, and nothing here may choose one" 65
done
[ -n "${ELEVATION_PASSWORD:-}" ]   || fail "$FILE states no ELEVATION_PASSWORD, and every program of this sequence is run elevated" 65
[ -n "${CATALOG_REPO_READ_PAT:-}" ] || fail "$FILE states no CATALOG_REPO_READ_PAT, and the catalogue every program is read from is private" 65

# A MACHINE IS ADDRESSED BY ITS NAME, and by nothing else. The name in the config is
# the one the certificate will carry and the one the cluster is reached by, so a
# session opened to anything else is a session opened to a machine we cannot name.
readonly PORT=22

# --------------------------------------------------------------- the transcript
SESSION="./install-transcripts/$FQDN-$(date -u +%Y%m%d-%H%M%S)"
mkdir -p "$SESSION"
TRANSCRIPT="$SESSION/session.log"
printf '\n  %s  ·  stage %s\n' "$FQDN" "$STAGE" >&2
printf '  Everything said here is also kept in %s\n' "$TRANSCRIPT" >&2

TARGET="$OPERATOR_USER@$FQDN"
SSH=(ssh -p "$PORT" -o BatchMode=yes -o ConnectTimeout=20 "$TARGET")

# THE CONFIG TRAVELS AS IT STANDS, over the session's own standard input. It lands
# under a mask that admits nobody else and driver.sh shreds it on every path it can
# end on. It is never an argument, because an argument stands in a process listing.
"${SSH[@]}" 'umask 077 && cat > ~/.aw-config.env' < "$FILE" \
  || fail "could not reach $TARGET, or could not write the config there" 69

# THE INSTALLATION, over the same session, with the driver on standard input so
# that nothing this put there is left on the machine.
"${SSH[@]}" 'bash -s -- ~/.aw-config.env' < "$DRIVER" 2>&1 | tee "$TRANSCRIPT"
INSTALLED=${PIPESTATUS[0]}

# ---------------------------------------------------- the machine's own records
# FETCHED WHATEVER HAPPENED: a failed installation is the one whose records are
# read, so this runs on the failing path too.
IDS=$(grep -oE '^[[:space:]]*RUNS .*$' "$TRANSCRIPT" | tail -1 | sed 's/^[[:space:]]*RUNS //' | tr -d '\r')
if [ -n "${IDS// /}" ]; then
  printf "\n  Fetching the machine's own record of %s run(s) into %s\n" "$(printf '%s' "$IDS" | wc -w | tr -d ' ')" "$SESSION" >&2
  for id in $IDS; do
    mkdir -p "$SESSION/$id"
    scp -q -P "$PORT" -o BatchMode=yes "$TARGET:/var/lib/ansiwise/runs/$id/*" "$SESSION/$id/" 2>/dev/null || true
    scp -q -P "$PORT" -o BatchMode=yes "$TARGET:/var/lib/ansiwise/runs/$id.startup.log" "$SESSION/$id/" 2>/dev/null || true
  done
  printf '  %s\n\n' "$SESSION" >&2
else
  printf '  The machine named no runs — read the transcript above; nothing was recorded to fetch.\n\n' >&2
fi

exit "$INSTALLED"
