#!/usr/bin/env bash
# =============================================================================
# regenerate-driver.sh — the regeneration of ONE install branch, ON THE MACHINE
# ITSELF. regenerate-install-branch.sh and regenerate-install-branch.ps1 stream
# this file over the session they open, exactly as install-machine.sh and
# install-machine.ps1 stream driver.sh.
# =============================================================================
#
# WHAT THIS IS. A driver. It runs no step and changes nothing a program would not
# change: it composes the answers regenerate-branch is told with and invokes the
# program, once per mode. The regeneration itself is regenerate-branch.yaml in
# the catalogue standing on this machine, and every decision about what a branch
# becomes is a row of that file.
#
# WHY IT IS A FILE OF ITS OWN RATHER THAN TEXT INSIDE THE TWO LAUNCHERS. The
# answers are composed HERE, out of the program's own declaration, and the
# launchers are two spellings of one act — so text carried inside them would be
# two copies of this composition and the pair would come to disagree the first
# time one was corrected. One file, streamed by both, cannot.
#
# WHY THE ANSWERS ARE COMPOSED ON THIS MACHINE AND NOT ON THE WORKSTATION. The
# names are read off regenerate-branch.yaml in the catalogue standing here, so
# nothing on the workstation holds a list of answers that could fall behind what
# the program declares. The catalogue is on this machine and not on that one.
#
# WHAT IT IS TOLD, and it is the only thing that reaches it from outside: the
# same key=value config file the operator filled in for the installation, carried
# over the session as it stands, with one line added by the launcher —
# PLATFORM_REF, read off the `release:` line of this cluster's own map. The
# launcher reads the pin so that nobody states the ref a second time.
#
# It is read once, mode 0600, and shredded before this exits — on every path,
# including a failure. What is left on the machine afterwards carries no
# credential this put there.
#
# WHAT IT PRINTS IS ASCII. The line goes back over the session to a console
# whose code page nobody here knows, and a byte outside ASCII arrives there as
# something else. The comments in this file are read by people and may say what
# they like.
# =============================================================================

set -uo pipefail

say()  { printf '   %s\n' "$*"; }
good() { printf '   ok   %s\n' "$*"; }
bad()  { printf '   RED  %s\n' "$*" >&2; }
die()  { bad "$1"; exit "${2:-1}"; }

# ------------------------------------------------------------ what it was told
readonly CONFIG="${1:?the config's path is this script's only argument}"
[ -r "$CONFIG" ] || die "there is no config at $CONFIG, and it is the only thing this is told" 64
# WHETHER A DIRTY CHECKOUT MAY BE THROWN AWAY, stated by the person and never
# assumed. Only the deployment programs write /srv/hostyour-cloud and they commit
# what they write, so anything uncommitted there is debris a failed run left. It
# is still not discarded on its own: a merge that folds away whatever is lying
# around hides the reason it was lying around, and the refusal is what names it.
readonly DISCARD="${2:-}"

