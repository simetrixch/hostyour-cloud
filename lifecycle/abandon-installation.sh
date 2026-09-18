#!/usr/bin/env bash
# =============================================================================
# abandon-installation.sh — take down what ONE installation left outside its
# machines: the DNS records it wrote, its install branches and its books branch
# in the catalog. PowerShell twin: abandon-installation.ps1 (same folder), which
# does the same in the same order and prints the same lines. lifecycle/test.sh
# measures that.
# =============================================================================
#
# USAGE (run from anywhere inside a hostyour-cloud checkout)
#   bash lifecycle/abandon-installation.sh <master-fqdn> [config]
#
# THE TWO INPUTS
#   master-fqdn — WHICH INSTALLATION is abandoned, named by the cluster that
#             keeps its books: the domain of the master, the name of its install
#             branch, the name of its map under clusters/active and the name of
#             the installation's books branch in the catalog.
#   config  — that installation's own key=value file, the one install-machine.sh
#             was given for the master and in the same grammar. Two values are
#             read out of it and nothing is run: the DNS token the installation
#             wrote its records with, and the catalog its tenants are registered
#             in. Defaults to config.<first label of the fqdn>.env beside this
#             file, which is the name release-platform.sh looks for too.
#
# WHAT AN INSTALLATION LEAVES OUTSIDE ITS MACHINES. Restoring a machine to its
# bare point takes back everything on it and nothing beside it: the unit records
# in the zone still answer with the old address, the install branch on origin
# still carries the map a release would pin, and the catalog still carries the
# books branch with every tenant registration. The next installation meets each
# of them — a unit record that answers with a machine that is gone refuses the
# onboarding of the same unit, and a release regenerates a branch of a machine
# that no longer exists.
#
# EVERYTHING IS DERIVED FROM THE INSTALL BRANCH ON ORIGIN, never typed and never
# read off a local checkout: the cluster map of the master and of every slave it
# records say what the machines were and where they stood (nodeCidrs), the
# consumer registrations on the same branch and the tenant registrations on the
# catalog's books branch say which unit names were written, and the map's two
# sender domains say which mail records were published. A record is DELETED only
# where its content proves it the installation's — an A or AAAA at one of the
# installation's addresses, or an SPF that authorises those addresses and nobody
# else. Everything else standing under a derived name is listed by name and
# left: a foreign address at the same name, a DKIM key whose private half lived
# in the Vault that is gone, a DMARC policy the operator wrote, an SPF merged
# with another sender's mechanisms. Listed, because the person tearing the
# installation down needs to see what still stands.
#
# A LIVING INSTALLATION IS REFUSED. Before anything is asked of the operator,
# every address of every cluster is asked whether the cluster's API still
# answers there. THE API PORT AND NOT THE SSH PORT, on purpose: a machine
# restored to its bare point still answers on 22 — that is how the next
# installation reaches it — so the ssh port cannot tell an installation that is
# gone from a bare machine standing at the same address, and it would refuse the
# very case this act exists for. What a living installation has and a bare
# machine has not is the cluster, and the cluster answers on its API port. A
# living installation is offboarded through the Manager and taken back with
# remove-slave and the reset, never abandoned.
#
# THE ORDER IS READ, GUARD, CONFIRM, DNS, BRANCHES, and nothing is written before
# the operator has typed the master's domain. The records go before the
# branches because the branch is what the records are derived FROM: a branch
# deleted first would leave records nobody can attribute any more. A failure in
# the DNS phase therefore stops before the branches and says so, and a second
# run derives the same names again — an absent record and an absent branch are
# not errors, so every run of this is safe to repeat.
#
# THE CONFIG STAYS. A local config is the record of the answers a machine was
# installed with, nothing but the file itself carries it, and the next machine
# of that name is installed from it. This names it and leaves it.
#
# WHAT IS PRINTED IS ASCII, and that is not a typographic preference. The two
# spellings are held to printing the same bytes, and PowerShell writes its output
# in whatever code page the console carries -- so a dash from outside ASCII
# arrives there as a different byte and the pair quietly stops agreeing. The
# comments in these files are read by people and may say what they like.
# =============================================================================

