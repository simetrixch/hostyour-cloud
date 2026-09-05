#!/usr/bin/env bash
# =============================================================================
# regenerate-install-branch.sh — bring ONE installation onto the release its map
# is pinned to. PowerShell twin: regenerate-install-branch.ps1 (same folder),
# which does the same in the same order and prints the same lines.
# lifecycle/test.sh measures that.
# =============================================================================
#
# USAGE (run from anywhere inside a hostyour-cloud checkout)
#   bash lifecycle/regenerate-install-branch.sh <fqdn> [config]
#
# THE TWO INPUTS
#   fqdn    — WHICH INSTALLATION is regenerated. It is the domain of the cluster,
#             the name of its install branch, the name of its map under
#             clusters/active, and the name the session is opened to.
#   config  — the key=value file stating that installation, the same one
#             install-machine.sh is given and in the same grammar. It holds the
#             account this machine is reached as, the password that raises a
#             command there, and the answers deploy-branch is told with.
#             Defaults to config.env beside this file.
#
# THIS IS THE SECOND ACT, and release-platform.sh beside it is the first. That
# one writes `release: <tag>` into clusters/active/<fqdn>.yaml on the install
# branch and stops. That line alone moves every CHART the cluster reads: the
# reconciler's own tree fills __RELEASE__ from it, and every source that reads a
# chart of this repository targets that ref. What it does not move is the three
# trees the reconciler reads from the install branch itself -- clusters/argocd,
# clusters/bootstrap and clusters/platform. This performs the regeneration that
# carries those, and the two are separate acts on purpose: between them somebody
# can read what the pin now says, ask status.sh which of those trees this release
# touched, and stop where it touched none.
#
# THE REF IS READ OFF THE PIN AND NEVER ASKED FOR. `release:` in that map is
# where the first act recorded the state, so reading it is what makes the pin and
# the regeneration ONE statement rather than two that can disagree. An
# installation is brought to the state its own map records, or the run refuses.
#
# NOTHING IS TOUCHED BEFORE THE TARGET IS KNOWN GOOD. The branch, the map, the
# pin and the tag are asked of the REMOTE before a session is opened, so a
# mistyped domain or a pin naming a tag nobody pushed costs a fetch and no more.
# Every refusal below says that nothing has been changed, because at every one of
# them nothing has.
#
# WHAT ACTUALLY REGENERATES A BRANCH is deploy-branch.yaml in the catalogue
# repository, run by the engine on the machine. This opens ONE session, carries
# the config over it, and starts regenerate-driver.sh there — the same shape
# install-machine.sh uses to start driver.sh, and for the same
# reason: what runs on a machine is fetched by that machine, and what this
# carries over is the operator's own config and nothing else.
#
# WHAT IS PRINTED IS ASCII, and that is not a typographic preference. The two
# spellings are held to printing the same bytes, and PowerShell writes its output
# in whatever code page the console carries -- so a dash from outside ASCII
# arrives there as a different byte and the pair quietly stops agreeing. The
# comments in these files are read by people and may say what they like.
# =============================================================================

set -uo pipefail

# EVERY REFUSAL SAYS THAT NOTHING HAS BEEN CHANGED, and it is appended here
# rather than written out eighteen times: every one of them stands before the
# session is opened, so the sentence is true of all of them by construction and
# cannot be forgotten on the one that is added next.
die() { printf 'regenerate: %s. Nothing has been changed\n' "$1" >&2; exit "${2:-65}"; }
say() { printf '%s\n' "$1"; }

# THE VALUE OF ONE TOP-LEVEL KEY of the installation's map, read the way the
# catalogue's own step writes it: a line beginning at column one with the key and
# a colon. A key of the same name indented under `global:` is a different key and
# is deliberately not seen. Surrounding quotes are the notation's and are taken
# off, which is what the catalogue's reading step does too.
value_in_text() {
  local key="$1" line value
  while IFS= read -r line; do
    case "$line" in
      "$key":*)
        value="${line#"$key":}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        case "$value" in
          \"*\") value="${value#\"}"; value="${value%\"}" ;;
          \'*\') value="${value#\'}"; value="${value%\'}" ;;
        esac
        printf '%s\n' "$value"
        return 0
        ;;
    esac
  done
  return 1
}

FQDN=""
CONFIG=""
DISCARD=""
# --discard IS TAKEN FROM ANY POSITION, because it is the argument a person adds
# to a command they have already typed once and had refused.
for arg in "$@"; do
  case "$arg" in
    --discard) DISCARD=--discard ;;
    *) if [ -z "$FQDN" ]; then FQDN="$arg"; elif [ -z "$CONFIG" ]; then CONFIG="$arg"; else
         die "lifecycle/regenerate-install-branch.sh was given more than it takes: $arg" 64; fi ;;
  esac
done

