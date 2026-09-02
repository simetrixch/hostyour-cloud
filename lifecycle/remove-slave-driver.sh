#!/usr/bin/env bash
# =============================================================================
# remove-slave-driver.sh — the removal of ONE slave's registration, ON THE MASTER
# ITSELF. remove-slave-from-master.sh and remove-slave-from-master.ps1 stream this
# file over the session they open, exactly as install-machine.sh and
# install-machine.ps1 stream driver.sh.
# =============================================================================
#
# WHAT THIS IS. A driver. It runs no step and changes nothing a program would not
# change: it composes the answers remove-slave is told with and invokes the
# program, once per mode. The removal itself is remove-slave.yaml in the catalogue
# standing on this machine, and every decision about what goes and what stays is a
# row of that file.
#
# WHY IT IS A FILE OF ITS OWN RATHER THAN TEXT INSIDE THE TWO LAUNCHERS. The
# answers are composed HERE, out of the program's own declaration, and the
# launchers are two spellings of one act — so text carried inside them would be
# two copies of this composition and the pair would come to disagree the first
# time one was corrected. One file, streamed by both, cannot.
#
# WHY THE ANSWERS ARE COMPOSED ON THIS MACHINE AND NOT ON THE WORKSTATION. The
# names are read off remove-slave.yaml in the catalogue standing here, so nothing
# on the workstation holds a list of answers that could fall behind what the
# program declares. The catalogue is on this machine and not on that one.
#
# AND ONE OF THOSE NAMES IS NOBODY'S TO ANSWER. remove-slave declares
# slave_cluster_name as the first DNS label of slave_fqdn, and the engine refuses
# an envelope that carries a derived answer as well — supplying it is supplying a
# second version of a fact already stated, and a pair that does not match is
# exactly what deriving it prevents. So the composer below reads `derived:` off
# the declaration and leaves every answer it marks out, and says which ones it
# left out rather than being silent about them.
#
# WHAT IT IS TOLD, and it is the only thing that reaches it from outside: the
# same key=value config file the operator filled in for the MASTER, carried over
# the session as it stands, with two lines added by the launcher — MASTER_FQDN,
# which is that config's own FQDN under the name the program declares for it, and
# SLAVE_FQDN, which is the slave named on the command line.
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

ANSWERS_DIR=''
# SHREDDED ON EVERY PATH. A credential that outlives the act it was handed over
# for is a credential nobody is watching, and the config this is told carries the
# elevation password of the machine it is standing on.
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
# then reads it as part of the value, so a slave's domain ending in a control
# character would name a mount nothing ever created and the removal would report
# every one of its rows as already gone. COUNTED RATHER THAN MATCHED: grep on a
# Windows workstation opens a file in text mode and strips the very byte it is
# being asked about, and tr reads bytes on both.
[ "$(tr -dc '\r' < "$CONFIG" | wc -c)" -eq 0 ] \
  || die 'the config carries carriage returns, so every value would end in one. Write it with Unix line endings' 65

# shellcheck disable=SC1090
. "$CONFIG"

readonly STAGE="${STAGE:-}"
readonly FQDN="${FQDN:-}"
readonly OPERATOR="${OPERATOR_USER:-}"
readonly MASTER_FQDN="${MASTER_FQDN:-}"
readonly SLAVE_FQDN="${SLAVE_FQDN:-}"

for named in STAGE FQDN OPERATOR MASTER_FQDN SLAVE_FQDN; do
  [ -n "${!named}" ] || die "the config says nothing under ${named}, and nothing here may choose one" 64
done
[ -n "${ELEVATION_PASSWORD:-}" ] \
  || die 'the config states no ELEVATION_PASSWORD, and a removal is run elevated' 64

readonly CATALOG=/srv/ansiwise-catalog
readonly ENGINE=/usr/local/bin/ansiwise
readonly RUNS=/var/lib/ansiwise/runs
readonly PROGRAM=remove-slave
readonly DECLARES="$CATALOG/ansiwise/programs/$PROGRAM.yaml"
ANSWERS_DIR="/home/$OPERATOR/.remove-slave-answers"

# THE ROLE THE RUN IS STARTED UNDER IS master, AND IT IS THIS MACHINE'S OWN.
# remove-slave.yaml states `roles: [master]` because everything it takes down is
# an object of the master's installation: the store the mount and the policies
# stand in, the coordinator the membership stands at, and the reconciler the
# project stands in.
readonly RUN_ROLE=master
# THE CHECKOUT THE PROGRAM READS ITS OWN FACTS OUT OF. Every store row of the
# program names it as its repository — the root token stands under it, and so
# does the map the endpoint and the auth path are read from.
readonly PLATFORM=/srv/hostyour-cloud