set -uo pipefail

die() { printf 'abandon: %s\n' "$1" >&2; exit "${2:-65}"; }
say() { printf '%s\n' "$1"; }

# THE VALUE OF ONE KEY of a map or a registration, read the way the catalogue's
# own step writes it: a line beginning at column one with the key and a colon. A
# key under `global:` is asked for WITH its two spaces of indentation, so a key
# of the same name at the top level is a different key and is not seen.
# Surrounding quotes are the notation's and are taken off.
value_in_text() { # key, on stdin -> the value, unquoted; 1 where the key is not there
  local key="$1" line value
  while IFS= read -r line || [ -n "$line" ]; do
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

# THE ADDRESSES OF ONE CLUSTER, out of its map's nodeCidrs, the prefix length
# taken off. The branch program writes the list as a flow sequence on one line
# and the Manager writes a slave's as a block sequence, one address per line
# under the key, so both spellings are read.
addresses_in_text() { # on stdin -> one address per line
  local line value entry inblock=0
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$inblock" = 1 ]; then
      case "$line" in
        '    - '*) entry="${line#    - }"; entry="${entry%%/*}"; entry="${entry%"${entry##*[![:space:]]}"}"; printf '%s\n' "$entry" ;;
        *) return 0 ;;
      esac
      continue
    fi
    case "$line" in
      '  nodeCidrs:'*)
        value="${line#  nodeCidrs:}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        case "$value" in
          \[*\])
            value="${value#\[}"; value="${value%\]}"
            IFS=',' read -r -a entries <<< "$value"
            for entry in ${entries[@]+"${entries[@]}"}; do
              entry="${entry#"${entry%%[![:space:]]*}"}"; entry="${entry%%/*}"
              entry="${entry%"${entry##*[![:space:]]}"}"
              [ -n "$entry" ] && printf '%s\n' "$entry"
            done
            return 0 ;;
          '') inblock=1 ;;
        esac ;;
    esac
  done
}

# THE VALUE OF ONE KEY of the config, READ AND NEVER EXECUTED. A shell `.` runs
# every line, and two values are all this act needs out of a file that carries
# thirteen credentials.
config_value() { # KEY -> the value of the KEY='value' line, or nothing
  local key="$1" line
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in
      "$key="\'*) line="${line#"$key="\'}"; printf '%s\n' "${line%%\'*}"; return 0 ;;
    esac
  done < "$CONFIG"
  return 1
}

