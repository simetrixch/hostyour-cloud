#!/usr/bin/env bash
# =============================================================================
# driver.sh — a first master, installed from zero, ON THE MACHINE ITSELF.
# =============================================================================
#
# WHAT THIS IS. A driver. It runs no step and changes nothing a program would not
# change: it puts the two things a program cannot put there itself — the engine and the catalogue —
# and then invokes the programs of the master sequence, each of them three times.
# install-order.yaml states that division in its own words: "THIS FILE STATES THE
# ORDER. IT DOES NOT RUN IT. A driver reads the sequence and invokes the programs
# itself."
#
# IT CARRIES ITS OWN COPY OF THE SEQUENCE, and does not read that file. The list is written out at
# PROGRAMS below, and a sentence here claiming the order is read out of
# clusters/platform/install-order.yaml would hide a drift rather than prevent one: the file and this
# driver can name different programs — the file six for a master and this driver five, without
# onboard-manager — and nobody can see it, because such a sentence says there is nothing to compare.
# install-order.yaml says the same thing from its side, in its own header: "WHO READS IT TODAY:
# NOBODY. Both drivers still carry their own copy of the sequence."
#
# The other carrier is the manager, which invokes the same programs over its own channel and keeps
# its list in TypeScript. Three carriers of one fact, and the one that was written to be the answer
# is the one nothing reads. Whether the driver should READ the file is a separate question with a
# real consequence — it would run onboard-manager too, which it does not — and it is not answered
# by this comment.
#
# WHY IT RUNS HERE AND NOT ON THE OPERATOR'S MACHINE. Everything it fetches is
# fetched by THIS machine, and every one of the three is public: the pin out of the
# platform repository, the two executables out of the release, the catalogue out of
# the repository the deployment programs stand in. Nothing is carried from the
# operator's own disk, so what stands here afterwards is what the repositories say
# and not what somebody's checkout happened to hold.
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
# Every value in it is one the programs declare, lower-cased into the answers
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
  # THE RECORDS ARE HANDED TO THIS ACCOUNT BEFORE THEY ARE NAMED. Every run is
  # elevated, so the engine creates /var/lib/ansiwise as root on a machine that has
  # never carried it — and the launcher fetches over a session opened as this
  # account, which then reads nothing. It is the same shape as the catalogue, and
  # the same rule: hostyour-manager#68 records /var/lib/ansiwise and its runs
  # directory as this account's.
  #
  # IN THE SUMMARY BECAUSE THE SUMMARY RUNS ON BOTH PATHS. A failed installation is
  # the one whose records are read, so handing them over only on success would take
  # them away exactly when they are wanted.
  # The launcher reads this line to know which records to fetch. One line, one
  # run identifier, in the order they happened.
  # PLAIN, AND DELIBERATELY UNDRESSED. Every other line here is written for a person
  # and wears the colour that helps them read it. This one is written for the
  # LAUNCHER, which reads it to know which records to fetch — and an escape sequence
  # in front of it is not whitespace, so a pattern anchored at the start of the line
  # never matched and the launcher reported that no runs were named while three
  # stood on the line above it.
  printf '\nRUNS %s\n' "${RUN_IDS[*]:-}"
}

# ------------------------------------------------------------ what it was told
readonly CONFIG="${1:?the config's path is this script's only argument}"
[ -r "$CONFIG" ] || die "there is no config at $CONFIG, and it is the only thing this is told" 64

