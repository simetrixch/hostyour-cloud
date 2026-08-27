#!/usr/bin/env bash
# =============================================================================
# from-unix.sh — start a first master's installation from Linux or macOS.
# =============================================================================
#
#   ./from-unix.sh                     reads ./installation.json
#   ./from-unix.sh other-machine.json  reads that instead
#
# NO OPTIONS, AND THAT IS THE POINT. An installation is a great many statements —
# thirty-three answers for deploy-branch alone — and a command line long enough to
# carry them is a command line nobody can read back, nobody can diff, and whose
# every value stands in this machine's process listing. One file states the whole
# installation; this reads it and starts.
#
# THE TWIN OF from-windows.ps1, doing the same four things in the same order:
# refuse a file anyone else can read, compose the envelope, open one session, keep
# every line that comes back. The installation itself is on-machine.sh and it runs
# ON THE MACHINE — nothing is fetched here and nothing is carried from this disk,
# so what stands on the machine afterwards is what the repositories say rather
# than what this checkout happened to hold.
#
# THE FILE CARRIES CREDENTIALS AND IS REFUSED UNLESS IT IS PROTECTED. Nine of
# deploy-branch's answers are credentials — three repository write tokens, a DNS
# token, a storage password, a registry token — and two more open this session and
# the catalogue. A file readable by anyone on this machine is refused by name, and
# so is one standing inside a git working tree, because the mistake that is made
# once is `git add .`.
# =============================================================================

set -uo pipefail

readonly FILE="${1:-./installation.json}"
readonly HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly DRIVER="$HERE/on-machine.sh"

fail() { printf '\n  %s\n\n' "$*" >&2; exit "${2:-65}"; }

[ -r "$DRIVER" ] || fail 'on-machine.sh is not beside this file — it IS the installation, and this only starts it' 66
[ -r "$FILE" ]   || fail "there is no installation file at $FILE. Copy installation.example.json, fill it in, then chmod 600 it" 66

# ------------------------------------------------------- the file, and its guard
# OWNER-ONLY OR NOTHING. `stat` spells its arguments differently on Linux and on
# macOS, and both are asked rather than one being assumed.
MODE=$(stat -c '%a' "$FILE" 2>/dev/null || stat -f '%Lp' "$FILE" 2>/dev/null)
case "$MODE" in
  600|400) ;;
  *) fail "$FILE is mode ${MODE:-unknown} and carries credentials — nine of deploy-branch's answers are tokens with write access to your repositories. Run: chmod 600 $FILE" 77 ;;
esac

# INSIDE A GIT TREE IS REFUSED, because the mistake is made once and cannot be
# taken back: a token that reached a remote is a token that must be rotated.
if git -C "$(dirname "$FILE")" rev-parse --show-toplevel >/dev/null 2>&1; then
  tree=$(git -C "$(dirname "$FILE")" rev-parse --show-toplevel)
  fail "$FILE stands inside the git working tree at $tree. A file of credentials belongs nowhere a commit can reach it — move it out, or say so in that tree's .gitignore and move it anyway" 77
fi

# ------------------------------------------------------------- what it must say
python3 - "$FILE" <<'PY' || exit 65
import json, sys

path = sys.argv[1]
try:
    stated = json.load(open(path))
except json.JSONDecodeError as broken:
    sys.exit(f"{path} is not readable as JSON: {broken}")

MACHINE = ("fqdn", "address", "operator_user", "stage")
for named in MACHINE:
    if not stated.get("machine", {}).get(named):
        sys.exit(f'{path} states no machine.{named}, and nothing here may choose one')
for named in ("elevation_password", "catalog_token"):
    if not stated.get("credentials", {}).get(named):
        sys.exit(f'{path} states no credentials.{named} — the first opens this session, the second the private catalogue')
for named in ("catalog", "platform"):
    if not stated.get("repositories", {}).get(named):
        sys.exit(f'{path} states no repositories.{named}')
answers = stated.get("answers") or {}
if not answers:
    sys.exit(f"{path} states no answers at all, and an installation is what its answers say")
for named in ("operator_user", "fqdn"):
    if not answers.get(named):
        sys.exit(f'{path} states no answers.{named}')
if answers["fqdn"] != stated["machine"]["fqdn"]:
    sys.exit(f'{path} says machine.fqdn "{stated["machine"]["fqdn"]}" and answers.fqdn "{answers["fqdn"]}" — one installation, one name')
if answers["operator_user"] != stated["machine"]["operator_user"]:
    sys.exit(f'{path} names two different operator accounts — one installation, one account')
# NAMED HERE BEFORE THE MACHINE IS TOUCHED, because an apostrophe in a mailbox
# makes the cluster map unparseable and the run dies far from the cause
# (simetrixch/ansiwise-plugins#161).
carrying = [k for k, v in answers.items() if isinstance(v, str) and "'" in v]
if carrying:
    sys.exit(f'{path}: {", ".join(carrying)} carries an apostrophe, and a template slot standing inside quotes has no way to say so — simetrixch/ansiwise-plugins#161')
PY

FQDN=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["machine"]["fqdn"])' "$FILE")
ADDRESS=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["machine"]["address"])' "$FILE")
OPERATOR=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["machine"]["operator_user"])' "$FILE")
PORT=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["machine"].get("port", 22))' "$FILE")

# THE ENVELOPE IS COMPOSED IN MEMORY and reaches the machine over standard input;
# it touches no disk on this side and stands in no argument list.
ENVELOPE=$(python3 -c 'import json,sys
d = json.load(open(sys.argv[1]))
json.dump({
    "answers": d["answers"],
    "elevation_password": d["credentials"]["elevation_password"],
    "catalog_token": d["credentials"]["catalog_token"],
    "catalog_repo": d["repositories"]["catalog"],
    "platform_repo": d["repositories"]["platform"],
    "stage": d["machine"]["stage"],
}, sys.stdout)' "$FILE") || exit 65

# --------------------------------------------------------------- the transcript
SESSION="./install-transcripts/$FQDN-$(date -u +%Y%m%d-%H%M%S)"
mkdir -p "$SESSION"
TRANSCRIPT="$SESSION/session.log"
printf '\n  %s  ·  %s  ·  stage %s\n' "$FQDN" "$ADDRESS" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["machine"]["stage"])' "$FILE")" >&2
printf '  Everything said here is also kept in %s\n' "$TRANSCRIPT" >&2

TARGET="$OPERATOR@$ADDRESS"
SSH=(ssh -p "$PORT" -o BatchMode=yes -o ConnectTimeout=20 "$TARGET")

printf '%s' "$ENVELOPE" | "${SSH[@]}" 'umask 077 && cat > ~/.aw-envelope.json' \
  || fail "could not reach $TARGET, or could not write the envelope there" 69
unset ENVELOPE

# THE INSTALLATION, over the same session, with the driver on standard input so
# that nothing this put there is left on the machine.
"${SSH[@]}" 'bash -s -- ~/.aw-envelope.json' < "$DRIVER" 2>&1 | tee "$TRANSCRIPT"
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