MASTER="${1:-}"
CONFIG="${2:-}"
[ $# -le 2 ] || die "lifecycle/abandon-installation.sh was given more than it takes: $3" 64
[ -n "$MASTER" ] || die 'usage: lifecycle/abandon-installation.sh <master-fqdn> [config]' 64

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for tool in git curl; do
  command -v "$tool" >/dev/null 2>&1 \
    || die "$tool is not on this path, and this act is nothing but git against origin and curl against the DNS provider"
done
git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die 'not inside a git repository. Run this from a checkout of the platform tree' 66

# ------------------------------------------------------------- the config
[ -n "$CONFIG" ] || CONFIG="$HERE/config.${MASTER%%.*}.env"
[ -r "$CONFIG" ] \
  || die "there is no config at $CONFIG. It is the installation's own, the one it was installed with: name it as the second argument" 66
CONFIG_FQDN="$(config_value FQDN)"
[ "$CONFIG_FQDN" = "$MASTER" ] \
  || die "$CONFIG states FQDN='${CONFIG_FQDN}', and this abandons $MASTER. The config has to be the installation's own, because its token and its catalog are what this writes with" 65
TOKEN="$(config_value CLOUDFLARE_DNS_API_TOKEN)"
[ -n "$TOKEN" ] \
  || die "$CONFIG states no CLOUDFLARE_DNS_API_TOKEN, and the records were written with it" 65
CATALOG_REPO="$(config_value CATALOG_REPO)"
[ -n "$CATALOG_REPO" ] \
  || die "$CONFIG states no CATALOG_REPO, and the installation's books branch stands in that repository" 65
CATALOG_URL="https://github.com/${CATALOG_REPO}.git"

# The MicroK8s API port — a constant of the distribution, the same the Manager
# and the cluster maps carry — and where the DNS provider answers for everybody.
API_PORT=16443
CLOUDFLARE_API='https://api.cloudflare.com/client/v4'
# Every host label the platform tree composes on a cluster's own domain: the four
# bootstrap templates (argo, idp, kube, vault), the registry (zot), the tailnet
# coordinator (tale), the relay (mail), and the ingress hosts of dbgate, grafana,
# the manager, the release cycle's webhook, tekton and the two push routes.
PLATFORM_HOST_LABELS='argo build gate grafana idp kube loki-push mail manager prom-push tale tekton vault zot'
STAGES='dev test prod'

# ================================================================== READ
# ASKED OF THE REMOTE AND NOT OF THIS CHECKOUT, for the reason every act here
# reads the remote: an install branch moves without this workstation.
git ls-remote --exit-code --heads origin "refs/heads/$MASTER" >/dev/null 2>&1
case $? in
  0) BOOKS=yes ;;
  2) BOOKS=no ;;
  *) die 'origin could not be asked for its branches, so nothing here would be about what origin carries' 69 ;;
esac

NAMES=''      # one line per derived record name: name, a tab, what it is
NAME_COUNT=0
ADDRESSES=''  # every address of the installation, space-separated
CLUSTERS=''   # every cluster of the installation, one line each: fqdn, a tab, its addresses
add_name() { NAMES="${NAMES}${1}"$'\t'"${2}"$'\n'; NAME_COUNT=$((NAME_COUNT + 1)); }
is_address() { case " $ADDRESSES " in *" $1 "*) return 0 ;; esac; return 1; }
# A CNAME whose content is one of this installation's own cluster names is the installation's: the
# wildcard deploy-branch writes, `*.<fqdn>` -> `<fqdn>` (hostyour-deploy#35).
is_cluster_name() { case "$CLUSTERS" in *"$1"$'\t'*) return 0 ;; esac; return 1; }
stage_apex() { case "$1" in prod) printf '%s\n' "$UNIT_APEX" ;; *) printf '%s.%s\n' "$1" "$UNIT_APEX" ;; esac; }