# SHREDDED ON EVERY PATH. A credential that outlives the act it was handed over
# for is a credential nobody is watching.
# WHAT THIS PUT ON THE MACHINE, TAKEN OFF AGAIN ON EVERY PATH, including a failure.
# The answers are not an afterthought here: most of what deploy-branch is told is
# credentials, and a file holding them has no reason to outlive the run that needed it.
cleanup() {
  rm -f "$CONFIG" 2>/dev/null || true
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
readonly DEPLOY_REPO="${DEPLOY_REPO:-}"
readonly PLATFORM_REPO="${PLATFORM_REPO:-}"
readonly OPERATOR="${OPERATOR_USER:-}"
readonly FQDN="${FQDN:-}"
readonly ROLE="${ROLE:-}"

for named in STAGE CATALOG_REPO DEPLOY_REPO PLATFORM_REPO OPERATOR FQDN ROLE; do
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
readonly ANSWERS_DIR=/home/$OPERATOR/.installer-answers
ANSWERS=''

RUN_IDS=()

# Every elevated command goes through here, and the password reaches it on
# STANDARD INPUT — never an argument list, which stands in this machine's own
# process listing for anyone on it to read.
root() { printf '%s
' "$ELEVATION_PASSWORD" | sudo -S -p '' "$@"; }

# =============================================================================
phase '0 / 4   what this machine is, before anything is touched'
# =============================================================================
say "asked as $(id -un) on $(hostname), for $FQDN, stage $STAGE"
say "$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME") · kernel $(uname -r) · $(nproc) cpu · $(free -g | awk '/^Mem:/{print $2}') GB"
say "free on /: $(df -h / | awk 'NR==2{print $4}')"

sudo -n true 2>/dev/null && warn 'this account already raises commands without a password — nothing here needs that'
printf '%s
' "$ELEVATION_PASSWORD" | sudo -S -p '' true 2>/dev/null || die 'the ELEVATION_PASSWORD in the config does not raise a command on this machine' 77
good 'the elevation password raises a command'

# THE BRANCH THIS MACHINE WOULD PUSH TO, ASKED BEFORE ANYTHING IS TOUCHED. A RESTORE
# WIPES A MACHINE AND LEAVES ITS BRANCH STANDING — the branch lives in the platform
# repository, which no restore reaches. deploy-branch cuts from the master this machine
# cloned and merges the release PLATFORM_REF names into it, so it does not descend from
# what is on the remote, and its push is refused at the last step with a git hint
# recommending `git pull` — which here would graft the record of a machine that no
# longer exists onto the machine that replaced it.
#
# WHICH OF THE TWO CASES IT IS, THIS CANNOT KNOW and does not guess. A branch standing
# there means either the machine is LIVE and this is not a first installation, or it is
# what a restore left behind. Only the operator knows which, so both are said and the
# run stops.
#
# NO CREDENTIAL, AND DELIBERATELY SO. The platform repository is the one this machine
# already reads its pin out of over plain HTTPS, so asking github whether a ref exists
# needs nothing — and a token would have to stand in this command's own words, which is
# the one thing nothing here does. GIT_TERMINAL_PROMPT=0 keeps a repository that is NOT
# public from turning this into a prompt nobody can see.
BRANCH_TIP=$(GIT_TERMINAL_PROMPT=0 git ls-remote --heads \
  "https://github.com/$PLATFORM_REPO.git" "refs/heads/$FQDN" 2>/dev/null | awk '{print $1}')
STATUS=$?

if [ -n "$BRANCH_TIP" ]; then
  # A BRANCH STANDING THERE IS NOT YET A PROBLEM. Treating it as one makes the
  # installer refuse its own second run, two lines above a message promising that
  # every program is idempotent. deploy-branch PUSHES this branch, so from its first
  # green run onwards the branch is supposed to be there — and deploy-branch asks the
  # same question of the same remote before its first step, to decide whether to cut
  # the branch or to stand the checkout on what is published.
  #
  # WHAT SEPARATES THE TWO CASES IS WHETHER THIS MACHINE WROTE IT. A branch this
  # installation pushed is in this machine's own checkout, object and all. One left
  # by a machine that was restored is not: the restore took the checkout with it and
  # left the branch standing in a repository no restore reaches.
  #
  # A REFUSAL IS NOT AN ANSWER ABOUT CONTENT, and reading the checkout unelevated
  # makes exactly the mistake this check exists to prevent: git refuses a repository
  # owned by another account outright, and that refusal reads as "this machine does
  # not carry the commit" about a commit this machine wrote itself. It is the same
  # defect as ansiwise-plugins#162, in this file.
  #
  # So the reading is elevated and says safe.directory, which takes BOTH ownership and
  # permission out of the answer — and where it still cannot read, it says so instead
  # of concluding anything.
  CHECKOUT=/srv/hostyour-cloud
  BRANCH_DOUBT=''
  BARE=''
  if ! root test -d "$CHECKOUT/.git"; then
    BARE="this machine carries no checkout at $CHECKOUT at all, so nothing here wrote that branch"
  elif ! root git -c "safe.directory=$CHECKOUT" -C "$CHECKOUT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    BRANCH_DOUBT="$CHECKOUT is there but could not be read, so whether this machine wrote that branch is unknown"
  # ASKED AFTER A FETCH, because a machine cannot judge a commit it has never seen. The published
  # tip usually IS newer than anything here: that is how a release reaches a cluster — a merge of
  # the product branch into this machine's own, made from wherever the release was cut.
  else
    git -C "$CHECKOUT" fetch --quiet origin "$FQDN" 2>/dev/null || true
    if ! git -C "$CHECKOUT" cat-file -e "$BRANCH_TIP^{commit}" 2>/dev/null; then
      BRANCH_DOUBT="this machine could not fetch that commit, so whether it wrote that branch is unknown"
    # RELATED IN EITHER DIRECTION IS OURS. What this has to tell apart is a branch this machine grew
    # from one somebody else's machine wrote, and both readings of "related" answer that: the tip
    # descends from what stands here (a release was merged in), or what stands here descends from the
    # tip (this machine has committed since). Only two histories with nothing in common are foreign.
    #
    # ASKING ONLY THE FIRST OF THE TWO STOPS A RUN. A release merged into this branch from a
    # workstation makes the machine call its own branch somebody else's, so the checkout is never
    # stood on it and deploy-branch meets a local branch it may not reset — twenty-four steps spent
    # to be refused at the fifth.
    elif ! git -C "$CHECKOUT" merge-base --is-ancestor "$BRANCH_TIP" "refs/heads/$FQDN" 2>/dev/null       && ! git -C "$CHECKOUT" merge-base --is-ancestor "refs/heads/$FQDN" "$BRANCH_TIP" 2>/dev/null; then
      BRANCH_DOUBT="this machine's branch and what is published have no commit in common"
    fi
  fi

  # ONLY WHAT IS CERTAIN IS REFUSED. A machine carrying no checkout at all cannot have
  # written that branch — there is no other reading. Everything else is a SUSPICION:
  # deploy-branch says it plainly and at once if it is true, and a check that stops a
  # run it should have let through is worse than one that lets a suspicion pass, so it
  # does not get to stop one on a guess.
  if [ -n "$BARE" ]; then
    die "the platform repository $PLATFORM_REPO already carries a branch named $FQDN, standing at $BRANCH_TIP — and $BARE.

deploy-branch cuts this machine's branch from the master this machine cloned and merges
PLATFORM_REF into it, so it will not descend from that one, and its push would be
refused at the LAST step of the program — after everything before it has already been
done.

WHICH OF THESE IT IS, ONLY YOU KNOW:

  The machine is LIVE and this is not its first installation. Then this is not the
  right tool: adopt it from the Manager, which knows how to meet a machine that
  already exists.

  It is what a RESTORE left behind. A restore wipes a machine and never touches the
  repository, so the branch outlived the machine it described. Note its tip above in
  case you want it back, then delete it and start again:

    git push origin --delete $FQDN" 65
  fi

  if [ -n "$BRANCH_DOUBT" ]; then
    warn "$FQDN stands at ${BRANCH_TIP:0:7} in $PLATFORM_REPO, and $BRANCH_DOUBT. If that branch is what a restore left behind, deploy-branch's push is refused at its last step and \`git push origin --delete $FQDN\` is what clears it"
  else
    good "$FQDN stands at ${BRANCH_TIP:0:7} and this machine wrote it — deploy-branch stands the checkout on it and its push will fast-forward"
  fi
elif [ $STATUS -ne 0 ]; then
  warn "could not ask whether $PLATFORM_REPO already carries a branch named $FQDN. If it does, deploy-branch is refused at its last step"
else
  good "$PLATFORM_REPO carries no branch named $FQDN — this machine's is cut fresh"
fi

for path in "$CATALOG" /srv/hostyour-cloud /var/lib/ansiwise; do
  [ -e "$path" ] && warn "$path already stands here — this is not a bare machine, and what follows will act on what is there"
done

# THE PACKAGE MANAGER, ASKED WHETHER IT IS FREE BEFORE ANY PROGRAM WANTS IT. Ubuntu
# starts unattended-upgrades on its own shortly after boot, so a machine that was just
# restored is holding the dpkg lock through the first minutes of its life — which is
# exactly when deploy-host reaches install_packages, four rows into the first program.
# Measured on a real machine: the first run after a restore dies with
# "Could not get lock /var/lib/dpkg/lock-frontend. It is held by process 14400
# (unattended-upgr)", and a minute later the same run is green.
#
# APT ITSELF DOES THE WAITING. DPkg::Lock::Timeout makes it block for the lock rather
# than fail on it, so this asks in short turns and reports between them instead of
# holding a silent session. `check` is the cheapest thing apt does that takes the lock.
#
# NOTHING IS STOPPED OR MASKED. unattended-upgrades is a machine's security updates
# doing their job, and switching them off to make an installation quieter is not a
# trade this makes — it waits for them like any other tenant of that lock.
#
# THIS COMES OUT WHEN ansiwise-plugins#163 LANDS: install_packages will carry the same
# option itself, and a step that waits for its own lock needs no gate in front of it.
# WHETHER THE MACHINE HAS FINISHED STARTING, asked before anything that needs a service.
#
# A machine that was restored a moment ago answers every other question in this phase correctly
# while its system bus is not yet accepting connections — and the first thing that needs the bus is
# installing a snap, which registers services. Measured on a real machine whose uptime was 0 minutes
# when the run started: deploy-cluster dies at install_snap with
# "Failed to connect to system scope bus via local transport: Connection refused", the snap rolls
# itself back, and the same run minutes later installs it without trouble.
#
# IT BELONGS HERE AND NOT IN THE STEP. This phase exists to establish that a machine is in a state
# an installation can begin from and to say so before anything is changed; a bus that is not up yet
# is that kind of fact, and it clears itself within a minute. Left to the step, the same fact arrives
# four rows into the third program as a snap error quoting systemctl, three layers from its cause.
#
# `degraded` IS ACCEPTED, and that is deliberate rather than lax: it means the machine HAS finished
# starting and some unit of it failed. That is a different problem, it belongs to whoever reads the
# unit, and swallowing it into this wait would hide it behind a timeout about booting.
STARTED_WAITED=0
until case "$(systemctl is-system-running 2>/dev/null)" in running|degraded) true ;; *) false ;; esac; do
  if [ "$STARTED_WAITED" -ge 300 ]; then
    die "this machine has not finished starting after ${STARTED_WAITED}s — systemctl is-system-running says '$(systemctl is-system-running 2>&1)'.