ANSWERS_DIR=''
# SHREDDED ON EVERY PATH. A credential that outlives the act it was handed over
# for is a credential nobody is watching, and most of what regenerate-branch is
# told is credentials.
cleanup() {
  rm -f "$CONFIG" 2>/dev/null || true
  rm -rf "${ANSWERS_DIR:-}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# NOTHING BUT ASSIGNMENTS AND COMMENTS, checked BEFORE this file is read, because
# reading it is running it: a shell `.` executes every line, so a config carrying
# a command would run it as this account. The launcher checks the same thing on
# the operator's side; it is checked again HERE because what arrives is what
# matters and a session is not a promise.
BAD=$(grep -nvE "^[[:space:]]*(#.*)?$|^[A-Z][A-Z0-9_]*='[^']*'[[:space:]]*(#.*)?$" "$CONFIG" | head -3)
[ -z "$BAD" ] || die "the config carries lines that are neither a comment nor NAME='value', and this file is READ BY THE SHELL: $BAD" 65

# AND NO CARRIAGE RETURN. The shape check above lets one through — a CR falls
# after the closing quote, where [[:space:]] matches it — and a bash on Linux
# then reads it as part of the value, so a ref ending in a control character
# would be fetched and the first thing to say so would be a merge naming a
# commit nobody wrote. COUNTED RATHER THAN MATCHED: grep on a Windows
# workstation opens a file in text mode and strips the very byte it is being
# asked about, and tr reads bytes on both.
[ "$(tr -dc '\r' < "$CONFIG" | wc -c)" -eq 0 ] \
  || die 'the config carries carriage returns, so every value would end in one. Write it with Unix line endings' 65

# shellcheck disable=SC1090
. "$CONFIG"

readonly STAGE="${STAGE:-}"
readonly FQDN="${FQDN:-}"
readonly OPERATOR="${OPERATOR_USER:-}"
readonly PLATFORM_REF="${PLATFORM_REF:-}"

for named in STAGE FQDN OPERATOR PLATFORM_REF; do
  [ -n "${!named}" ] || die "the config says nothing under ${named}, and nothing here may choose one" 64
done
[ -n "${ELEVATION_PASSWORD:-}" ] \
  || die 'the config states no ELEVATION_PASSWORD, and a regeneration is run elevated' 64

readonly CATALOG=/srv/ansiwise-catalog
readonly ENGINE=/usr/local/bin/ansiwise
readonly RUNS=/var/lib/ansiwise/runs
readonly PROGRAM=regenerate-branch
readonly DECLARES="$CATALOG/ansiwise/programs/$PROGRAM.yaml"
ANSWERS_DIR="/home/$OPERATOR/.regenerate-answers"

# THE ROLE THE RUN IS STARTED UNDER IS master, AND IT IS NOT THIS MACHINE'S OWN
# ROLE. regenerate-branch.yaml states `roles: [master]` — the cluster maps and
# the books stand on the master's branch, which is the branch this regenerates —
# so master is the only role it admits. What every part of this machine carries
# is the `role` ANSWER, which the config states and the stamps below write.
readonly RUN_ROLE=master
# THE TREE THE MERGE HAPPENS IN. The program names it on every `repository:` row
# of its own; this names it once, to look at before the program is started.
readonly PLATFORM=/srv/hostyour-cloud

# ------------------------------------------- what a failed run may have left
# NAMED BEFORE IT GOES, every path of it. A count says nothing a reader can act
# on, and the one thing worth knowing about a discarded change is what it was.
DIRTY=$(git -C "$PLATFORM" status --porcelain 2>/dev/null || true)
if [ -n "$DIRTY" ]; then
  if [ "$DISCARD" = "--discard" ]; then
    say "$PLATFORM carries changes nothing declared, and --discard was given, so they are thrown away:"
    printf '%s
' "$DIRTY" | while IFS= read -r line; do say "    $line"; done
    git -C "$PLATFORM" reset --quiet --hard       || die "could not put $PLATFORM back on its own last commit" 70
    git -C "$PLATFORM" clean -qfd       || die "could not remove what was left standing in $PLATFORM" 70
    good "$PLATFORM stands on its own last commit again"
  else
    say "$PLATFORM carries changes nothing declared:"
    printf '%s
' "$DIRTY" | while IFS= read -r line; do say "    $line"; done
    die "a merge over them would fold changes nobody declared into the merge commit. Read them above: they are either debris a failed run left, in which case start this again with --discard, or something that belongs in the repository, in which case it belongs there and not on a machine" 65
  fi
fi

# ONLY WHAT AN INSTALLATION ALREADY HAS. Both of these are put here by
# deploy-host at an installation's birth, and this is a regeneration: a machine
# carrying neither is a machine nothing has installed, and the act for that is
# lifecycle/install-machine.sh.
[ -d "$CATALOG" ] \
  || die "there is no catalogue at $CATALOG, so the programs a regeneration runs are not on this machine. A machine is given them by lifecycle/install-machine.sh at its birth; nothing has been changed" 66
[ -x "$ENGINE" ] \
  || die "there is no engine at $ENGINE, and it is what runs a program. A machine is given it by lifecycle/install-machine.sh at its birth; nothing has been changed" 66
[ -r "$DECLARES" ] \
  || die "$DECLARES cannot be read, and it is what states the answers $PROGRAM takes; nothing has been changed" 66
command -v python3 >/dev/null 2>&1 \
  || die 'python3 is not on this path, and the answers envelope is composed with it; nothing has been changed' 66

say "$FQDN, stage $STAGE, regenerated onto $PLATFORM_REF"

# =============================================================================
# THE ANSWERS, composed out of the config and the program's own declaration.
#
# THE NAMES ARE READ OFF THE PROGRAM ITSELF, out of the catalogue standing on
# this machine, so nothing here holds a list that could fall behind what the
# program declares. The config's names are those names in upper case.
#
# COMPOSED ONCE, NOT ONCE PER MODE. test, dry and run gate one another on a
# fingerprint taken over what the run was told, so the three have to be told by
# the same bytes.
#
# AN EMPTY VALUE IS LEFT OUT rather than written as an empty string. A value the
# config does not state is one the operator wants the program's DECLARED DEFAULT
# for, and an empty string is not that default — it is an answer that overrides
# it with nothing. On a regeneration that is what makes the credentials optional:
# an answer nobody gave fills no key, and the file on this machine keeps what it
# holds.
#
# THE ELEVATION PASSWORD STANDS BESIDE THE ANSWERS, NOT AMONG THEM. It is what
# the run was STARTED with, not something a caller answers, and the engine
# refuses an envelope carrying it among the answers by name.
#
# driver.sh beside this file composes the same envelope out of the same config grammar
# for the five programs that make a master. The two are two statements of one
# grammar, and nothing holds them against each other.
# =============================================================================
mkdir -p "$ANSWERS_DIR" && chmod 700 "$ANSWERS_DIR" \
  || die "could not make $ANSWERS_DIR, and the answers are written there" 73

ANSWERS="$ANSWERS_DIR/$PROGRAM.json"
COUNTED=$(python3 - "$CONFIG" "$DECLARES" "$ANSWERS" <<'COMPOSE'
import json, re, sys

BESIDE = 'elevation_password'
config_path, declares_path, into = sys.argv[1], sys.argv[2], sys.argv[3]

stated = {}
for line in open(config_path, encoding='utf-8'):
    named = re.match(r"^([A-Z][A-Z0-9_]*)='([^']*)'\s*(#.*)?$", line)
    if named and named.group(2) != '':
        stated[named.group(1).lower()] = named.group(2)

# WHAT EACH ANSWER IS, not only what it is called. An answer declared as a list
# and given a string is refused by kind, and the config has one line per name, so
# the shape has to be read off the program rather than guessed from the value.
declared, kinds, inside, current = [], {}, False, None
for line in open(declares_path, encoding='utf-8').read().splitlines():
    if re.match(r'^answers:\s*(#.*)?$', line):
        inside = True
        continue
    if not inside:
        continue
    if line.strip() and not line[0].isspace():
        break
    entry = re.match(r'^\s*-\s*name:\s*([a-z][a-z0-9_]*)\s*(#.*)?$', line)
    if entry:
        current = entry.group(1)
        declared.append(current)
        continue
    of_kind = re.match(r'^\s+kind:\s*(\S+)', line)
    if of_kind and current:
        kinds[current] = of_kind.group(1)


def shaped(name, value):
    """The value as the kind the program declared it, out of one config line.

    A LIST IS WRITTEN COMMA-SEPARATED, because a config file states one value per
    line and a list has to fit on that line. Whitespace around an entry is the
    operator's formatting, not part of the entry, and an empty entry is a
    trailing comma rather than a member."""
    if kinds.get(name, '').endswith('_list'):
        return [part.strip() for part in value.split(',') if part.strip()]
    return value


answers = {name: shaped(name, stated[name]) for name in declared
           if name in stated and name != BESIDE}
envelope = {'answers': answers}
if BESIDE in stated:
    envelope[BESIDE] = stated[BESIDE]

with open(into, 'w', encoding='utf-8') as written:
    json.dump(envelope, written, indent=2)

silent = [name for name in declared if name not in stated and name != BESIDE]
print(f"{len(answers)} of the {len(declared)} it declares"
      + (f", and {len(silent)} left to its own default: {' '.join(silent)}" if silent else ""))
COMPOSE
) || die "could not write the answers for $PROGRAM; nothing has been changed" 73

chmod 600 "$ANSWERS" || die "could not close $ANSWERS to this account alone" 73
say "$PROGRAM is told $COUNTED"

# THE REF IT WAS TOLD, SAID OUT LOUD. It is the one answer that did not come from
# the operator's config, and it is what this whole act is about.
say "platform_ref is $PLATFORM_REF, read off the pin in clusters/active/$FQDN.yaml"

# =============================================================================
# THE THREE MODES, which gate one another: a test that measures, a dry run that
# cannot mutate, and a real run the engine refuses without a green dry run for
# the same input. A mode that is not green stops this here rather than carrying a
# doubt into the next one.
# =============================================================================
RAN=0
for mode in test dry run; do
  printf '\n   %s %s\n' "$PROGRAM" "$mode"
  BEGAN=$(date +%s)

  # `-u "$OPERATOR"` IS NOT ELEVATION. The tool runs as the account that owns
  # this machine — the same account the Manager starts it as — and what sudo does
  # here is the other thing it does when it enters an account: it builds that
  # account's group set afresh out of the group database. What needs root is
  # raised one command at a time, by the tool, from the row that needs it, with
  # the password that rides beside the answers.
  #
  # THE PASSWORD REACHES sudo ON STANDARD INPUT and is never an argument, which
  # would stand in this machine's own process listing for anyone on it to read.
  printf '%s\n' "$ELEVATION_PASSWORD" | ( cd "$CATALOG" && sudo -S -p '' -u "$OPERATOR" "$ENGINE" "$PROGRAM" \
      --programs "$CATALOG/ansiwise/programs" \
      --config "$CATALOG/ansiwise.yaml" \
      --answers "$ANSWERS" \
      --runs "$RUNS" \
      --role "$RUN_ROLE" --stage "$STAGE" --fqdn "$FQDN" \
      --mode "$mode" ) 2>&1 | sed -u 's/^/       /'
  # THE SECOND ELEMENT, not the last. The pipeline is printf, the run, sed — so
  # $? is sed's, which succeeds whatever the run did.
  STATUS=${PIPESTATUS[1]}
  TOOK=$(( $(date +%s) - BEGAN ))

  if [ "$STATUS" -ne 0 ]; then
    bad "$PROGRAM ($mode) ended with exit $STATUS after ${TOOK}s"
    say "the machine's own record of it stands under $RUNS"
    if [ "$mode" = run ] && [ "$RAN" = 1 ]; then
      say 'the run had already begun, so read the step above before starting this again: what it did stands'
    else
      say 'nothing was mutated: test measures and dry cannot write'
    fi
    exit "$STATUS"
  fi
  good "$PROGRAM $mode is green (${TOOK}s)"
  [ "$mode" = run ] && RAN=1
done

printf '\n'
good "$FQDN stands on $PLATFORM_REF: its branch is merged, stamped, committed and pushed"
say "the machine's own records stand under $RUNS"

# THIS FILE IS READ FROM STANDARD INPUT, so what follows it on that stream is
# read as more of it. PowerShell appends its own newline when it pipes a string
# to a native command, and on Windows that newline is CRLF — so the last thing to
# arrive is a lone carriage return on a line of its own, which bash tries to run.
# An explicit exit ends the script where the script ends, and bash reads no
# further.
exit 0