if [ "$BOOKS" = yes ]; then
  git fetch --quiet origin "refs/heads/$MASTER" \
    || die "the branch $MASTER could not be fetched from origin, so what it records cannot be read" 69
  say "abandon: $MASTER keeps its books on branch $MASTER of origin, and everything below is read there"
  FILES="$(git ls-tree -r --name-only FETCH_HEAD -- clusters/active registrations 2>/dev/null)"

  MAP="clusters/active/${MASTER}.yaml"
  MAPTEXT="$(git show "FETCH_HEAD:$MAP" 2>/dev/null)" \
    || die "branch $MASTER carries no $MAP. That map is where an installation records what it is, and nothing can be derived without it" 66
  STAGE="$(printf '%s\n' "$MAPTEXT" | value_in_text stage)"
  UNIT_APEX="$(printf '%s\n' "$MAPTEXT" | value_in_text '  unitApex')"
  PLATFORM_DOMAIN="$(printf '%s\n' "$MAPTEXT" | value_in_text '  platformDomain')"
  [ -n "$STAGE" ] || die "$MAP on branch $MASTER states no stage, and the DKIM record is named after it" 65
  [ -n "$UNIT_APEX" ] || die "$MAP on branch $MASTER states no unitApex, and every unit record stands under a zone of it" 65

  # THE MASTER FIRST, THEN EVERY OTHER MAP ON THE BRANCH. The branch is the
  # installation's books, so every map standing there is a cluster of it.
  MAPS="$MAP"
  while IFS= read -r file; do
    case "$file" in clusters/active/*.yaml) [ "$file" = "$MAP" ] || MAPS="$MAPS"$'\n'"$file" ;; esac
  done <<< "$FILES"
  while IFS= read -r file; do
    fqdn="${file#clusters/active/}"; fqdn="${fqdn%.yaml}"
    text="$(git show "FETCH_HEAD:$file" 2>/dev/null)"
    role="$(printf '%s\n' "$text" | value_in_text role)"
    addrs="$(printf '%s\n' "$text" | addresses_in_text | tr '\n' ' ')"
    addrs="${addrs% }"
    [ -n "$addrs" ] \
      || die "$file on branch $MASTER states no nodeCidrs, so where $fqdn stood is unknown: it can neither be asked whether it still answers nor can a record be attributed to it" 65
    say "abandon: $file records $fqdn as ${role:-a cluster of unstated role} at ${addrs// /, }"
    ADDRESSES="$ADDRESSES $addrs"
    CLUSTERS="${CLUSTERS}${fqdn}"$'\t'"${addrs}"$'\n'
    add_name "*.$fqdn" "the platform host names of $fqdn"
    for label in $PLATFORM_HOST_LABELS; do add_name "$label.$fqdn" "a platform host name of $fqdn"; done
    if [ "$fqdn" != "$MASTER" ]; then
      add_name "argo-${fqdn%%.*}.$MASTER" "the reconciler of the slave $fqdn on its master"
      say "abandon: the platform host names of $fqdn: *.$fqdn, argo-${fqdn%%.*}.$MASTER and the labels $PLATFORM_HOST_LABELS below $fqdn"
    else
      say "abandon: the platform host names of $fqdn: *.$fqdn and the labels $PLATFORM_HOST_LABELS below it"
    fi
  done <<< "$MAPS"
  ADDRESSES="${ADDRESSES# }"

  # EVERY CONSUMER AT EVERY STAGE, off the path of its registration: the stage is
  # the file's name, the host label is the registration's `host`, and the name is
  # <label>.<stage apex> — the one composition the Manager and the ApplicationSets
  # share.
  while IFS= read -r file; do
    case "$file" in registrations/*/dev.yaml|registrations/*/test.yaml|registrations/*/prod.yaml) ;; *) continue ;; esac
    unit="${file#registrations/}"; unit="${unit%%/*}"
    stage="${file##*/}"; stage="${stage%.yaml}"
    text="$(git show "FETCH_HEAD:$file" 2>/dev/null)"
    host="$(printf '%s\n' "$text" | value_in_text host)"
    [ -n "$host" ] || host="$(printf '%s\n' "$text" | value_in_text name)"
    [ -n "$host" ] || host="$unit"
    name="$host.$(stage_apex "$stage")"
    say "abandon: $file stands at $name"
    add_name "$name" "the consumer $unit at $stage"
  done <<< "$FILES"

  # THE TWO SENDER DOMAINS, off the master's map: customer mail as the platform
  # domain, alert mail as the unit apex. Each carries the address record and the
  # SPF at the apex, the DKIM key under the relay's selector, which is the stage,
  # and the DMARC policy.
  MAIL_DOMAINS="$UNIT_APEX"
  if [ -n "$PLATFORM_DOMAIN" ] && [ "$PLATFORM_DOMAIN" != "$UNIT_APEX" ]; then
    MAIL_DOMAINS="$PLATFORM_DOMAIN $UNIT_APEX"
  elif [ -z "$PLATFORM_DOMAIN" ]; then
    say "abandon: $MAP names no platformDomain, so no mail record of a platform domain is derived"
  fi
  for domain in $MAIL_DOMAINS; do
    say "abandon: the mail records of $domain: $domain (its address and SPF), $STAGE._domainkey.$domain (DKIM), _dmarc.$domain (DMARC)"
    add_name "$domain" "the sender domain $domain"
    add_name "$STAGE._domainkey.$domain" "the DKIM record of $domain"
    add_name "_dmarc.$domain" "the DMARC record of $domain"
  done
