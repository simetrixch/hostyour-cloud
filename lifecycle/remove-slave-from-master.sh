#!/usr/bin/env bash
# =============================================================================
# remove-slave-from-master.sh — take ONE slave's registration off the master it
# stands on. PowerShell twin: remove-slave-from-master.ps1 (same folder), which
# does the same in the same order and prints the same lines. lifecycle/test.sh
# measures that.
# =============================================================================
#
# USAGE (run from anywhere inside a hostyour-cloud checkout)
#   bash lifecycle/remove-slave-from-master.sh <slave-fqdn> [config] [--even-if-running]
#
# THE TWO INPUTS
#   slave-fqdn — WHICH SLAVE is taken off. It is the domain of the slave's
#             cluster, the name of its install branch, and the name of the map
#             the master keeps for it under clusters/active.
#   config  — the MASTER's key=value file, the same one install-machine.sh is
#             given for the master and in the same grammar. It states the master
#             this runs on, the account that machine is reached as, the password
#             that raises a command there, and the stage every path the removal
#             writes is spelled along. Defaults to config.env beside this file.
#
# THE CONFIG IS THE MASTER'S AND NOT THE SLAVE'S, because a registration stands
# on the master: the auth mount, the three policies, the entries in the slaves
# tier, the reconciler project and the membership at the coordinator are all
# objects of the master's own installation. The slave contributes one fact — its
# domain — and that is the argument.
#
# THIS IS THE INVERSE OF register-slave AND ONLY OF ITS HALF. What goes is the
# master-side management plane of one slave. What stays is the git side: the map
# clusters/active/<slave-fqdn>.yaml on the master's own branch and the slave's
# install branch. Dropping those is what tears the per-slave reconciler instance
# down, it is a separate act with a separate blast radius, and the last line this
# prints says so.
#
# WHAT THE REGISTRATION LEAVES BEHIND when nothing takes it off: a slave keeps
# its auth mount, its policies, its KV entries, its reconciler project, its
# membership at the coordinator and its map for as long as the master stands, and
# a fresh registration of the same name then meets objects it means to create.
#
# NOTHING IS TOUCHED BEFORE THE TARGET IS KNOWN GOOD. The master's branch, the
# map it keeps for this slave, what that map says the slave is, and whether the
# slave still answers are all asked before a session is opened. Every refusal
# below says that nothing has been changed, because at every one of them nothing
# has.
#
# A SLAVE THAT STILL ANSWERS IS REFUSED unless the run is told otherwise.
# Cleaning up after a machine that is gone and cutting a running cluster off its
# master are two different acts: the second leaves every workload on the slave
# alive and unable to read a secret, its reconciler without a project and its
# node without a tailnet, and a person should say that they mean it rather than
# learn it afterwards.
#
# THE CONFIG IS READ BEFORE ITS TWO EXPOSURE GUARDS ARE ASKED, and the order is
# deliberate. The shape check stands first, because reading this file is running
# it. The two guards under it are about who else can reach the credentials in it
# and whether a commit could sweep them up — neither is a reason to read a branch
# or to ask a slave whether it is alive — so they stand immediately before the
# file leaves this workstation, which is the thing they are about.
#
# WHAT ACTUALLY REMOVES A REGISTRATION is remove-slave.yaml in the catalogue
# repository, run by the engine on the master. This opens ONE session, carries
# the config over it, and starts remove-slave-driver.sh there — the same shape
# install-machine.sh uses to start driver.sh, and for the same reason: what runs
# on a machine is fetched by that machine, and what this carries over is the
# operator's own config and nothing else.
#
# WHAT IS PRINTED IS ASCII, and that is not a typographic preference. The two
# spellings are held to printing the same bytes, and PowerShell writes its output
# in whatever code page the console carries -- so a dash from outside ASCII
# arrives there as a different byte and the pair quietly stops agreeing. The
# comments in these files are read by people and may say what they like.
# =============================================================================

set -uo pipefail

# EVERY REFUSAL SAYS THAT NOTHING HAS BEEN CHANGED, and it is appended here
# rather than written out a dozen times: every one of them stands before the
# session is opened, so the sentence is true of all of them by construction and
# cannot be forgotten on the one that is added next.
die() { printf 'remove-slave: %s. Nothing has been changed\n' "$1" >&2; exit "${2:-65}"; }
say() { printf '%s\n' "$1"; }