Everything after this needs services, and the first of them fails on a system bus that is not
accepting connections yet. What to look at:

  systemctl list-jobs
  systemctl --failed" 75
  fi
  [ $(( STARTED_WAITED % 30 )) -eq 0 ]     && say "this machine is still starting — waited ${STARTED_WAITED}s"
  sleep 5
  STARTED_WAITED=$(( STARTED_WAITED + 5 ))
done
good "this machine has finished starting${STARTED_WAITED:+ after ${STARTED_WAITED}s}"

PACKAGES_WAITED=0
until root apt-get -o DPkg::Lock::Timeout=5 check >/dev/null 2>&1; do
  if [ "$PACKAGES_WAITED" -ge 600 ]; then
    die "the package manager has been busy for ${PACKAGES_WAITED}s and deploy-host installs packages four rows in.

A freshly booted Ubuntu runs unattended-upgrades, which holds the dpkg lock — that is
normal and it finishes on its own. Ten minutes is longer than it should take, so
something else holds it. What to look at:

  ps -o pid,etime,cmd -C unattended-upgrade
  sudo fuser -v /var/lib/dpkg/lock-frontend" 75
  fi
  [ $(( PACKAGES_WAITED % 60 )) -eq 0 ] \
    && say "the package manager is busy — a freshly booted Ubuntu runs unattended-upgrades; waited ${PACKAGES_WAITED}s"
  PACKAGES_WAITED=$(( PACKAGES_WAITED + 5 ))
