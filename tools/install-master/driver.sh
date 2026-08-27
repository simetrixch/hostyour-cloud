#!/usr/bin/env bash
# =============================================================================
# driver.sh — a first master, installed from zero, ON THE MACHINE ITSELF.
# =============================================================================
#
# WHAT THIS IS. A driver. It runs no step and changes nothing a program would not
# change: it reads the order out of clusters/platform/install-order.yaml's own
# sequence, puts the two things a program cannot put there itself — the engine and
# the catalogue — and then invokes the five programs, each of them three times.
# install-order.yaml states that division in its own words: "THIS FILE STATES THE
# ORDER. IT DOES NOT RUN IT. A driver reads the sequence and invokes the programs
# itself."
#
# WHY IT RUNS HERE AND NOT ON THE OPERATOR'S MACHINE. Everything it fetches is
# fetched by THIS machine: the pin out of the public platform repository, the two
# executables out of the public release, the catalogue out of the private one with
# a read credential handed over for the length of that clone. Nothing is carried
# from the operator's own disk, so what stands here afterwards is what the
# repositories say and not what somebody's checkout happened to hold.
#
# THE ONE THING IT DOES THAT NO PROGRAM DOES, stated rather than hidden: it
# installs `git`, `curl` and `python3` when they are missing. deploy-host's
# install_packages row installs all three — and the catalogue those programs are
# READ FROM cannot be cloned without git, so the first of them cannot run without
# it. That is the whole of the exception, it is reported before it happens, and a
# machine that already carries all three is not touched.
#
# WHAT IT NEVER DOES. It composes no shell for a program, it edits no file a
# program owns, and it makes no decision an answer should make. Every value it
# uses comes out of the config the operator wrote; a value it cannot find is a
# refusal by name, never a default.
#
# THE CONFIG, and it is the only thing that reaches this from outside: the same
# key=value file the operator filled in, carried over the session as it stands.
# Every value in it is one the five programs declare, lower-cased into the answers
# a run is told with.
#
# It is read once, mode 0600, and shredded before this exits — on every path,
# including a failure. What is left on the machine afterwards carries no
# credential this put there.
#
# TRACEABILITY IS THE POINT. Every line of every program reaches standard output
# here, prefixed with the program and the mode it belongs to, so the operator's
# session carries the whole of it. The machine's OWN record of each run —
# /var/lib/ansiwise/runs/<id> — is what the launcher fetches afterwards; this
# names each run's identifier on a line of its own so nothing has to be guessed.
# =============================================================================

set -uo pipefail

# ---------------------------------------------------------------- what it says
# One vocabulary for the whole run, so a reader can tell a phase from a step from
# a machine's own words at a glance, and so a log kept as plain text still reads.
readonly C_OFF=$'\033[0m' C_DIM=$'\033[2m' C_RED=$'\033[31m' C_GRN=$'\033[32m'
readonly C_YEL=$'\033[33m' C_BLU=$'\033[36m' C_BLD=$'\033[1m'

# Every warning and every refusal, kept as they happen and said again at the end:
# a run of ninety steps scrolls, and the two lines that mattered must not be the
# two the operator missed.
WARNINGS=()
FAILURES=()

stamp() { date -u +%H:%M:%S; }
phase() { printf '\n%s══ %s %s%s\n' "$C_BLD$C_BLU" "$(stamp)" "$*" "$C_OFF"; }
say()   { printf '%s   %s%s\n' "$C_DIM" "$*" "$C_OFF"; }
good()  { printf '%s   ✓ %s%s\n' "$C_GRN" "$*" "$C_OFF"; }
warn()  { WARNINGS+=("$*"); printf '%s   ! %s%s\n' "$C_YEL" "$*" "$C_OFF"; }
bad()   { FAILURES+=("$*"); printf '%s   ✗ %s%s\n' "$C_RED" "$*" "$C_OFF"; }

# Ends the whole installation, saying what stopped it and what was already done.
# NEVER a bare exit: an operator who is told only a number has to come back to the
# machine to find out what it meant.
die() {
  bad "$1"
  summary
  exit "${2:-1}"
}

