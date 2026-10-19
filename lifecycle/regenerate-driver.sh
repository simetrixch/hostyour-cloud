#!/usr/bin/env bash
# =============================================================================
# regenerate-driver.sh — the regeneration of ONE install branch, ON THE MACHINE
# ITSELF. regenerate-install-branch.sh streams this file over the session it
# opens, exactly as install-machine.sh streams driver.sh.
# =============================================================================
#
# WHAT THIS IS. A driver. It runs no step and changes nothing a program would not
# change: it composes the answers each program is told with and invokes it, once
# per mode. The regeneration itself is deploy-branch.yaml in the programs checkout
# standing on this machine, and every decision about what a branch becomes is a
# row of that file. That one program carries both acts: it cuts the branch where
# the remote publishes none and stands the checkout on the one it does, so what
# tells a birth from a regeneration is the remote and not the name of the
# program.
#
# AND tailnet-record-address AFTER IT, which the installation runs last as well.
# It records the address this master holds on its private network as
# `global.apiHost` in its own map, the fact the fence of a mail sender's SMTP
# entry admits (hostyour-cloud#242). Every regeneration keeps it true. The join
# itself is not run again: the machine is on its network already, and a join key
# minted for it would stand unused until it expires.
#
# WHY THE ANSWERS ARE COMPOSED ON THIS MACHINE AND NOT ON THE WORKSTATION. The
# names are read off each program's file in the programs checkout standing here, so
# nothing on the workstation holds a list of answers that could fall behind what
# a program declares. The programs checkout is on this machine and not on that one.
#
# WHAT IT IS TOLD, and it is the only thing that reaches it from outside: the
# same key=value config file the operator filled in for the installation, carried
# over the session as it stands, with one line added by the launcher —
# PLATFORM_REF, read off the `release:` line of this cluster's own map. The
# launcher reads the pin so that nobody states the ref a second time.
#
# THE ENGINE IS PLACED BEFORE THE PROGRAMS CHECKOUT IS READ, the same act the installation
# performs (driver.sh, phase 1). The programs checkout's trunk names the steps of the
# engine the platform repository pins, and a machine holds the engine its last run
# left: a regeneration that ran the new programs checkout on the old engine was refused
# before its first step, every program held against a registry lacking the steps
# the trunk had gained (hostyour-cloud#216, measured on apps3 after the 0.8.182
# engine release). The Manager places the engine before every program it drives;
# this is the one path that did not.
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

# EMPTY UNTIL THIS SCRIPT SETS THEM, so a name the environment happens to carry is never removed.
ANSWERS_DIR=''
FETCHED=''
# SHREDDED ON EVERY PATH. A credential that outlives the act it was handed over
# for is a credential nobody is watching, and most of what deploy-branch is
# told is credentials.
cleanup() {
  rm -f "$CONFIG" 2>/dev/null || true
  rm -rf "${ANSWERS_DIR:-}" 2>/dev/null || true
  rm -rf "${FETCHED:-}" 2>/dev/null || true
}
# A SIGNAL ENDS THE RUN, and EXIT then cleans up. A handler that only cleaned up would let bash
# resume the script after it, into a step whose files the handler has just taken away: the engine
# was left half placed that way, ansiwise at the pin and ansiwise-rest not.
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# NOTHING BUT ASSIGNMENTS AND COMMENTS, checked BEFORE this file is read, because
# reading it is running it: a shell `.` executes every line, so a config carrying
# a command would run it as this account. The launcher checks the same thing on
# the operator's side; it is checked again HERE because what arrives is what
# matters and a session is not a promise.
# The same function as require-config-assignments.sh, held byte-equal to it by test.sh: this
# script arrives over one ssh session and can read no sibling. A refused line is named by its
# number and never quoted, because it may carry a credential.
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
require_config_assignments "$CONFIG" \
  || die "the config carries lines that are neither a comment nor NAME='value', and this file is READ BY THE SHELL: $BAD_LINES. They are named and never quoted, because a line may carry a credential" 65