[ -n "$FQDN" ] || die 'usage: lifecycle/regenerate-install-branch.sh <fqdn> [config] [--discard]' 64

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIVER="$HERE/regenerate-driver.sh"
[ -r "$DRIVER" ] \
  || die 'regenerate-driver.sh is not beside this file. It IS the regeneration on the machine, and this only starts it' 66

command -v git >/dev/null 2>&1 \
  || die 'git is not on this path, and everything read below is read out of git'
git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die 'not inside a git repository. Run this from a checkout of the platform tree' 66

# ---------------------------------------------------------- the target, asked
# ASKED OF THE REMOTE AND NOT OF THIS CHECKOUT, for the same reason the first act
# reads the remote: an install branch moves without this workstation — a release
# writes its pin onto it — so a local view of that branch answers about whenever it
# last looked.
git ls-remote --exit-code --heads origin "refs/heads/$FQDN" >/dev/null 2>&1 \
  || die "origin has no branch $FQDN. An installation is regenerated on its own install branch, and there is none of that name" 66
git fetch --quiet origin "refs/heads/$FQDN" \
  || die "the branch $FQDN could not be fetched from origin, so its pin cannot be read" 69

MAP="clusters/active/${FQDN}.yaml"
MAPTEXT="$(git show "FETCH_HEAD:$MAP" 2>/dev/null)" \
  || die "branch $FQDN carries no $MAP. That map is where an installation records what it is, and the pin is one line in it" 66

PIN="$(printf '%s\n' "$MAPTEXT" | value_in_text release)"
[ -n "$PIN" ] \
  || die "$MAP on branch $FQDN carries no release line, so nothing records which state this installation is to stand on. release-platform.sh / release-platform.ps1 beside this file writes that line" 65

# THE TAG IS ASKED OF THE REMOTE, because the remote is what the machine fetches
# from. A pin naming a tag this workstation happens to carry and origin does not
# would send the machine after a ref it can never resolve, and the run would fail
# three systems away in a message about a git ref rather than about a release.
[ -n "$(git ls-remote --tags origin "refs/tags/$PIN")" ] \
  || die "origin carries no $PIN, and that is what $MAP pins $FQDN to. The machine fetches from origin, so a state only this workstation knows is a state it cannot reach" 69

say "regenerate: $FQDN is pinned to $PIN in $MAP, and that is the state this brings it to"

# ------------------------------------------------------- the config, and its guards
# THE SAME FILE install-machine.sh IS GIVEN, in the same grammar and under the
# same guards. It carries the account this machine is reached as, the password
# that raises a command there, and every answer deploy-branch declares except
# the ref, which is the pin above.
[ -n "$CONFIG" ] || CONFIG="$HERE/config.env"
[ -r "$CONFIG" ] \
  || die "there is no config at $CONFIG. It states the installation this regenerates: copy config.example.env beside it, fill it in, and name it as the second argument" 66

# OWNER-ONLY OR NOTHING. `stat` spells its arguments differently on Linux and on
# macOS, and both are asked rather than one being assumed.
MODE=$(stat -c '%a' "$CONFIG" 2>/dev/null || stat -f '%Lp' "$CONFIG" 2>/dev/null)
case "$MODE" in
  600|400) ;;
  *) die "$CONFIG is mode ${MODE:-unknown} and carries credentials, the elevation password of the machine among them. Run: chmod 600 $CONFIG" 77 ;;
esac

# INSIDE A GIT TREE AND NOT IGNORED BY IT is refused: the mistake is made once and
# cannot be taken back, because a token that reached a remote must be rotated.
# IGNORED IS ENOUGH — what this stops is `git add .` sweeping the file up, and a
# file the tree ignores takes a deliberate `git add -f`, which is somebody choosing.
CONFIG_DIR="$(cd "$(dirname "$CONFIG")" && pwd)"
if git -C "$CONFIG_DIR" rev-parse --show-toplevel >/dev/null 2>&1; then
  git -C "$CONFIG_DIR" check-ignore -q "$CONFIG" 2>/dev/null \
    || die "$CONFIG stands inside a git working tree that does not ignore it. A file of credentials belongs nowhere a commit can reach it: move it out, or name it in that tree's .gitignore" 77
fi

# NOTHING BUT ASSIGNMENTS AND COMMENTS, checked BEFORE this file is read, because
# reading it is running it. A shell `.` executes every line, so a config carrying
# a command would run it with the operator's own rights, and the same file is
# read again by a shell on the machine.
BAD=$(grep -nvE "^[[:space:]]*(#.*)?$|^[A-Z][A-Z0-9_]*='[^']*'[[:space:]]*(#.*)?$" "$CONFIG" | head -3)
[ -z "$BAD" ] \
  || die "$CONFIG carries lines that are neither a comment nor NAME='value', and this file is READ BY THE SHELL on both sides: $BAD" 65

# THE NAME THIS RUN WAS GIVEN, KEPT BEFORE THE CONFIG IS READ. The config states
# an FQDN of its own and reading it is what puts it in this shell, so without this
# the two could not be told apart afterwards and a config stating none at all
# would look as though it stated this one.
ASKED="$FQDN"
unset -v FQDN