else
  say "abandon: origin carries no branch $MASTER, so no map, no address and no registration of it can be read: no DNS record can be derived or attributed, and the zone is left as it stands"
fi

# ----------------------------------------------------------- the catalog
# THE INSTALLATION'S BOOKS BRANCH IN THE CATALOG, named like the install branch,
# carries the tenant registrations and the pins. It is asked with this
# workstation's own login, the way every act here reaches a repository.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
git ls-remote --exit-code --heads "$CATALOG_URL" "refs/heads/$MASTER" >/dev/null 2>&1
case $? in
  0) CATALOG_BOOKS=yes ;;
  2) CATALOG_BOOKS=no ;;
  *) die "the catalog $CATALOG_URL could not be asked for its branches with this workstation's login, so what it carries of $MASTER cannot be read" 69 ;;
esac
if [ "$CATALOG_BOOKS" = yes ]; then
  CAT="$WORK/catalog"
  git clone --quiet --single-branch --branch "$MASTER" "$CATALOG_URL" "$CAT" \
    || die "the books branch $MASTER of the catalog $CATALOG_URL could not be cloned, so its registrations cannot be read" 69
  while IFS= read -r file; do
    case "$file" in registrations/*/dev.yaml|registrations/*/test.yaml|registrations/*/prod.yaml) ;; *) continue ;; esac
    guid="${file#registrations/}"; guid="${guid%%/*}"
    stage="${file##*/}"; stage="${stage%.yaml}"
    subdomain="$(value_in_text subdomain < "$CAT/$file")"
    if [ "$BOOKS" = yes ] && [ -n "$subdomain" ]; then
      name="*.$subdomain.$(stage_apex "$stage")"
      say "abandon: the catalog's books branch $MASTER carries $file, which stands at $name"
      add_name "$name" "the tenant $guid at $stage"
    else
      say "abandon: the catalog's books branch $MASTER carries $file (subdomain '${subdomain:-none}'), whose wildcard cannot be derived without the map"
    fi
  done <<< "$(git -C "$CAT" ls-tree -r --name-only HEAD -- registrations 2>/dev/null)"
else
  say "abandon: the catalog $CATALOG_URL carries no books branch $MASTER"
fi

if [ "$BOOKS" = no ] && [ "$CATALOG_BOOKS" = no ]; then
  say "abandon: nothing of $MASTER stands on origin or in the catalog, and nothing can be derived without its branch: nothing to do"
  say "abandon: $CONFIG stays. A local config is the record of the answers a machine was installed with, and the next machine of that name is installed from it"
  exit 0
fi

if [ "$BOOKS" = yes ]; then
  say "abandon: $MASTER itself is the machine's name and not the installation's, so its own address record stays"
  say "abandon: $NAME_COUNT names derived; an A or AAAA record among them at ${ADDRESSES// /, } is this installation's, so is a CNAME to one of its own cluster names, and so is an SPF that authorises those addresses and nobody else"
fi