done
good "the package manager is free${PACKAGES_WAITED:+ after ${PACKAGES_WAITED}s}"

MISSING=()
for tool in git curl python3; do command -v "$tool" >/dev/null 2>&1 || MISSING+=("$tool"); done
if [ ${#MISSING[@]} -gt 0 ]; then
  say "this machine carries no ${MISSING[*]} — and the catalogue every program is READ FROM cannot be"
  say 'cloned without git, so the first program cannot run without it. This is the one'
  say "change here that no program makes, and deploy-host's install_packages row makes it again"
  root bash -c 'DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 update -qq && DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 install -y -qq git curl python3' \
    || die "apt-get would not install ${MISSING[*]}" 70
  good "installed ${MISSING[*]}"
else
  good 'git, curl and python3 are already here — nothing installed'
fi

# =============================================================================
phase '1 / 4   the engine, at the version the platform repository pins'
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

ENGINE_ANSWERS=$("$ENGINE" --version 2>/dev/null || true)
if [ "$ENGINE_ANSWERS" = "$PIN" ]; then
  good "$ENGINE already answers $PIN — nothing fetched"
else
  [ -n "$ENGINE_ANSWERS" ] && say "$ENGINE answers $ENGINE_ANSWERS, which is not the pin"
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
phase '2 / 4   the catalogue every program is read out of'
# =============================================================================
# install-order.yaml names four things that must stand under this ONE path, and
# says why it is not free: hostyour-vault-unseal.service's WorkingDirectory and
# both of its ExecStart lines name files under it.
#
# NOTHING IS HANDED OVER TO REACH IT. The repository the deployment programs stand
# in is public, so this machine clones and fetches them on its certificate store
# alone — the same footing the pin and the two executables above arrive on. No
# credential reaches git in this phase.
#
# GIT_TERMINAL_PROMPT=0 ALL THE SAME. A repository github answers 404 for — a name
# with a typo in it, or one that is not public — turns an unauthenticated clone into
# a prompt for a username, and a prompt on a session nobody is watching hangs an
# installation instead of failing it.
#
# ASKED WITH ELEVATION, because a catalogue an elevated clone left behind is root's
# and an unelevated test would answer "not a checkout" about a checkout standing
# right there — sending this into a clone that dies on a non-empty directory.
if root test -d "$CATALOG/.git"; then
  # BROUGHT FORWARD, NOT LEFT WHERE IT STANDS. This phase and the one before it are
  # two halves of one statement: the binary is placed at the pin the platform
  # repository names, and the catalogue carries the row that HOLDS a machine to that
  # pin. A run that moved the first and left the second stale puts the two into
  # contradiction, and the machine is then refused by its own catalogue —
  # "ansiwise is at <the new one> and the program pins <the old one>", measured on a
  # real machine, at the last step of deploy-cluster.
  #
  # ELEVATED AND NOT AUTHENTICATED. The catalogue repository is public, so the fetch
  # itself asks for nothing; what needs raising is the WRITE — /srv is root's, and a
  # checkout an earlier elevated clone left there belongs to root until the chown
  # below hands it over.
  say "bringing $CATALOG onto the published head of its branch"
  # THE ORIGIN IS STATED, NOT INHERITED. A checkout standing here was cloned from
  # whatever repository this machine was told to read at the time, and a fetch goes
  # to that one for ever unless something says otherwise — to a remote this machine
  # now has no credential for, or to one that no longer carries the programs. Either
  # way the refusal names github.com and a missing username, which says nothing about
  # the cause. DEPLOY_REPO is what this machine reads, so it is what this checkout
  # follows, and stating it costs one command on every run and nothing when it already
  # agrees.
  want="https://github.com/$DEPLOY_REPO.git"
  have=$(root git -C "$CATALOG" remote get-url origin 2>/dev/null || true)
  if [ "$have" != "$want" ]; then
    root git -C "$CATALOG" remote set-url origin "$want"       || die "could not point $CATALOG at $DEPLOY_REPO" 69
    say "$CATALOG followed $have and now follows $DEPLOY_REPO"
  fi
  branch=$(root git -C "$CATALOG" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
  [ -n "$branch" ] && [ "$branch" != HEAD ] || branch=master
  root bash -c "GIT_TERMINAL_PROMPT=0 git -C '$CATALOG' fetch --quiet origin '$branch'"     || die "could not fetch $DEPLOY_REPO into $CATALOG — check that the repository exists and is reachable from this machine" 69
  # RESET AND NOT MERGE: nothing on a machine may write this tree, so the published
  # head is the whole of what it should carry, and anything else standing here is
  # debris a merge would try to keep.
  root git -C "$CATALOG" reset --quiet --hard FETCH_HEAD     || die "could not bring $CATALOG onto the published head of $branch" 69
  good "$CATALOG stands at $(root git -C "$CATALOG" rev-parse --short HEAD 2>/dev/null || echo 'an unreadable commit') on $branch"
else
  say "cloning $DEPLOY_REPO into $CATALOG"
  root bash -c "GIT_TERMINAL_PROMPT=0 git clone --quiet 'https://github.com/$DEPLOY_REPO.git' '$CATALOG'"
  status=$?
  [ $status -eq 0 ] || die "could not clone $DEPLOY_REPO — check that the repository exists and is reachable from this machine" 69
  good "cloned $DEPLOY_REPO"
fi

# HANDED TO THIS ACCOUNT, on both paths, because the clone had to be elevated and
# what an elevated clone leaves behind belongs to root — including one left by an
# earlier run. Two things need it not to:
#
# This account reads the catalogue on the very next line, and every program is read
# out of it afterwards. And the Manager REFRESHES this checkout later WITHOUT
# elevation, on purpose — a tree it cannot write is a tree it cannot bring forward.
# That fetch needs no credential of its own, because the repository the programs
# stand in is public; what it needs is a tree this account owns, and an elevated
# clone leaves one belonging to root.
root chown -R "$OPERATOR:$OPERATOR" "$CATALOG" \
  || die "could not hand $CATALOG to $OPERATOR, and the programs run as that account" 73
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
# engine refuses an answer a program does not declare, by name and one line each, so
# handing one program the whole config buries its run in refusals. It is right to
# refuse: an answer no program asked for is a name somebody mistyped or one a program
# stopped using, and either is worth a refusal rather than a silent pass.
#
# The Manager composes per program in exactly this way, and its hostAnswers() is
# deploy-host's own (hostyour-manager/server/domains/runs/defs/deploy-slave.ts).
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
# among the answers by name — ansiwise-core/lib/src/model/caller_inputs.dart —
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

# WHAT EACH ANSWER IS, not only what it is called. An answer declared as a list and
# given a string is refused by kind — "alert_recipients" holds textList, and was
# given String — and the config has one line per name, so the shape has to be read
# off the program rather than guessed from the value.
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
    operator's formatting, not part of the entry, and an empty entry is a trailing
    comma rather than a member."""
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
  ) || { bad "could not write the answers for $program"; return 1; }

  chmod 600 "$ANSWERS" || { bad "could not close $ANSWERS to this account alone"; return 1; }
  say "$program is told $counted"
  return 0
}

# =============================================================================
# The five programs that MAKE A MASTER, each of them test then dry then run — the
# three modes gate one another, and a mode that is not green stops the whole
# installation here rather than carrying a doubt into the next program.
#
# THE LAST OF THE FIVE puts the master on the private network it runs the coordinator
# for. It is here and not in the Manager because a master that is not a member of its
# own network cannot reach a slave at the address the design tells it to dial, and
# nothing else in an installation would notice: every surface answers over its public
# name, and the gap shows up much later as a slave that cannot be deployed. It waits
# for the coordinator first, because the coordinator is a workload the reconciler
# brings rather than anything a program here puts down.
#
# install-order.yaml's master sequence names a SIXTH, onboard-manager, and it is
# deliberately not here. It onboards this platform's own manager AS A CONSUMER, over
# the route every other consumer takes — which makes it an onboarding, and onboarding
# is not this tool's to do. The header of this file has said so since it was written:
# adopting a machine, deploying a slave, onboarding a consumer or a tenant are the
# Manager's, and this deliberately cannot do any of them. It could, and it did, and
# that was the defect.
#
# WHAT A MASTER IS WITHOUT IT: a machine, a branch, a cluster, and the platform
# services on it — including the manager itself, which deploy-platform-services puts
# there and which is what the operator then works from. Onboarding it as a consumer is
# the first thing done IN the manager, by hand, and not the last thing done to it by a
# script.
# =============================================================================
readonly PROGRAMS=(deploy-host deploy-branch deploy-cluster deploy-platform-services tailnet-join-self)

run_program() {
  local program="$1" mode="$2" ordinal="$3"
  printf '%s   %-26s %-5s%s\n' "$C_BLD" "$program" "$mode" "$C_OFF"
  local began; began=$(date +%s)
  local log="/tmp/aw-$program-$mode.log"

  # A HEARTBEAT, because a program can be busy and silent at the same time.
  # deploy-cluster's run took 280 seconds on a bare machine and said nothing for most
  # of it, and a screen that says nothing is indistinguishable from one that has hung.
  # This says how long, and nothing else.
  ( while :; do
      sleep 60
      printf '%s       … still running, %ds%s\n' "$C_DIM" "$(( $(date +%s) - began ))" "$C_OFF"
    done ) &
  local ticker=$!

  # `-u "$OPERATOR"` IS WHAT THIS LINE IS ABOUT, AND IT IS NOT ELEVATION. The tool runs
  # as the account that owns this machine — the same account the Manager starts it as
  # later. What sudo does here is the OTHER thing it does when it enters an account: it
  # builds that account's group set afresh out of the group database.
  #
  # WHY THAT IS NEEDED. A process carries the groups its session was given, and nothing
  # later reaches it. deploy-cluster installs MicroK8s and puts this account in the
  # `microk8s` group — inside this very session, which therefore does not have it.
  # deploy-platform-services then asks the cluster a question as this account and is told
  # "Insufficient permissions to access MicroK8s", AFTER its own elevated write had already
  # succeeded: the Secret existed and the step reported the machine as not in the state it
  # produces (measured on a real machine, kubernetes_secret_from_vault). Entering the
  # account again hands each program the machine as it stands, not as it stood at the door.
  #
  # WITHOUT `-u` THIS LINE MEANS root, WHICH IS A DIFFERENT PROGRAM ENTIRELY. Every command
  # of every program then runs as root, including the ones needing nothing, and each leaves a
  # file behind that this account cannot read — in /srv/hostyour-cloud, .git/HEAD among them
  # at mode 600 — so the next run, started as this account, meets its own checkout
  # with git answering "not a git repository". What needs root is raised one command at a
  # time, by the tool, from the row that needs it (ansiwise-core domain/shell.dart
  # `Command.elevated`), with the password that rides beside the answers (BESIDE above; the
  # catalogue's ansiwise.yaml says `password_from_caller: true`).
  #
  # THE RUN'S OWN OUTPUT ON THIS PIPELINE, AS IT HAPPENS. Capturing it to a file and
  # printing it when the program ends shows nothing for as long as a run of ninety
  # steps takes, and the one asking for traceability watches a blank terminal.
  #
  # The file is kept all the same: tee writes the one the failing-record reader and
  # the summary both read afterwards.
  printf '%s\n' "$ELEVATION_PASSWORD" | ( cd "$CATALOG" && sudo -S -p '' -u "$OPERATOR" "$ENGINE" "$program" \
      --programs "$CATALOG/ansiwise/programs" \
      --config "$CATALOG/ansiwise.yaml" \
      --answers "$ANSWERS" \
      --runs "$RUNS" \
      --role "$ROLE" --stage "$STAGE" --fqdn "$FQDN" \
      --mode "$mode" ) 2>&1 | tee "$log" | sed -u 's/^/       /'
  # THE SECOND ELEMENT, not the last. The pipeline is printf, the run, tee, sed —
  # so $? is sed's, which succeeds whatever the run did.
  local status=${PIPESTATUS[1]}
  kill "$ticker" 2>/dev/null
  wait "$ticker" 2>/dev/null
  local took=$(( $(date +%s) - began ))

  # THE RECORD'S NAME IS LOOKED FOR, NOT TAKEN FROM THE END. Reading it off the last
  # line holds right up until a run has something to say afterwards —
  # deploy-platform-services ends with an `issue:` line under its summary, so the
  # last word is "issue:" and the identifier is dropped. The launcher then fetches
  # every record but the failing run's: the only one anybody wanted.
  #
  # A RUN IDENTIFIER HAS A SHAPE, and that is what is matched: eight digits, T, six
  # digits, Z, then the process and a hex tail. The LAST one in the log is this run's,
  # because a program says it once at the end of its own summary.
  local last; last=$(grep -E '^[[:space:]]*[0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9a-f]+[[:space:]]' "$log" | tail -1)
  local id; id=$(printf '%s' "$last" | awk '{print $1}')
  case "$id" in *T*Z-*) RUN_IDS+=("$id") ;; *) id='' ;; esac

  if [ $status -eq 0 ]; then
    printf '%s   %-26s %-5s ✓ %s%s  %s(%ds)%s\n' "$C_GRN" "$program" "$mode" "$(printf '%s' "$last" | sed 's/^[^ ]*  *//')" "$C_OFF" "$C_DIM" "$took" "$C_OFF"
  else
    printf '%s   %-26s %-5s ✗ exit %d%s  %s(%ds)%s\n' "$C_RED" "$program" "$mode" "$status" "$C_OFF" "$C_DIM" "$took" "$C_OFF"
  fi
  rm -f "$log"

  if [ $status -ne 0 ]; then
    bad "$program ($mode) ended with exit $status${id:+ — its record is $RUNS/$id}"

    # THE RECORD READ OUT HERE, IN THIS SESSION, rather than left to be fetched.
    # A run that fails before install_authorized_key leaves this account with no key
    # on the machine, so the launcher's own fetch cannot reach anything — and that is
    # exactly the run whose record is wanted. This session is already open and
    # already elevated, so the failing step can say what it said.
    if [ -n "$id" ]; then
      root cat "$RUNS/$id/run.json" 2>/dev/null | python3 -c "
import json, sys
try:
    run = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for at, step in enumerate(run.get('steps', []), 1):
    verdict = step.get('verdict', {})
    if verdict.get('label') == 'ok':
        continue
    print(f\"       step {at} of {len(run['steps'])}, {step['step']} ({step.get('source','')})\")
    for line in (verdict.get('reason') or verdict.get('label') or '').splitlines():
        print('         ' + line)
" || true
    fi
    return 1
  fi
  return 0
}

# WHERE THE RECORDS GO, MADE FOR THE ACCOUNT THAT WRITES THEM. This tool runs as the
# operator now, and /var/lib is root's — so the account that is about to record every run
# there cannot create the directory it records into. It is created elevated and handed
# over, once, before the first program: the same one act ansiwise-git's git_clone performs
# for a checkout under /srv, and for the same reason. `install -d` also settles a machine
# carrying a root-owned one from an earlier installation.
root install -d -o "$OPERATOR" -g "$OPERATOR" -m 755 /var/lib/ansiwise || die "could not make /var/lib/ansiwise for $OPERATOR; the programs would have nowhere to record" 78
good "/var/lib/ansiwise belongs to $OPERATOR — every run records into it as itself"

step=0
for program in "${PROGRAMS[@]}"; do
  step=$(( step + 1 ))
  phase "$step / 4   $program"

  compose_answers "$program" || {
    say ''
    say "the installation stops here, before $program was started."
    # NOT `break`. A break leaves the loop and falls into the paragraph below it, which
    # says the installation is done and every run was green — over a failure that had
    # just been reported. The two ways out of this loop have to end the same way.
    summary
    exit 1
  }
  for mode in test dry run; do
    run_program "$program" "$mode" "$step" || {
      say ''
      say "the installation stops here. Nothing after $program was started, and what"
      say 'it already did stands.'
      say ''
      say 'YOU DO NOT NEED TO RESTORE THIS MACHINE. Read the step above, fix what it'
      say 'names, and start this again: a second run MEASURES what the first one left and'
      say 'does only what is still missing.'
      say ''
      say 'ONE PROGRAM IS CUT ONLY ONCE. deploy-branch cuts the branch of this machine at'
      say 'its birth and refuses to cut it twice, because that branch carries the installation.'
      say 'On a later run this puts the checkout ON that branch instead, which is what the'
      say 'step asks for, and its other rows then re-measure as every other program does.'
      say ''
      say 'A restore is worth it for one reason only — when you want to prove a FIRST'
      say 'installation on a bare machine rather than get this one working. Then restore'
      say "AND delete this machine's branch, because a restore never touches the"
      say 'repository and the branch left standing stops the next run at its last step.'
      summary
      exit 1
    }
  done
done

phase 'done'
# COUNTED, never stated. A sentence naming the numbers goes wrong the moment the sequence changes,
# and the last thing an installation tells the operator would then be wrong about what it has just
# done. Both numbers are held by this script already.
good "$FQDN is installed: ${#PROGRAMS[@]} programs, ${#RUN_IDS[@]} runs, every one green"
say "the machine's own records stand under $RUNS"
summary

# THIS FILE IS READ FROM STANDARD INPUT, so what follows it on that stream is read as
# more of it. PowerShell appends its own newline when it pipes a string to a native
# command, and on Windows that newline is CRLF — so the last thing to arrive is a lone
# carriage return on a line of its own, which bash tries to run:
#
#   bash: line 828: $'\r': command not found
#
# Measured on a green installation, two lines past the end of the stream.
# Stripping carriage returns cannot reach it: it is added after the stripping, by the
# thing doing the sending.
#
# An explicit exit ends the script where the script ends, and bash reads no further.
exit 0
