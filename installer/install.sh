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
# NO OPTIONS. Thirty-five values reach the five programs, and a command line long
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
# must be blank, a comment, or NAME='value' with no single quote inside the value. A
# comment may follow a value on the same line, because that is valid in the shell that
# reads it and it is where an operator naturally writes what a value may be.
BAD=$(grep -nvE "^[[:space:]]*(#.*)?$|^[A-Z][A-Z0-9_]*='[^']*'[[:space:]]*(#.*)?$" "$FILE" | head -3)
if [ -n "$BAD" ]; then
  fail "$FILE carries lines that are neither a comment nor NAME='value', and this file is READ BY THE SHELL — a line that is not an assignment is a command that would run:
$BAD" 65
fi

# shellcheck disable=SC1090
. "$FILE"

for named in FQDN OPERATOR_USER STAGE CATALOG_REPO DEPLOY_REPO PLATFORM_REPO; do
  [ -n "${!named:-}" ] || fail "$FILE states no $named, and nothing here may choose one" 65
done
[ -n "${ELEVATION_PASSWORD:-}" ]   || fail "$FILE states no ELEVATION_PASSWORD, and every program of this sequence is run elevated" 65

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
BASE=(-p "$PORT" -o ConnectTimeout=20 -o StrictHostKeyChecking=accept-new)

# WHICH DOOR THIS MACHINE OPENS, asked before anything is sent, because the two
# cases this has to serve are opposites. A machine this platform installed carries
# the operator key and has had its password door shut by disable-password-login. A
# machine at its birth carries NO key — deploy-host's install_authorized_key row is
# what puts it there — so its first session can only be a password session, and it
# is the case these launchers exist for.
#
# The key is tried first and the password only where the key is refused, so neither
# case needs a flag and a re-run never asks for a password a machine does not take.
PROBE=$(ssh "${BASE[@]}" -o BatchMode=yes "$TARGET" true 2>&1)
if [ $? -eq 0 ]; then
  DOOR=(-o BatchMode=yes)
  printf '  %s opens to the operator key\n' "$TARGET" >&2
else
  case "$PROBE" in
    *'REMOTE HOST IDENTIFICATION HAS CHANGED'*|*'Host key verification failed'*)
      # NOT ACCEPTED SILENTLY, and accept-new deliberately does not cover it: a
      # machine whose host key changed is either one that was rebuilt or one that
      # is not the machine any more, and only the operator knows which.
      fail "$FQDN answers with a host key this machine does not recognise.

A restore gives a machine a NEW host key, so if you have just restored it that is
expected. Forget the old one and start again:

  ssh-keygen -R $FQDN

If you have NOT restored it, clear nothing: something else is answering for $FQDN." 74 ;;
    *'Permission denied'*)
      [ -t 0 ] || fail "$TARGET carries no operator key yet, so this can only be a password session — and there is no terminal here to ask on. Start it from a terminal." 69
      DOOR=(-o BatchMode=no -o NumberOfPasswordPrompts=1)
      printf '\n  %s carries no operator key yet. deploy-host is what puts it there,\n' "$TARGET" >&2
      printf '  and it is one of the five programs this is about to run.\n\n' >&2
      printf '  ssh will ask for the login password ONCE, on this terminal. It is not read\n' >&2
      printf '  from the config, it is not kept, and it does not reach the transcript.\n' >&2 ;;
    *)
      fail "could not reach $TARGET:

$PROBE" 69 ;;
  esac
fi

# ONE SESSION, so that a password is typed at most once. The stream is the config
# inside a quoted heredoc with the driver behind it: the config lands on the machine
# under a mask that admits nobody else, and driver.sh shreds it on every path it can
# end on. Neither is ever an argument, because an argument stands in a process
# listing. The heredoc marker cannot collide with anything in the config, because the
# guard above admits no line but a comment and NAME='value'.
# A CARRIAGE RETURN IS TAKEN OFF BOTH. This repository stores LF (.gitattributes), but
# the config is written by an operator in whatever editor they have, and Notepad writes
# CRLF. NAME=value followed by a CR puts that CR INSIDE the value, so the FQDN a
# certificate is issued for would carry one and nothing downstream would say why.
{
  printf 'umask 077\ncat > "$1" <<%sAW_CONFIG_END%s\n' "'" "'"
  tr -d $'\r' < "$FILE"
  printf 'AW_CONFIG_END\n'
  tr -d $'\r' < "$DRIVER"
} | ssh "${BASE[@]}" "${DOOR[@]}" "$TARGET" 'bash -s -- "$HOME/.aw-config.env"' 2>&1 | tee "$TRANSCRIPT"
INSTALLED=${PIPESTATUS[1]}

# ---------------------------------------------------- the machine's own records
# FETCHED WHATEVER HAPPENED: a failed installation is the one whose records are
# read, so this runs on the failing path too.
IDS=$(sed 's/\x1b\[[0-9;]*m//g' "$TRANSCRIPT" | grep -oE '^[[:space:]]*RUNS .*$' | tail -1 | sed 's/^[[:space:]]*RUNS //' | tr -d '\r')
if [ -n "${IDS// /}" ]; then
  printf "\n  Fetching the machine's own record of %s run(s) into %s\n" "$(printf '%s' "$IDS" | wc -w | tr -d ' ')" "$SESSION" >&2
  ARRIVED=0
  for id in $IDS; do
    mkdir -p "$SESSION/$id"
    scp -q -P "$PORT" -o BatchMode=yes "$TARGET:/var/lib/ansiwise/runs/$id/*" "$SESSION/$id/" 2>/dev/null || true
    scp -q -P "$PORT" -o BatchMode=yes "$TARGET:/var/lib/ansiwise/runs/$id.startup.log" "$SESSION/$id/" 2>/dev/null || true
    # WHAT ACTUALLY LANDED, COUNTED. An empty directory beside a line saying the
    # records were fetched is worse than no line at all: it reads as "they are
    # there" to whoever comes looking for them later.
    if [ -n "$(ls -A "$SESSION/$id" 2>/dev/null)" ]; then
      ARRIVED=$(( ARRIVED + 1 ))
    else
      rmdir "$SESSION/$id" 2>/dev/null || true
    fi
  done
  if [ "$ARRIVED" -eq 0 ]; then
    printf '  NOTHING ARRIVED. The machine named its runs, and none of them could be read.\n' >&2
    printf '  Either this account carries no key on that machine yet — deploy-host installs\n' >&2
    printf '  it, and it did not get that far — or the records are not readable by it. They\n' >&2
    printf '  stand on the machine either way:\n\n' >&2
    printf '    ssh %s sudo tar -C /var/lib/ansiwise -cf - runs | tar -C %s -xf -\n\n' "$TARGET" "$SESSION" >&2
  else
    printf '  %s of %s arrived: %s\n\n' "$ARRIVED" "$(printf '%s' "$IDS" | wc -w | tr -d ' ')" "$SESSION" >&2
  fi
else
  printf '  The machine named no runs — read the transcript above; nothing was recorded to fetch.\n\n' >&2
fi

exit "$INSTALLED"