# THE VALUE OF ONE TOP-LEVEL KEY of a cluster map, read the way the catalogue's
# own step writes it: a line beginning at column one with the key and a colon. A
# key of the same name indented under `global:` is a different key and is
# deliberately not seen. Surrounding quotes are the notation's and are taken off,
# which is what the catalogue's reading step does too.
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

SLAVE=""
CONFIG=""
RUNNING=""
# --even-if-running IS TAKEN FROM ANY POSITION, because it is the argument a
# person adds to a command they have already typed once and had refused.
for arg in "$@"; do
  case "$arg" in
    --even-if-running) RUNNING=yes ;;
    *) if [ -z "$SLAVE" ]; then SLAVE="$arg"; elif [ -z "$CONFIG" ]; then CONFIG="$arg"; else
         die "lifecycle/remove-slave-from-master.sh was given more than it takes: $arg" 64; fi ;;
  esac
done

[ -n "$SLAVE" ] \
  || die 'usage: lifecycle/remove-slave-from-master.sh <slave-fqdn> [config] [--even-if-running]' 64

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIVER="$HERE/remove-slave-driver.sh"
[ -r "$DRIVER" ] \
  || die 'remove-slave-driver.sh is not beside this file. It IS the removal on the machine, and this only starts it' 66

command -v git >/dev/null 2>&1 \
  || die 'git is not on this path, and the master keeps its books in git'
git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die 'not inside a git repository. Run this from a checkout of the platform tree' 66

# ------------------------------------------- the config, for the two facts in it
# THE SAME FILE install-machine.sh IS GIVEN FOR THE MASTER, in the same grammar.
# It carries the account the master is reached as, the password that raises a
# command there, and the two facts that name this act: the master's own domain,
# which is the branch its books stand on, and the stage every path the removal
# writes is spelled along.
[ -n "$CONFIG" ] || CONFIG="$HERE/config.env"
[ -r "$CONFIG" ] \
  || die "there is no config at $CONFIG. It states the MASTER this removal runs on: copy config.example.env beside it, fill it in, and name it as the second argument" 66

# NOTHING BUT ASSIGNMENTS AND COMMENTS, checked BEFORE this file is read, because
# reading it is running it. A shell `.` executes every line, so a config carrying
# a command would run it with the operator's own rights, and the same file is
# read again by a shell on the machine.
BAD=$(grep -nvE "^[[:space:]]*(#.*)?$|^[A-Z][A-Z0-9_]*='[^']*'[[:space:]]*(#.*)?$" "$CONFIG" | head -3)
[ -z "$BAD" ] \
  || die "$CONFIG carries lines that are neither a comment nor NAME='value', and this file is READ BY THE SHELL on both sides: $BAD" 65

# THE TWO FACTS THIS RUN WAS GIVEN, PUT OUT OF THE CONFIG'S REACH. Reading the
# config is running it, so an assignment in that file lands in this shell under
# whatever name it states — and the two that decide WHICH slave goes and whether
# a running one may go are the last that should be reachable from a file.
# Positional parameters are not assignable from a sourced file, and the shape
# check above admits no line that could call set.
set -- "$SLAVE" "$RUNNING"
# shellcheck disable=SC1090
. "$CONFIG"
SLAVE="$1"
RUNNING="$2"

for named in FQDN OPERATOR_USER STAGE; do
  [ -n "${!named:-}" ] || die "$CONFIG states no $named, and nothing here may choose one" 65
done
[ -n "${ELEVATION_PASSWORD:-}" ] \
  || die "$CONFIG states no ELEVATION_PASSWORD, and a removal is run elevated" 65

MASTER="$FQDN"

# ------------------------------------------------- the registration, asked of git
# ASKED OF THE REMOTE AND NOT OF THIS CHECKOUT, for the reason every act here
# reads the remote: an install branch moves without this workstation — a release
# writes its pin onto it, a migration writes its record onto it, a registration
# writes a map onto it — so a local view of that branch answers about whenever it
# last looked.
git ls-remote --exit-code --heads origin "refs/heads/$MASTER" >/dev/null 2>&1 \
  || die "origin has no branch $MASTER, and $CONFIG states that as the master. A master keeps its books on its own install branch, and there is none of that name" 66