# ONLY WHAT AN INSTALLATION ALREADY HAS. All four of these are put here by
# deploy-host at an installation's birth, and this is a removal: a machine
# carrying none of them is a machine nothing has installed, and there is nothing
# on it for a slave to have been registered against.
[ -d "$CATALOG" ] \
  || die "there is no catalogue at $CATALOG, so the programs a removal runs are not on this machine. A machine is given them by lifecycle/install-machine.sh at its birth; nothing has been changed" 66
[ -x "$ENGINE" ] \
  || die "there is no engine at $ENGINE, and it is what runs a program. A machine is given it by lifecycle/install-machine.sh at its birth; nothing has been changed" 66
[ -r "$DECLARES" ] \
  || die "$DECLARES cannot be read, and it is what states the answers $PROGRAM takes; nothing has been changed" 66
[ -d "$PLATFORM" ] \
  || die "there is no checkout at $PLATFORM, and it is where this installation's store credentials and its own cluster map stand; nothing has been changed" 66
command -v python3 >/dev/null 2>&1 \
  || die 'python3 is not on this path, and the answers envelope is composed with it; nothing has been changed' 66

say "$SLAVE_FQDN, stage $STAGE, taken off $MASTER_FQDN"

# =============================================================================
# THE ANSWERS, composed out of the config and the program's own declaration.
#
# THE NAMES ARE READ OFF THE PROGRAM ITSELF, out of the catalogue standing on
# this machine, so nothing here holds a list that could fall behind what the
# program declares. The config's names are those names in upper case, which is
# what the launcher's two appended lines are written as.
#
# COMPOSED ONCE, NOT ONCE PER MODE. test, dry and run gate one another on a
# fingerprint taken over what the run was told, so the three have to be told by
# the same bytes.
#
# AN ANSWER THE PROGRAM WORKS OUT ITSELF IS LEFT OUT, whatever the config says.
# The engine refuses an envelope carrying a derived answer, because supplying it
# is supplying a second version of a fact already stated — and for this program
# that fact is the one every object it removes is named after, so a pair that did
# not match would take a slave nobody registered off while the registered one kept
# everything.
#
# AN EMPTY VALUE IS LEFT OUT rather than written as an empty string. A value the
# config does not state is one the operator wants the program's DECLARED DEFAULT
# for, and an empty string is not that default — it is an answer that overrides it
# with nothing.
#
# THE ELEVATION PASSWORD STANDS BESIDE THE ANSWERS, NOT AMONG THEM. It is what
# the run was STARTED with, not something a caller answers, and the engine
# refuses an envelope carrying it among the answers by name.
#
# driver.sh and regenerate-driver.sh beside this file compose the same envelope
# out of the same config grammar for the programs they drive. The three are three
# statements of one grammar, and nothing holds them against each other.
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
# `derived:` is read off the same block for the same reason: which answers the
# program works out for itself is the program's statement and nobody else's.
declared, kinds, worked_out, inside, current = [], {}, [], False, None
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
    if re.match(r'^\s+derived:\s*\S+', line) and current and current not in worked_out:
        worked_out.append(current)


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
           if name in stated and name != BESIDE and name not in worked_out}
envelope = {'answers': answers}
if BESIDE in stated:
    envelope[BESIDE] = stated[BESIDE]

with open(into, 'w', encoding='utf-8') as written:
    json.dump(envelope, written, indent=2)

silent = [name for name in declared
          if name not in stated and name != BESIDE and name not in worked_out]
print(f"{len(answers)} of the {len(declared)} it declares"
      + (f", {len(worked_out)} it works out itself: {' '.join(worked_out)}" if worked_out else "")
      + (f", and {len(silent)} left to its own default: {' '.join(silent)}" if silent else ""))
COMPOSE
) || die "could not write the answers for $PROGRAM; nothing has been changed" 73

chmod 600 "$ANSWERS" || die "could not close $ANSWERS to this account alone" 73
say "$PROGRAM is told $COUNTED"

# WHICH SLAVE THIS IS ABOUT, SAID OUT LOUD. It is the one answer that did not
# come from the operator's config, and every object the program removes is named
# after the label the program works out of it.
say "slave_fqdn is $SLAVE_FQDN, so what goes is named after ${SLAVE_FQDN%%.*}"

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
good "$SLAVE_FQDN is off $MASTER_FQDN: its auth mount, its policies, its entries in the slaves tier, its reconciler project and its membership at the coordinator are gone"
say "the machine's own records stand under $RUNS"

# THIS FILE IS READ FROM STANDARD INPUT, so what follows it on that stream is
# read as more of it. PowerShell appends its own newline when it pipes a string
# to a native command, and on Windows that newline is CRLF — so the last thing to
# arrive is a lone carriage return on a line of its own, which bash tries to run.
# An explicit exit ends the script where the script ends, and bash reads no
# further.
exit 0