# AND NO CARRIAGE RETURN. The shape check above lets one through — a CR falls
# after the closing quote, where [[:space:]] matches it — and a bash on Linux
# then reads it as part of the value, so a ref ending in a control character
# would be fetched and the first thing to say so would be a merge naming a
# commit nobody wrote. COUNTED WITH tr, which reads bytes and nothing else, so
# no tool's reading of a line ending stands between the file and the check.
[ "$(tr -dc '\r' < "$CONFIG" | wc -c)" -eq 0 ] \
  || die 'the config carries carriage returns, so every value would end in one. Write it with Unix line endings' 65

# shellcheck disable=SC1090
. "$CONFIG"

readonly STAGE="${STAGE:-}"
readonly FQDN="${FQDN:-}"
readonly OPERATOR="${OPERATOR_USER:-}"
readonly PLATFORM_REF="${PLATFORM_REF:-}"
readonly PROGRAMS_REPO="${PROGRAMS_REPO:-}"

for named in STAGE FQDN OPERATOR PLATFORM_REF PROGRAMS_REPO; do
  [ -n "${!named}" ] || die "the config says nothing under ${named}, and nothing here may choose one" 64
done
[ -n "${ELEVATION_PASSWORD:-}" ] \
  || die 'the config states no ELEVATION_PASSWORD, and a regeneration is run elevated' 64
readonly PLATFORM_REPO="${PLATFORM_REPO:-}"
[ -n "$PLATFORM_REPO" ] \
  || die 'the config says nothing under PLATFORM_REPO, and the engine pin is read off that repository' 64

# Every elevated command goes through here, and the password reaches it on
# STANDARD INPUT - never an argument list, which stands in this machine's own
# process listing for anyone on it to read.
root() { printf '%s\n' "$ELEVATION_PASSWORD" | sudo -S -p '' "$@"; }

# THE FETCHED ENGINE IS HELD AGAINST THE DIGESTS THE PLATFORM REPOSITORY STATES FOR THE PIN,
# before either executable is placed. The pin says which release is fetched and not which bytes
# arrive, and an asset replaced after the release answers --version with whatever it was built to
# answer. The release writes the digests in the same commit as the pin, off what GitHub recorded
# when the build uploaded the assets.
#
# A LINE FOR EACH EXECUTABLE, NAMED BY ITS ASSET, is asked for before anything is hashed, so a
# digest file that names another release says so, rather than sha256sum reporting a file it
# cannot find.
hold_engine_against_digests() { # <directory the assets were fetched into> <the digest file's text> <pin>
  local dir="$1" digests="$2" pin="$3" tool asset line wanted=''
  for tool in ansiwise ansiwise-rest; do
    asset="$tool-$pin-linux-x64"
    line=$(printf '%s\n' "$digests" | awk -v asset="$asset" '$2 == asset')
    case "$line" in
      '') echo "the digests name no $asset" >&2; return 1 ;;
      *$'\n'*) echo "the digests name $asset more than once" >&2; return 1 ;;
    esac
    printf '%s\n' "$line" | awk '{ exit !(length($1) == 64 && $1 ~ /^[0-9a-f]+$/) }' \
      || { echo "the digests name $asset with no SHA-256 of 64 lowercase hex digits" >&2; return 1; }
    wanted+="$line"$'\n'
  done
  ( cd "$dir" && printf '%s' "$wanted" | sha256sum --check --strict --quiet - )
}

readonly PROGRAMS_CHECKOUT=/srv/ansiwise-programs
readonly ENGINE=/usr/local/bin/ansiwise
readonly RUNS=/var/lib/ansiwise/runs
readonly PROGRAMS=(deploy-branch tailnet-record-address)
ANSWERS_DIR="/home/$OPERATOR/.regenerate-answers"

# THE ROLE THE RUN IS STARTED UNDER IS master, AND IT IS NOT THIS MACHINE'S OWN
# ROLE. Both programs state `roles: [master]` — the cluster maps and the books
# stand on the master's branch, which is the branch this regenerates — so master
# is the only role they admit. What every part of this machine carries
# is the `role` ANSWER, which the launcher reads off the map on the branch and
# appends to the config (the map is the writable place, and the config's ROLE
# seeds a first installation only), and the stamps below write.
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
[ -d "$PROGRAMS_CHECKOUT" ] \
  || die "there is no programs checkout at $PROGRAMS_CHECKOUT, so the programs a regeneration runs are not on this machine. A machine is given them by lifecycle/install-machine.sh at its birth; nothing has been changed" 66