# ================================================================== GUARD
# EVERY ADDRESS OF EVERY CLUSTER IS ASKED whether the cluster's API still
# answers there. Asked as an HTTPS request to the API port: an API server
# answers an anonymous request with a status, and a status of any kind is an
# answer, while a connection refused (curl 7) or one that times out (curl 28) is
# not. Anything else — a handshake that failed, a protocol nobody expected — is
# read as answering, because the safe reading of a doubt is the refusal.
if [ "$BOOKS" = yes ]; then
  while IFS=$'\t' read -r fqdn addrs; do
    [ -n "$fqdn" ] || continue
    for addr in $addrs; do
      case "$addr" in *:*) at="[$addr]" ;; *) at="$addr" ;; esac
      curl -k -sS -o /dev/null --connect-timeout 5 --max-time 10 "https://$at:$API_PORT/" >/dev/null 2>&1
      rc=$?
      case "$rc" in
        7|28) say "abandon: $fqdn does not answer on port $API_PORT at $addr" ;;
        *) die "$fqdn answers on port $API_PORT at $addr (curl exit $rc), so this is a LIVING installation. A living installation is offboarded through the Manager and taken back with remove-slave-from-master and the reset, never abandoned. Nothing has been changed" 69 ;;
      esac
    done
  done <<< "$CLUSTERS"
fi

# ------------------------------------------------------ the push access
# PROVEN BEFORE THE FIRST DELETE, by a dry run of the same push: a deletion this
# workstation cannot push would be found after the records are gone, with the
# branch they were derived from still standing and no way to say so in advance.
DELETABLE=''
if [ "$BOOKS" = yes ]; then
  while IFS=$'\t' read -r fqdn addrs; do
    [ -n "$fqdn" ] || continue
    if [ "$fqdn" = "$MASTER" ] || git ls-remote --exit-code --heads origin "refs/heads/$fqdn" >/dev/null 2>&1; then
      REFUSED="$(git push --dry-run --quiet origin --delete "refs/heads/$fqdn" 2>&1)" \
        || die "this workstation cannot push the deletion of branch $fqdn to origin ($(printf '%s' "$REFUSED" | tr '\n' ' ')), so the branch could not follow the records. Nothing has been changed" 77
      DELETABLE="${DELETABLE}${fqdn}"$'\n'
    fi
  done <<< "$CLUSTERS"
fi
if [ "$CATALOG_BOOKS" = yes ]; then
  REFUSED="$(git -C "$CAT" push --dry-run --quiet origin --delete "refs/heads/$MASTER" 2>&1)" \
    || die "this workstation cannot push the deletion of the books branch $MASTER to the catalog $CATALOG_URL ($(printf '%s' "$REFUSED" | tr '\n' ' ')), so that branch could not follow the records. Nothing has been changed" 77
fi
say "abandon: this workstation can push a branch deletion to origin and to the catalog, so every branch below can follow the records"

# ================================================================ CONFIRM
GOES=''
[ "$BOOKS" = yes ] && GOES="every record above that proves itself this installation's, the branches ${DELETABLE//$'\n'/ }on origin"
[ "$CATALOG_BOOKS" = yes ] && GOES="${GOES:+$GOES, and }the books branch $MASTER of the catalog $CATALOG_URL"
say "abandon: what goes: $GOES. Type $MASTER to confirm, or anything else to stop"
IFS= read -r ANSWER || ANSWER=''
ANSWER="${ANSWER%$'\r'}"
[ "$ANSWER" = "$MASTER" ] || die "the answer was not $MASTER, so this stops. Nothing has been changed" 65

# ==================================================================== DNS
# ONE CALL TO THE API: the token rides the Authorization header, handed to curl
# through a config on its standard input so it stands in no argument list. The
# API wraps every answer in a success flag and can answer 200 without it, so the
# flag and not the status is what is read. On a failure WHY says what happened
# and the caller says what it leaves behind.
RE_ID='"id":"([0-9a-f]{32})"'
RE_TYPE='"type":"([A-Z]+)"'
RE_CONTENT='"content":"(([^"\\]|\\.)*)"'
RE_MESSAGE='"message":"([^"]*)"'
cf() { # method, path, then curl arguments -> BODY; 1 with WHY set when the API did not answer success
  local method="$1" path="$2" rc; shift 2
  BODY="$(printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" | curl -sS -K - -X "$method" "$@" "$CLOUDFLARE_API$path" 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    WHY="the DNS provider could not be reached for $method $path (curl exit $rc: $(printf '%s' "$BODY" | tr '\n' ' '))"
    return 1
  fi
  case "$BODY" in *'"success":true'*) return 0 ;; esac
  WHY="the DNS provider refused $method $path"
  [[ $BODY =~ $RE_MESSAGE ]] && WHY="$WHY: ${BASH_REMATCH[1]}"
  return 1
}
STANDS='What was deleted above stays deleted, every branch stands, and a second run derives the same names again'