summary() {
  printf '\n%s══ %s what this run leaves behind%s\n' "$C_BLD$C_BLU" "$(stamp)" "$C_OFF"
  if [ ${#WARNINGS[@]} -eq 0 ]; then
    say 'no warnings'
  else
    printf '%s   %d warning(s):%s\n' "$C_YEL" "${#WARNINGS[@]}" "$C_OFF"
    for w in "${WARNINGS[@]}"; do printf '%s     ! %s%s\n' "$C_YEL" "$w" "$C_OFF"; done
  fi
  if [ ${#FAILURES[@]} -eq 0 ]; then
    good 'nothing failed'
  else
    printf '%s   %d failure(s):%s\n' "$C_RED" "${#FAILURES[@]}" "$C_OFF"
    for f in "${FAILURES[@]}"; do printf '%s     ✗ %s%s\n' "$C_RED" "$f" "$C_OFF"; done
  fi
  # The launcher reads this line to know which records to fetch. One line, one
  # run identifier, in the order they happened.
  printf '\n%s   RUNS %s%s\n' "$C_DIM" "${RUN_IDS[*]:-}" "$C_OFF"
}

# ------------------------------------------------------------ what it was told
readonly CONFIG="${1:?the config's path is this script's only argument}"
[ -r "$CONFIG" ] || die "there is no config at $CONFIG, and it is the only thing this is told" 64

# SHREDDED ON EVERY PATH. A credential that outlives the act it was handed over
# for is a credential nobody is watching.
# WHAT THIS PUT ON THE MACHINE, TAKEN OFF AGAIN ON EVERY PATH, including a failure.
# The answers are not an afterthought here: deploy-branch is told nine credentials,
# and a file holding them has no reason to outlive the run that needed it.
cleanup() {
  rm -f "$CONFIG" /tmp/.aw-askpass /tmp/.aw-token 2>/dev/null || true
  rm -rf "${ANSWERS_DIR:-}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# NOTHING BUT ASSIGNMENTS AND COMMENTS, checked BEFORE this file is read, because
# reading it is running it: a shell `.` executes every line, so a config carrying a
# command would run it as this account. The launcher checks the same thing on the
# operator's side; it is checked again HERE because what arrives is what matters
# and a session is not a promise.
BAD=$(grep -nvE "^[[:space:]]*(#.*)?$|^[A-Z][A-Z0-9_]*='[^']*'[[:space:]]*(#.*)?$" "$CONFIG" | head -3)
[ -z "$BAD" ] || die "the config carries lines that are neither a comment nor NAME='value', and this file is READ BY THE SHELL: $BAD" 65

# AND NO CARRIAGE RETURN. The shape check above lets one through — a CR falls after the
# closing quote, where [[:space:]] matches it — and a bash on Linux then reads it as part
# of the value, so a config written in Notepad would give this machine an FQDN ending in
# a control character and the first thing to say so would be a certificate issued for a
# name nobody typed. Both launchers strip it; this refuses it, because what arrives is
# what matters.
#
# COUNTED RATHER THAN MATCHED, because `grep` on a Windows workstation opens a file in
# text mode and strips the very byte it is being asked about — so the obvious spelling
# is green on the machine where the file is WRITTEN and only works on the one where it
# is read. `tr` reads bytes on both.
[ "$(tr -dc '\r' < "$CONFIG" | wc -c)" -eq 0 ] \
  || die 'the config carries carriage returns, so every value would end in one. Write it with Unix line endings' 65

# shellcheck disable=SC1090
. "$CONFIG"

readonly STAGE="${STAGE:-}"
readonly CATALOG_REPO="${CATALOG_REPO:-}"
readonly PLATFORM_REPO="${PLATFORM_REPO:-}"
readonly OPERATOR="${OPERATOR_USER:-}"
readonly FQDN="${FQDN:-}"
readonly TOKEN="${CATALOG_REPO_READ_PAT:-}"

for named in STAGE CATALOG_REPO PLATFORM_REPO OPERATOR FQDN TOKEN; do
  [ -n "${!named}" ] || die "the config says nothing under ${named}, and nothing here may choose one" 64
done

# WHERE A RELEASED EXECUTABLE IS FETCHED FROM. Public, so this machine reaches it
# with nothing but a certificate store — which is the whole reason a first master can
# arm itself rather than be armed from somebody's laptop. The pin says WHICH release;
# this says where releases are.
readonly RELEASES=https://github.com/simetrixch/ansiwise-cli/releases/download

readonly CATALOG=/srv/ansiwise-catalog
readonly ENGINE=/usr/local/bin/ansiwise
readonly RUNS=/var/lib/ansiwise/runs
readonly ANSWERS_DIR=/home/$OPERATOR/.install-master-answers
ANSWERS=''

RUN_IDS=()

# Every elevated command goes through here, and the password reaches it on
# STANDARD INPUT — never an argument list, which stands in this machine's own
# process listing for anyone on it to read.
root() { printf '%s
' "$ELEVATION_PASSWORD" | sudo -S -p '' "$@"; }

# =============================================================================
phase '0 / 5   what this machine is, before anything is touched'
# =============================================================================
say "asked as $(id -un) on $(hostname), for $FQDN, stage $STAGE"
say "$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME") · kernel $(uname -r) · $(nproc) cpu · $(free -g | awk '/^Mem:/{print $2}') GB"
say "free on /: $(df -h / | awk 'NR==2{print $4}')"

sudo -n true 2>/dev/null && warn 'this account already raises commands without a password — nothing here needs that'
printf '%s
' "$ELEVATION_PASSWORD" | sudo -S -p '' true 2>/dev/null || die 'the ELEVATION_PASSWORD in the config does not raise a command on this machine' 77
good 'the elevation password raises a command'

for path in "$CATALOG" /srv/hostyour-cloud /var/lib/ansiwise; do
  [ -e "$path" ] && warn "$path already stands here — this is not a bare machine, and what follows will act on what is there"
done

MISSING=()
for tool in git curl python3; do command -v "$tool" >/dev/null 2>&1 || MISSING+=("$tool"); done
if [ ${#MISSING[@]} -gt 0 ]; then
  say "this machine carries no ${MISSING[*]} — and the catalogue every program is READ FROM cannot be"
  say 'cloned without git, so the first program cannot run without it. This is the one'
  say "change here that no program makes, and deploy-host's install_packages row makes it again"
  root bash -c 'DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git curl python3' \
    || die "apt-get would not install ${MISSING[*]}" 70
  good "installed ${MISSING[*]}"
else
  good 'git, curl and python3 are already here — nothing installed'
fi

# =============================================================================
phase '1 / 5   the engine, at the version the platform repository pins'
# =============================================================================
# READ OFF THE PUBLIC PLATFORM REPOSITORY BY THIS MACHINE. The pin is one fact of
# an installation (clusters/platform/versions.yaml, cliTools.ansiwise.version) and
# no caller states a version: a machine carrying one no file names is a machine
# nobody can say anything about afterwards.
readonly PIN_URL="https://raw.githubusercontent.com/$PLATFORM_REPO/master/clusters/platform/versions.yaml"
say "reading the pin from $PIN_URL"
PIN_YAML=$(curl -fsSL "$PIN_URL") || die "$PIN_URL could not be read from this machine" 69
# SINGLE-QUOTED FOR THE SHELL, so every dollar and every quote below belongs to
# python and not to bash. The regexes therefore use double quotes throughout and
# never a single one.
PIN=$(printf '%s' "$PIN_YAML" | python3 -c 'import sys, re
text = sys.stdin.read()
# THE cliTools BLOCK AND NOT THE WHOLE FILE, and it may be the LAST one: a lookahead
# demanding another top-level key after it matched nothing at all, because it IS the
# last. \Z is what makes the end of the file an end of the block. Counter-probed
# against a decoy ansiwise: standing under another top-level key, which it does not take.
block = re.search(r"^cliTools:\s*$.*?(?=^\S|\Z)", text, re.S | re.M)
found = re.search(r"^  ansiwise:\s*$\s*^\s+version:\s*\"([^\"]+)\"", block.group(0) if block else "", re.M)
sys.stdout.write(found.group(1) if found else "")')
[ -n "$PIN" ] || die "$PIN_URL says nothing under cliTools.ansiwise.version" 65
good "the pin is $PIN"

STANDING=$("$ENGINE" --version 2>/dev/null || true)
if [ "$STANDING" = "$PIN" ]; then
  good "$ENGINE already answers $PIN — nothing fetched"
else
  [ -n "$STANDING" ] && say "$ENGINE answers $STANDING, which is not the pin"
  for tool in ansiwise ansiwise-rest; do
    url="$RELEASES/$PIN/$tool-$PIN-linux-x64"
    say "fetching $tool from $url"
    curl -fsSL -o "/tmp/$tool" "$url" || die "$url served nothing — check the release carries an asset under that name" 69
    [ -s "/tmp/$tool" ] || die "$url served an empty file, and an empty executable answers every command with a shell error" 69
    root install -m 755 "/tmp/$tool" "/usr/local/bin/$tool" || die "could not place $tool in /usr/local/bin" 73
    rm -f "/tmp/$tool"
  done
  # READ BACK OFF THE MACHINE, never off this script's own claim: a truncated
  # transfer, an asset that is an error page and an architecture this machine
  # cannot execute are all one answer here — not the pin.
  for tool in ansiwise ansiwise-rest; do
    answered=$("/usr/local/bin/$tool" --version 2>/dev/null || true)
    [ "$answered" = "$PIN" ] || die "/usr/local/bin/$tool answers ${answered:-nothing} after being placed, not $PIN" 69
  done
  good "/usr/local/bin/ansiwise and /usr/local/bin/ansiwise-rest answer $PIN"
fi

# =============================================================================
phase '2 / 5   the catalogue every program is read out of'
# =============================================================================
# install-order.yaml names four things that must stand under this ONE path, and
# says why it is not free: hostyour-vault-unseal.service's WorkingDirectory and
# both of its ExecStart lines name files under it.
# ASKED WITH ELEVATION, because a catalogue an elevated clone left behind is root's
# and an unelevated test would answer "not a checkout" about a checkout standing
# right there — sending this into a clone that dies on a non-empty directory.
if root test -d "$CATALOG/.git"; then
  good "$CATALOG is already a checkout — leaving it where it stands"
else
  say "cloning $CATALOG_REPO into $CATALOG"
  # THE CREDENTIAL REACHES GIT AND NOTHING ELSE. It is written into a file only
  # this account may read, git asks that file for it, and both are gone before this
  # phase ends. It is never a word of a command, because a word of a command stands
  # in the process listing.
  #
  # WRITTEN BY THIS ACCOUNT AND NOT THROUGH root(). root() feeds sudo the elevation
  # password on ITS OWN standard input, so anything piped into it is thrown away —
  # the token file was written EMPTY and github answered "Invalid username or token"
  # about a credential that is perfectly valid. Only the clone needs to be elevated,
  # because /srv is root's; root reads these two files without being given them.
  # ANY LEFTOVER IS TAKEN OUT WITH ELEVATION FIRST. An earlier version of this file
  # wrote both as root, so a machine that ran it once carries two root-owned files
  # this account cannot overwrite — and the failure would name the helper rather than
  # the leftover.
  root rm -f /tmp/.aw-askpass /tmp/.aw-token 2>/dev/null || true

  ( umask 077 && cat > /tmp/.aw-askpass <<'ASK'
#!/bin/sh
case "$1" in
  Username*) printf 'x-access-token' ;;
  *) cat /tmp/.aw-token ;;
esac
ASK
  ) || die 'could not prepare the credential helper' 73
  chmod 700 /tmp/.aw-askpass || die 'could not prepare the credential helper' 73
  ( umask 077 && printf '%s' "$TOKEN" > /tmp/.aw-token ) || die 'could not hand the read credential over' 73
  [ -s /tmp/.aw-token ] || die 'the read credential was not written — git would be handed an empty password and github would report it as an invalid token' 73

  root bash -c "GIT_ASKPASS=/tmp/.aw-askpass GIT_TERMINAL_PROMPT=0 git clone --quiet 'https://github.com/$CATALOG_REPO.git' '$CATALOG'"
  status=$?
  rm -f /tmp/.aw-token /tmp/.aw-askpass
  [ $status -eq 0 ] || die "could not clone $CATALOG_REPO — check the read credential and that the repository exists" 69
  good "cloned $CATALOG_REPO"
fi

# HANDED TO THIS ACCOUNT, on both paths, because the clone had to be elevated and
# what an elevated clone leaves behind belongs to root — including one left by an
# earlier run. Two things need it not to:
#
# This account reads the catalogue on the very next line, and every program is read
# out of it afterwards. And the Manager REFRESHES this checkout later WITHOUT
# elevation, on purpose — it holds no credential of its own and needs none, because
# the machine's own remote carries one. A tree it cannot write is a tree it cannot
# bring forward.
root chown -R "$OPERATOR:$OPERATOR" "$CATALOG" \
  || die "could not hand $CATALOG to $OPERATOR, and an elevated clone leaves it as root's" 73
good "$CATALOG belongs to $OPERATOR"

# WHAT THIS ACCOUNT CAN SEE, ASKED BEFORE WHAT IS MISSING. A directory this account
# cannot enter answers every question with "not there", so a check that only reports
# absence sends the reader looking in the repository for a file that is sitting on
# the machine.
[ -d "$CATALOG" ]  || die "$CATALOG is not a directory" 66
[ -r "$CATALOG" ] && [ -x "$CATALOG" ] \
  || die "$CATALOG cannot be read by $(id -un) — it stands as $(ls -ld "$CATALOG" 2>/dev/null | awk '{print $1, $3, $4}'). Nothing is missing from it; this account cannot look inside" 77

for needed in ansiwise.yaml ansiwise/programs ansiwise-boot.yaml ansiwise/boot-programs; do
  [ -e "$CATALOG/$needed" ] \
    || die "$CATALOG carries no $needed, and install-order.yaml names it as one of the four that must stand there. What does stand there: $(ls -A "$CATALOG" 2>/dev/null | tr '\n' ' ')" 66
done
good 'all four things install-order.yaml names stand in the catalogue'
say "catalogue at $(cd "$CATALOG" && git rev-parse --short HEAD 2>/dev/null || echo 'unknown')"

# The answers, written HERE and never carried: mode 0600 and this account's own,
# because every program reads them and nothing else may.
#
# ONE FILE PER PROGRAM, CARRYING WHAT THAT PROGRAM DECLARES AND NOTHING ELSE. An
# engine refuses an answer a program does not declare, by name and one line each —
# deploy-host declares four and was handed thirty-three, so it said so
# twenty-eight times. It is right to refuse: an answer no program asked for is a
# name somebody mistyped or one a program stopped using, and either is worth a
# refusal rather than a silent pass.
#
# The Manager composes per program in exactly this way, and its hostAnswers() is
# deploy-host's four (hostyour-manager/server/domains/runs/defs/deploy-slave.ts:150).
#
# THE NAMES ARE READ OFF THE PROGRAM ITSELF, out of the catalogue standing on this
# machine, so nothing here holds a list that could fall behind what the programs
# declare. The config's names are those names in upper case.
#
# COMPOSED ONCE PER PROGRAM, NOT ONCE PER MODE. test, dry and run gate one another
# on a fingerprint taken over what the run was told, so the three have to be told
# by the same bytes.
#
# AN EMPTY VALUE IS LEFT OUT rather than written as an empty string. A value the
# config does not state is one the operator wants the program's DECLARED DEFAULT
# for, and an empty string is not that default — it is an answer that overrides it
# with nothing.
#
# THE ELEVATION PASSWORD STANDS BESIDE THE ANSWERS, NOT AMONG THEM. It is what the
# run was STARTED with, not something a caller answers, and a step that needs it
# has it filled in by the run itself. The engine refuses an envelope carrying it
# among the answers by name — ansiwise-core/lib/src/model/caller_inputs.dart:62 —
# and it is right to: a password sitting in the answers would be recorded as one.
mkdir -p "$ANSWERS_DIR" && chmod 700 "$ANSWERS_DIR" \
  || die "could not make $ANSWERS_DIR, and the answers are written there" 73

compose_answers() {
  local program="$1"
  local declares="$CATALOG/ansiwise/programs/$program.yaml"
  [ -r "$declares" ] || { bad "$declares cannot be read, and it is what states the answers $program takes"; return 1; }

  ANSWERS="$ANSWERS_DIR/$program.json"
  local counted
  counted=$(python3 - "$CONFIG" "$declares" "$ANSWERS" <<'COMPOSE'
import json, re, sys

BESIDE = 'elevation_password'
config_path, declares_path, into = sys.argv[1], sys.argv[2], sys.argv[3]

stated = {}
for line in open(config_path, encoding='utf-8'):
    named = re.match(r"^([A-Z][A-Z0-9_]*)='([^']*)'\s*(#.*)?$", line)
    if named and named.group(2) != '':
        stated[named.group(1).lower()] = named.group(2)

declared, inside = [], False
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
        declared.append(entry.group(1))

answers = {name: stated[name] for name in declared
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
  ) || { bad "could not write the answers for $program"; return 1; }

  chmod 600 "$ANSWERS" || { bad "could not close $ANSWERS to this account alone"; return 1; }
  say "$program is told $counted"
  return 0
}

# =============================================================================
# The five programs. install-order.yaml's own sequence for a first master, in its
# own order, each of them test then dry then run — the three modes gate one
# another, and a mode that is not green stops the whole installation here rather
# than carrying a doubt into the next program.
# =============================================================================
readonly PROGRAMS=(deploy-host deploy-branch deploy-cluster deploy-platform-services onboard-manager)

run_program() {
  local program="$1" mode="$2" ordinal="$3"
  printf '%s   %-26s %-5s %s' "$C_BLD" "$program" "$mode" "$C_OFF"
  local began; began=$(date +%s)
  local log="/tmp/aw-$program-$mode.log"

  # THE PASSWORD ON STANDARD INPUT AND THE RUN'S OWN OUTPUT ON THIS ONE. Every
  # line the machine writes is echoed as it happens, indented under the program
  # it belongs to, so a session that scrolls still carries the whole of it.
  printf '%s\n' "$ELEVATION_PASSWORD" | ( cd "$CATALOG" && sudo -S -p '' "$ENGINE" "$program" \
      --programs "$CATALOG/ansiwise/programs" \
      --config "$CATALOG/ansiwise.yaml" \
      --answers "$ANSWERS" \
      --runs "$RUNS" \
      --role master --stage "$STAGE" --fqdn "$FQDN" \
      --mode "$mode" ) > "$log" 2>&1
  local status=$?
  local took=$(( $(date +%s) - began ))

  local last; last=$(tail -1 "$log")
  local id; id=$(printf '%s' "$last" | awk '{print $1}')
  case "$id" in *T*Z-*) RUN_IDS+=("$id") ;; *) id='' ;; esac

  if [ $status -eq 0 ]; then
    printf '%s✓ %s%s  %s(%ds)%s\n' "$C_GRN" "$(printf '%s' "$last" | sed 's/^[^ ]*  *//')" "$C_OFF" "$C_DIM" "$took" "$C_OFF"
  else
    printf '%s✗ exit %d%s  %s(%ds)%s\n' "$C_RED" "$status" "$C_OFF" "$C_DIM" "$took" "$C_OFF"
  fi

  # THE WHOLE OF WHAT THE MACHINE SAID, indented and kept. Not a tail: the line
  # that explains a failure is rarely the last one, and this exists so that
  # nothing has to be asked for twice.
  sed 's/^/       /' "$log"
  rm -f "$log"

  if [ $status -ne 0 ]; then
    bad "$program ($mode) ended with exit $status${id:+ — its record is $RUNS/$id}"
    return 1
  fi
  return 0
}

step=0
for program in "${PROGRAMS[@]}"; do
  step=$(( step + 1 ))
  phase "$step / 5   $program"
  compose_answers "$program" || {
    say ''
    say "the installation stops here, before $program was started."
    break
  }
  for mode in test dry run; do
    run_program "$program" "$mode" "$step" || {
      say ''
      say "the installation stops here. Nothing after $program was started, and what"
      say 'it already did stands. Read the lines above, then start this again — every'
      say 'program of this sequence is idempotent and a second run measures what the'
      say 'first one left.'
      summary
      exit 1
    }
  done
done

phase 'done'
good "$FQDN is installed: five programs, fifteen runs, every one green"
say "the machine's own records stand under $RUNS"
summary