git fetch --quiet origin "refs/heads/$MASTER" \
  || die "the branch $MASTER could not be fetched from origin, so what it records about $SLAVE cannot be read" 69

# THE MAP THE MASTER KEEPS FOR THIS SLAVE, which is the git side of the
# registration this takes off. It stands on the MASTER's branch, because that is
# the branch the books live on: the slaves generator reads it there, and a slave
# nobody registered on this master has no file there at all.
MAP="clusters/active/${SLAVE}.yaml"
MAPTEXT="$(git show "FETCH_HEAD:$MAP" 2>/dev/null)" \
  || die "branch $MASTER carries no $MAP. A slave is registered on the master that keeps its map, and $MASTER keeps none for $SLAVE" 66

# WHAT THAT MAP SAYS THE CLUSTER IS. A role is one or several parts joined by a
# plus, and what this removal is about is the slave part — so the parts are read
# rather than the whole word compared, and a machine carrying master and slave at
# once is a slave like any other.
ROLE="$(printf '%s\n' "$MAPTEXT" | value_in_text role)"
case "+$ROLE+" in
  *+slave+*) ;;
  *) die "$MAP on branch $MASTER states role '${ROLE:-none}', so what stands under that name is no slave. This takes a slave's registration off its master, and a map that does not name the slave part describes something else" 65 ;;
esac

# AND WHICH MASTER IT STANDS ON. `booksCluster` is the cluster that keeps the
# maps and the registrations, which for a slave is its master — it is the value
# the slave's own generator selector is stamped from, so a map naming another
# cluster is a slave of that one and not of this.
BOOKS="$(printf '%s\n' "$MAPTEXT" | value_in_text booksCluster)"
[ "$BOOKS" = "$MASTER" ] \
  || die "$MAP on branch $MASTER states booksCluster '${BOOKS:-none}', and $CONFIG states the master $MASTER. A slave is registered on the master that keeps its books, and this map names another one" 65

say "remove-slave: $MAP on branch $MASTER records $SLAVE as a slave of $MASTER, and its registration on that master is what this takes off"

# --------------------------------------------------- the slave itself, asked
# WHETHER THE SLAVE IS STILL THERE, asked before anything is decided about it.
# The question is only whether something answers on the ssh port: an account that
# is refused is a machine that is running, and so is a machine whose host key no
# longer matches. Which account is asked with does not matter and the master's
# own is used, because no credential of the slave's is anywhere near this act.
PORT=22
ANSWER=$(ssh -p "$PORT" -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
             -o BatchMode=yes "$OPERATOR_USER@$SLAVE" true 2>&1)
ANSWERED=$?
case "$ANSWER" in
  *'Permission denied'*|*'REMOTE HOST IDENTIFICATION HAS CHANGED'*|*'Host key verification failed'*)
    ANSWERED=0 ;;
esac

if [ "$ANSWERED" -eq 0 ]; then
  # BOTH SPELLINGS OF THE ARGUMENT ARE NAMED, because this file and its twin are
  # held to printing the same bytes and the person reading this refusal typed one
  # of the two.
  [ -n "$RUNNING" ] \
    || die "$SLAVE answers on port $PORT, so it is a RUNNING slave. Taking it off its master leaves every workload on it alive and unable to read a secret, its reconciler without a project and its node without a tailnet. If that is what you mean, start this again with --even-if-running, which the PowerShell spelling writes -EvenIfRunning" 69
  say "remove-slave: $SLAVE answers on port $PORT, and this run was told to take a running slave off its master anyway"
else
  say "remove-slave: $SLAVE does not answer on port $PORT, so what this takes off $MASTER is the registration of a machine that is gone"
fi