[ -x "$ENGINE" ] \
  || die "there is no engine at $ENGINE, and it is what runs a program. A machine is given it by lifecycle/install-machine.sh at its birth; nothing has been changed" 66

# THE ENGINE, AT THE VERSION THE PLATFORM REPOSITORY PINS. Read off the public
# platform repository by this machine, fetched from the owner's registry at the
# address of each binary's SHA-256 (driver.sh says why), placed
# elevated and read back off the machine - the shape driver.sh gives it, so a
# regeneration and an installation put the same engine in front of the same
# programs checkout. Nothing is fetched where the machine already answers the pin.
readonly RELEASES=https://zot.master.digitacloud.app/v2/simetrixch/ansiwise-cli/blobs
readonly PIN_URL="https://raw.githubusercontent.com/$PLATFORM_REPO/master/clusters/platform/versions.yaml"
readonly DIGESTS_URL="https://raw.githubusercontent.com/$PLATFORM_REPO/master/clusters/platform/ansiwise.sha256"
say "reading the engine pin from $PIN_URL"
PIN_YAML=$(curl -fsSL "$PIN_URL") || die "$PIN_URL could not be read from this machine; nothing has been changed" 69
# SINGLE-QUOTED FOR THE SHELL, so every dollar and every quote below belongs to
# python and not to bash. The regexes therefore use double quotes throughout and
# never a single one.
PIN=$(printf '%s' "$PIN_YAML" | python3 -c 'import sys, re
text = sys.stdin.read()
block = re.search(r"^cliTools:\s*$.*?(?=^\S|\Z)", text, re.S | re.M)
found = re.search(r"^  ansiwise:\s*$\s*^\s+version:\s*\"([^\"]+)\"", block.group(0) if block else "", re.M)
sys.stdout.write(found.group(1) if found else "")')
[ -n "$PIN" ] || die "$PIN_URL says nothing under cliTools.ansiwise.version; nothing has been changed" 65
# BOTH EXECUTABLES ARE ASKED, so a machine left with one at the pin and the other not is placed
# again rather than passed over until the pin moves.
ENGINE_ANSWERS=$("$ENGINE" --version 2>/dev/null || true)
SERVING_ANSWERS=$(/usr/local/bin/ansiwise-rest --version 2>/dev/null || true)
if [ "$ENGINE_ANSWERS" = "$PIN" ] && [ "$SERVING_ANSWERS" = "$PIN" ]; then
  good "$ENGINE and /usr/local/bin/ansiwise-rest already answer $PIN - nothing fetched"
else
  say "$ENGINE answers ${ENGINE_ANSWERS:-nothing}, /usr/local/bin/ansiwise-rest answers ${SERVING_ANSWERS:-nothing}, and the pin is $PIN"
  say "reading the digests from $DIGESTS_URL"
  DIGESTS=$(curl -fsSL "$DIGESTS_URL") || die "$DIGESTS_URL could not be read from this machine; nothing has been changed" 69
  # EVERY ADDRESS BEFORE ANY DOWNLOAD. A blob is addressed by the digest its line states, so an
  # asset with no line, or with two, has no address at all and is refused before anything is fetched.
  for tool in ansiwise ansiwise-rest; do
    hex=$(printf '%s\n' "$DIGESTS" | awk -v asset="$tool-$PIN-linux-x64" '$2 == asset { print $1 }')
    [[ "$hex" =~ ^[0-9a-f]{64}$ ]] \
      || die "$DIGESTS_URL states no single SHA-256 for $tool-$PIN-linux-x64, and the registry serves a binary only at the address of its digest; nothing has been changed" 65
    printf -v "URL_${tool//-/_}" '%s' "$RELEASES/sha256:$hex"
  done
  # A DIRECTORY OF ITS OWN, readable by this account alone, and not a fixed name under /tmp: the
  # bytes that are hashed are the bytes that are placed, and nobody else can write between the two.
  FETCHED=$(mktemp -d) || die "no directory could be made to fetch the engine into; nothing has been changed" 73
  for tool in ansiwise ansiwise-rest; do
    url_name="URL_${tool//-/_}"; url="${!url_name}"
    say "fetching $tool from $url"
    curl -fsSL -o "$FETCHED/$tool-$PIN-linux-x64" "$url" || die "$url served nothing - the registry holds no blob of that digest; nothing has been changed" 69
    [ -s "$FETCHED/$tool-$PIN-linux-x64" ] || die "$url served an empty file, and an empty executable answers every command with a shell error; nothing has been changed" 69
  done
  if ! hold_engine_against_digests "$FETCHED" "$DIGESTS" "$PIN"; then
    die "the engine fetched for $PIN does not hold what $DIGESTS_URL states for it; nothing has been changed. The line above names the asset and why. Where it says the digests name no asset of $PIN, versions.yaml and ansiwise.sha256 were read at different moments: run again" 65
  fi
  good "ansiwise and ansiwise-rest hold the digests the platform repository states for $PIN"
  for tool in ansiwise ansiwise-rest; do
    root install -m 755 "$FETCHED/$tool-$PIN-linux-x64" "/usr/local/bin/$tool" || die "could not place $tool in /usr/local/bin" 73
  done
  rm -rf "$FETCHED"
  # READ BACK OFF THE MACHINE, never off this script's own claim: a truncated
  # transfer, an asset that is an error page and an architecture this machine
  # cannot execute are all one answer here - not the pin.
  for tool in ansiwise ansiwise-rest; do
    answered=$("/usr/local/bin/$tool" --version 2>/dev/null || true)
    [ "$answered" = "$PIN" ] || die "/usr/local/bin/$tool answers ${answered:-nothing} after being placed, not $PIN" 69
  done
  good "/usr/local/bin/ansiwise and /usr/local/bin/ansiwise-rest answer $PIN"
fi
# THE PROGRAMS CHECKOUT IS BROUGHT FORWARD BEFORE A PROGRAM IS READ OUT OF IT. A program's
# rows and the answers it declares move with the programs checkout's trunk, and a machine
# holds the copy its last run left: a regeneration that read that copy would run a
# program of unknown age and leave out every answer the config states under a name
# the old copy does not declare — measured on apps1 (hostyour-cloud#193), where the
# map lost its mail line because the machine's copy still declared the old name.
# The same act the installation performs (lifecycle/driver.sh), as this account:
# the tree belongs to the operator so that a fetch needs no elevation, and the
# repository is public so that it needs no credential. RESET AND NOT MERGE, because
# nothing on a machine may write this tree. A programs checkout that cannot be fetched stops
# the regeneration by name rather than running a program of unknown age.
say "bringing $PROGRAMS_CHECKOUT onto the published head of its branch"
want="https://github.com/$PROGRAMS_REPO.git"
have=$(git -C "$PROGRAMS_CHECKOUT" remote get-url origin 2>/dev/null || true)
if [ "$have" != "$want" ]; then
  git -C "$PROGRAMS_CHECKOUT" remote set-url origin "$want"     || die "could not point $PROGRAMS_CHECKOUT at $PROGRAMS_REPO; nothing has been changed" 69
  say "$PROGRAMS_CHECKOUT followed $have and now follows $PROGRAMS_REPO"
fi
branch=$(git -C "$PROGRAMS_CHECKOUT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
[ -n "$branch" ] && [ "$branch" != HEAD ] || branch=master
GIT_TERMINAL_PROMPT=0 git -C "$PROGRAMS_CHECKOUT" fetch --quiet origin "$branch"   || die "could not fetch $PROGRAMS_REPO into $PROGRAMS_CHECKOUT, and a program of unknown age is not run; nothing has been changed" 69
git -C "$PROGRAMS_CHECKOUT" reset --quiet --hard FETCH_HEAD   || die "could not bring $PROGRAMS_CHECKOUT onto the published head of $branch; nothing has been changed" 69
good "$PROGRAMS_CHECKOUT stands at $(git -C "$PROGRAMS_CHECKOUT" rev-parse --short HEAD 2>/dev/null || echo 'an unreadable commit') on $branch"

for program in "${PROGRAMS[@]}"; do
  [ -r "$PROGRAMS_CHECKOUT/ansiwise/programs/$program.yaml" ] \
    || die "$PROGRAMS_CHECKOUT/ansiwise/programs/$program.yaml cannot be read, and it is what states the answers $program takes; nothing has been changed" 66
done
command -v python3 >/dev/null 2>&1 \
  || die 'python3 is not on this path, and the answers envelope is composed with it; nothing has been changed' 66

say "$FQDN, stage $STAGE, regenerated onto $PLATFORM_REF"

# =============================================================================
# THE ANSWERS, composed out of the config and the program's own declaration.
#
# THE NAMES ARE READ OFF THE PROGRAM ITSELF, out of the programs checkout standing on
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
# for the six programs that make a master. The two are two statements of one
# grammar, and nothing holds them against each other.
# =============================================================================
mkdir -p "$ANSWERS_DIR" && chmod 700 "$ANSWERS_DIR" \
  || die "could not make $ANSWERS_DIR, and the answers are written there" 73

for PROGRAM in "${PROGRAMS[@]}"; do
ANSWERS="$ANSWERS_DIR/$PROGRAM.json"
COUNTED=$(python3 - "$CONFIG" "$PROGRAMS_CHECKOUT/ansiwise/programs/$PROGRAM.yaml" "$ANSWERS" <<'COMPOSE'
import json, re, sys

BESIDE = 'elevation_password'
config_path, declares_path, into = sys.argv[1], sys.argv[2], sys.argv[3]

stated = {}
for line in open(config_path, encoding='utf-8'):
    named = re.match(r"^([A-Z][A-Z0-9_]*)='([^']*)'\s*(#.*)?$", line)
    if named and named.group(2) != '':
        stated[named.group(1).lower()] = named.group(2)

# THE OWNER'S ACME BLOCK. ACME_SERVER and ACME_EMAIL alone answer letsencrypt_server and
# letsencrypt_email; the LETSENCRYPT lines older configs carry are read by nothing, because GTS is the
# one directory and a slave is regenerated from the master's map by the Manager.
# ACME_CREDENTIALS_JSON, the External Account Binding Google Trust Services issued as one line of
# JSON, gives acme_eab_key_id its keyId and acme_eab_mac_key its b64MacKey. A binding that cannot be read is refused by the key's name, and
# never with its value: the MAC key is a credential.
stated.pop('letsencrypt_server', None)
stated.pop('letsencrypt_email', None)
if 'acme_server' in stated:
    stated['letsencrypt_server'] = stated['acme_server']
if 'acme_email' in stated:
    stated['letsencrypt_email'] = stated['acme_email']
if 'acme_credentials_json' in stated:
    try:
        binding = json.loads(stated['acme_credentials_json'])
    except ValueError:
        binding = None
    if not isinstance(binding, dict) or not all(
            isinstance(binding.get(field), str) and binding[field] for field in ('keyId', 'b64MacKey')):
        sys.exit('ACME_CREDENTIALS_JSON in the config is not one line of JSON carrying keyId and '
                 'b64MacKey, the External Account Binding Google Trust Services issued; its value is not shown')
    stated['acme_eab_key_id'] = binding['keyId']
    stated['acme_eab_mac_key'] = binding['b64MacKey']

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
done

# THE REF IT WAS TOLD, SAID OUT LOUD. It is the one answer that did not come from
# the operator's config, and it is what this whole act is about.
say "platform_ref is $PLATFORM_REF, read off the pin in clusters/active/$FQDN.yaml"

# =============================================================================
# THE THREE MODES, which gate one another: a test that measures, a dry run that
# cannot mutate, and a real run the engine refuses without a green dry run for
# the same input. A mode that is not green stops this here rather than carrying a
# doubt into the next one.
# =============================================================================
for PROGRAM in "${PROGRAMS[@]}"; do
ANSWERS="$ANSWERS_DIR/$PROGRAM.json"
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
  printf '%s\n' "$ELEVATION_PASSWORD" | ( cd "$PROGRAMS_CHECKOUT" && sudo -S -p '' -u "$OPERATOR" "$ENGINE" "$PROGRAM" \
      --programs "$PROGRAMS_CHECKOUT/ansiwise/programs" \
      --config "$PROGRAMS_CHECKOUT/ansiwise.yaml" \
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
done

printf '\n'
good "$FQDN stands on $PLATFORM_REF: its branch is merged, stamped, committed and pushed, and its map states its tailnet address"
say "the machine's own records stand under $RUNS"

# THIS FILE IS READ FROM STANDARD INPUT, so whatever the sender writes after it on
# that stream would be read as more of it. An explicit exit ends the script where
# the script ends, and bash reads no further.
exit 0