# WHICH ZONE A NAME LIVES IN, found by asking the API and walking the labels: the
# exact name first, then the name with its leftmost label taken off, down to the
# last dot. A wildcard label is never part of a zone. Every answer is kept, so a
# second name under the same domain asks once.
ZONE_CACHE=$'\n'
zone_for() { # name -> ZONE_ID and ZONE_NAME, ZONE_ID empty where the token reaches no zone; 1 with WHY on a failure
  local candidate="${1#\*.}" known
  ZONE_ID=''; ZONE_NAME=''
  while [[ "$candidate" == *.* ]]; do
    case "$ZONE_CACHE" in
      *$'\n'"$candidate="*)
        known="${ZONE_CACHE#*$'\n'"$candidate="}"; known="${known%%$'\n'*}"
        if [ "$known" != none ]; then ZONE_ID="$known"; ZONE_NAME="$candidate"; return 0; fi ;;
      *)
        cf GET /zones -G --data-urlencode "name=$candidate" --data-urlencode per_page=1 || return 1
        if [[ $BODY =~ $RE_ID ]]; then
          ZONE_CACHE="${ZONE_CACHE}${candidate}=${BASH_REMATCH[1]}"$'\n'
          ZONE_ID="${BASH_REMATCH[1]}"; ZONE_NAME="$candidate"; return 0
        fi
        ZONE_CACHE="${ZONE_CACHE}${candidate}=none"$'\n' ;;
    esac
    candidate="${candidate#*.}"
  done
  return 0
}

# A TXT VALUE AS THE ONE TEXT IT IS, however the zone stored it: the API answers
# a long TXT as quoted chunks, so the outer quotes come off and the chunk seams
# are joined, the way the Manager and the catalogue's plugin read the same
# records.
txt_text() { local v="$1"; v="${v#\"}"; v="${v%\"}"; printf '%s\n' "${v//\" \"/}"; }

# AN SPF IS THE INSTALLATION'S ALONE when every term is the version, an ip4 of
# one of its addresses or the closing all-mechanism. A term of anybody else's —
# an include, an ip4 of another sender — makes the record a merge that the
# publish step preserved on purpose, and a merge is not deleted.
spf_is_ours() { # the spf text, lower-cased -> 0 when it authorises this installation's addresses and nobody else
  local term ours=0
  for term in $1; do
    case "$term" in
      v=spf1) ;;
      ip4:*) is_address "${term#ip4:}" || return 1; ours=1 ;;
      -all|~all|+all|?all) ;;
      *) return 1 ;;
    esac
  done
  [ "$ours" = 1 ]
}