# ------------------------------------------------- the config, and its guards
# INSIDE A GIT TREE AND NOT IGNORED BY IT is refused first of the two, because it
# is the mistake that cannot be taken back: a token that reached a remote must be
# rotated, while a mode is corrected where it stands. IGNORED IS ENOUGH — what
# this stops is `git add .` sweeping the file up, and a file the tree ignores
# takes a deliberate `git add -f`, which is somebody choosing.
CONFIG_DIR="$(cd "$(dirname "$CONFIG")" && pwd)"
if git -C "$CONFIG_DIR" rev-parse --show-toplevel >/dev/null 2>&1; then
  git -C "$CONFIG_DIR" check-ignore -q "$CONFIG" 2>/dev/null \
    || die "$CONFIG stands inside a git working tree that does not ignore it. A file of credentials belongs nowhere a commit can reach it: move it out, or name it in that tree's .gitignore" 77
fi

# OWNER-ONLY OR NOTHING. `stat` spells its arguments differently on Linux and on
# macOS, and both are asked rather than one being assumed.
MODE=$(stat -c '%a' "$CONFIG" 2>/dev/null || stat -f '%Lp' "$CONFIG" 2>/dev/null)
case "$MODE" in
  600|400) ;;
  *) die "$CONFIG is mode ${MODE:-unknown} and carries credentials, the elevation password of the machine among them. Run: chmod 600 $CONFIG" 77 ;;
esac

# ------------------------------------------------------------- the machine
# A MACHINE IS ADDRESSED BY ITS NAME, and by nothing else — the name in the map,
# which is the name of the branch and the name on the certificate. The machine
# here is the MASTER: the store, the coordinator and the reconciler this removal
# reaches into are all its own.
TARGET="$OPERATOR_USER@$MASTER"
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
  say "remove-slave: $TARGET opens to the operator key"
else
  case "$PROBE" in
    *'REMOTE HOST IDENTIFICATION HAS CHANGED'*|*'Host key verification failed'*)
      # NOT ACCEPTED SILENTLY, and accept-new deliberately does not cover it: a
      # machine whose host key changed is either one that was rebuilt or one that
      # is not the machine any more, and only the operator knows which.
      die "$MASTER answers with a host key this machine does not recognise. A restore gives a machine a NEW host key: if you have just restored it, forget the old one with ssh-keygen -R $MASTER and start again. If you have not, clear nothing: something else is answering for $MASTER" 74 ;;
    *'Permission denied'*)
      [ -t 0 ] \
        || die "$TARGET refuses the operator key, so this could only be a password session, and there is no terminal here to ask on. Start it from a terminal" 69
      DOOR=(-o BatchMode=no -o NumberOfPasswordPrompts=1)
      say "remove-slave: $TARGET refuses the operator key, so ssh asks for the login password ONCE, on this terminal. It is not read from the config and it is not kept" ;;
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
# THE TWO NAMES THE PROGRAM TAKES ARE APPENDED AS THE LAST LINES, in the config's
# own grammar, so the driver composes them into the answers exactly as it composes
# every other value and holds no special case for either. MASTER_FQDN is this
# config's own FQDN under the name remove-slave declares for it, and SLAVE_FQDN is
# the argument. Last, because the composer reads the file top to bottom and a
# later line wins: a config that states either of them itself is stating a fact
# about some other run, and the two this act is about are these.
#
# A CARRIAGE RETURN IS TAKEN OFF. This repository stores LF, but the config is
# written by an operator in whatever editor they have and Notepad writes CRLF,
# and the far side is a bash that reads a CR as part of the value.
{
  printf 'umask 077\ncat > "$1" <<%sAW_CONFIG_END%s\n' "'" "'"
  tr -d $'\r' < "$CONFIG"
  printf "MASTER_FQDN='%s'\n" "$MASTER"
  printf "SLAVE_FQDN='%s'\n" "$SLAVE"
  printf 'AW_CONFIG_END\n'
  tr -d $'\r' < "$DRIVER"
} | ssh "${BASE[@]}" "${DOOR[@]}" "$TARGET" "bash -s -- \"\$HOME/.aw-remove-slave.env\""
REMOVED=${PIPESTATUS[1]}

if [ "$REMOVED" -eq 0 ]; then
  say "remove-slave: $SLAVE is off $MASTER"
  say "remove-slave: $MAP on branch $MASTER and the install branch $SLAVE still stand. They are the git side of the registration, and dropping them is what tears the per-slave reconciler instance down"
else
  say "remove-slave: taking $SLAVE off $MASTER ended with exit $REMOVED. The line above it says which mode stopped and why"
fi
exit "$REMOVED"