# shellcheck disable=SC1090
. "$CONFIG"

for named in FQDN OPERATOR_USER STAGE; do
  [ -n "${!named:-}" ] || die "$CONFIG states no $named, and nothing here may choose one" 65
done
[ -n "${ELEVATION_PASSWORD:-}" ] \
  || die "$CONFIG states no ELEVATION_PASSWORD, and a regeneration is run elevated" 65

# ONE CONFIG STATES ONE INSTALLATION. The answers in it land in this cluster's own
# map and in its own credential files, so a config naming another installation
# would regenerate this branch out of another one's answers — every stamp writing
# a domain, a name and a stage that belong to a different machine.
[ "$FQDN" = "$ASKED" ] \
  || die "$CONFIG states FQDN $FQDN and this run names $ASKED. One config states one installation, and its answers are what the branch is regenerated from" 65

# ------------------------------------------------------------- the machine
# A MACHINE IS ADDRESSED BY ITS NAME, and by nothing else — the name in the map,
# which is the name of the branch and the name on the certificate.
PORT=22
TARGET="$OPERATOR_USER@$FQDN"
BASE=(-p "$PORT" -o ConnectTimeout=20 -o StrictHostKeyChecking=accept-new)

# WHICH DOOR THIS MACHINE OPENS, asked before anything is sent. An installation
# that stands carries the operator key — deploy-host's install_authorized_key row
# put it there and disable-password-login shut the password door — so the key is
# the case here, and the password is the exception a machine still at its birth
# would need. The key is tried first and the password only where the key is
# refused, so neither case needs a flag.
PROBE=$(ssh "${BASE[@]}" -o BatchMode=yes "$TARGET" true 2>&1)
if [ $? -eq 0 ]; then
  DOOR=(-o BatchMode=yes)
  say "regenerate: $TARGET opens to the operator key"
else
  case "$PROBE" in
    *'REMOTE HOST IDENTIFICATION HAS CHANGED'*|*'Host key verification failed'*)
      # NOT ACCEPTED SILENTLY, and accept-new deliberately does not cover it: a
      # machine whose host key changed is either one that was rebuilt or one that
      # is not the machine any more, and only the operator knows which.
      die "$FQDN answers with a host key this machine does not recognise. A restore gives a machine a NEW host key: if you have just restored it, forget the old one with ssh-keygen -R $FQDN and start again. If you have not, clear nothing: something else is answering for $FQDN" 74 ;;
    *'Permission denied'*)
      [ -t 0 ] \
        || die "$TARGET refuses the operator key, so this could only be a password session, and there is no terminal here to ask on. Start it from a terminal" 69
      DOOR=(-o BatchMode=no -o NumberOfPasswordPrompts=1)
      say "regenerate: $TARGET refuses the operator key, so ssh asks for the login password ONCE, on this terminal. It is not read from the config and it is not kept" ;;
    *)
      die "$TARGET could not be reached: $(printf '%s' "$PROBE" | tr '\n' ' ')" 69 ;;
  esac
fi

# ONE SESSION, so that a password is typed at most once. The stream is the config
# inside a quoted heredoc with the driver behind it: the config lands on the
# machine under a mask that admits nobody else, and the driver shreds it on every
# path it can end on. Neither is ever an argument, because an argument stands in a
# process listing. The heredoc marker cannot collide with anything in the config,
# because the guard above admits no line but a comment and NAME='value'.
#
# THE PIN IS APPENDED AS THE LAST LINE, in the config's own grammar, so the
# driver composes it into the answers exactly as it composes every other value and
# holds no special case for it. Last, because the composer reads the file top to
# bottom and a later line wins: a config that states a PLATFORM_REF of its own is
# a stale ref, and the pin on the branch is the one this act is about.
#
# A CARRIAGE RETURN IS TAKEN OFF. This repository stores LF, but the config is
# written by an operator in whatever editor they have and Notepad writes CRLF,
# and the far side is a bash that reads a CR as part of the value.
{
  printf 'umask 077\ncat > "$1" <<%sAW_CONFIG_END%s\n' "'" "'"
  tr -d $'\r' < "$CONFIG"
  printf "PLATFORM_REF='%s'\n" "$PIN"
  printf 'AW_CONFIG_END\n'
  tr -d $'\r' < "$DRIVER"
} | ssh "${BASE[@]}" "${DOOR[@]}" "$TARGET" "bash -s -- \"\$HOME/.aw-regenerate.env\" $DISCARD"
REGENERATED=${PIPESTATUS[1]}

if [ "$REGENERATED" -eq 0 ]; then
  say "regenerate: $FQDN stands on $PIN"
else
  say "regenerate: the regeneration of $FQDN ended with exit $REGENERATED. The line above it says which mode stopped and why"
fi
exit "$REGENERATED"