DELETED=0; LEFT=0; EMPTY=0
if [ "$BOOKS" = yes ]; then
  while IFS=$'\t' read -r name what; do
    [ -n "$name" ] || continue
    zone_for "$name" || die "$WHY. $STANDS" 69
    [ -n "$ZONE_ID" ] \
      || die "the token reaches no zone for $name, walked down to its last dot, so its records cannot be read. $STANDS" 69
    cf GET "/zones/$ZONE_ID/dns_records" -G --data-urlencode "name=$name" --data-urlencode per_page=100 \
      || die "$WHY. $STANDS" 69
    found=0
    # One record per chunk: the API answers the records as one array, and the
    # only place two objects stand side by side in it is between two records.
    RECORDS="${BODY//\},\{/$'\n'}"
    while IFS= read -r chunk; do
      [[ $chunk =~ $RE_ID ]] || continue; id="${BASH_REMATCH[1]}"
      [[ $chunk =~ $RE_TYPE ]] || continue; type="${BASH_REMATCH[1]}"
      [[ $chunk =~ $RE_CONTENT ]] || continue; content="${BASH_REMATCH[1]}"
      content="${content//\\\"/\"}"; content="${content//\\\\/\\}"
      found=1
      ours=no
      case "$type" in
        A|AAAA)
          if is_address "$content"; then ours=yes; shown="$type $name -> $content"
          else say "abandon: zone $ZONE_NAME: left $type $name -> $content, an address this installation never had"; fi ;;
        CNAME)
          if is_cluster_name "$content"; then ours=yes; shown="$type $name -> $content"
          else say "abandon: zone $ZONE_NAME: left $type $name -> $content, an alias to a name that is no cluster of this installation"; fi ;;
        TXT)
          text="$(txt_text "$content")"
          lowered="$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')"
          case "$lowered" in
            v=spf1*)
              if spf_is_ours "$lowered"; then ours=yes; shown="TXT $name ($text)"
              else say "abandon: zone $ZONE_NAME: left TXT $name ($text): it authorises senders beside this installation, or none of its addresses; take its mechanism out by hand"; fi ;;
            *) say "abandon: zone $ZONE_NAME: left TXT $name (${text:0:48}): nothing on the branch proves that content the installation's" ;;
          esac ;;
        *) say "abandon: zone $ZONE_NAME: left $type $name -> $content: this act judges A, AAAA, CNAME and TXT records only" ;;
      esac
      if [ "$ours" = yes ]; then
        cf DELETE "/zones/$ZONE_ID/dns_records/$id" || die "$WHY. $STANDS" 69
        say "abandon: zone $ZONE_NAME: deleted $shown, $what"
        DELETED=$((DELETED + 1))
      else
        LEFT=$((LEFT + 1))
      fi
    done <<< "$RECORDS"
    [ "$found" = 1 ] || EMPTY=$((EMPTY + 1))
  done <<< "$NAMES"
  say "abandon: $DELETED records deleted, $LEFT left standing and listed above, $EMPTY of the derived names carried nothing"
fi

# =============================================================== BRANCHES
# THE MASTER'S BRANCH, THE SLAVES' BRANCHES, THEN THE CATALOG'S, each named. A
# cluster carrying only the slave part has no branch of its own today; one cut
# under the earlier layout is taken down with the rest, and an absent one is
# said and not refused.
if [ "$BOOKS" = yes ]; then
  while IFS=$'\t' read -r fqdn addrs; do
    [ -n "$fqdn" ] || continue
    if [ "$fqdn" = "$MASTER" ] || git ls-remote --exit-code --heads origin "refs/heads/$fqdn" >/dev/null 2>&1; then
      git push --quiet origin --delete "refs/heads/$fqdn" >/dev/null 2>&1 \
        || die "the branch $fqdn could not be deleted on origin. The records above are gone; every branch not yet named as deleted stands, and a second run takes it down" 74
      say "abandon: deleted branch $fqdn on origin"
    else
      say "abandon: origin carries no branch $fqdn, as a cluster carrying only the slave part has none of its own"
    fi
  done <<< "$CLUSTERS"
fi
if [ "$CATALOG_BOOKS" = yes ]; then
  git -C "$CAT" push --quiet origin --delete "refs/heads/$MASTER" >/dev/null 2>&1 \
    || die "the books branch $MASTER could not be deleted in the catalog $CATALOG_URL. Everything above is gone, that branch stands, and a second run takes it down" 74
  say "abandon: deleted the books branch $MASTER of the catalog $CATALOG_URL"
fi

say "abandon: $CONFIG stays. A local config is the record of the answers a machine was installed with, and the next machine of that name is installed from it"
