#!/usr/bin/env bash
# =============================================================================
# create-github-app.sh — create the platform's GitHub App in the customer's
# organisation, install it there, and write its three answers into the config.
# PowerShell twin: create-github-app.ps1 (same folder), which does the same in
# the same order and prints the same lines. lifecycle/test.sh measures that.
# =============================================================================
#
# USAGE (run from anywhere)
#   bash lifecycle/create-github-app.sh <config> [organisation]
#
# THE TWO INPUTS
#   config        — the installation's own key=value file, the one
#                   install-machine.sh is given and in the same grammar. Read
#                   for CATALOG_REPO and UNIT_APEX and never run. The three
#                   answers GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID and
#                   GITHUB_APP_PRIVATE_KEY are written into it in place.
#   organisation  — the GitHub organisation the App is created in and installed
#                   on. Defaults to the owner of CATALOG_REPO, because that is
#                   the customer's organisation the tenant repositories live in.
#
# WHAT GITHUB ALLOWS, AND WHY TWO CLICKS STAY. No API creates an App from
# nothing. The App Manifest flow is the closest: a browser posts a manifest —
# the name, the homepage, the address to send the browser back to, the six
# repository permissions, no webhook — to the organisation's new-App page, the
# person clicks Create GitHub App ONCE, GitHub sends the browser back with a
# temporary code, and one unauthenticated request turns that code into the App:
# its id, its slug, its private key. No API installs an App on an organisation
# either: the person opens the App's installation page and clicks Install with
# All repositories, the second and last click. From then on the App's own JWT,
# signed with the key, can ask GitHub for that installation and its id.
#
# THE ORDER IS READ, GUARD, CREATE, WRITE, INSTALL, WRITE. The config is asked
# whether it already carries the answers and whether anybody but the owner can
# read it BEFORE the browser opens, because the private key lands in that file:
# a file refused after the App exists would leave an App on GitHub whose key no
# file holds. The two answers the creation gives, the id and the key, are
# written the moment the App stands and before the installation is asked for.
# The key exists in this run's memory and in that file and nowhere else, so a
# run that ends between the two clicks leaves a config a second run picks up:
# it finds the id and the key, skips the creation, and installs. A config
# carrying all three refuses, so every run of this is safe to repeat.
#
# THE LISTENER is one perl process on 127.0.0.1 at a port the system picks,
# and perl because it is the one interpreter Git Bash, Linux and macOS all
# carry with a socket module. It serves the manifest page, which submits itself,
# answers GitHub's redirect with one line, records the code, and exits. After
# ten minutes without the redirect it exits empty and this refuses.
#
# THE KEY TOUCHES DISK IN TWO PLACES: the config, and — for as long as it takes
# openssl to sign a JWT — a file in a temporary directory that nobody but the
# owner can reach, removed on every path this can end on. openssl reads a key
# from a file and not from a pipe, and on Git Bash process substitution hands
# the native openssl a path it cannot open.
#
# WHAT IS PRINTED IS ASCII, and that is not a typographic preference. The two
# spellings are held to printing the same bytes, and PowerShell writes its output
# in whatever code page the console carries -- so a dash from outside ASCII
# arrives there as a different byte and the pair quietly stops agreeing. The
# comments in these files are read by people and may say what they like.
# =============================================================================

set -uo pipefail

die() { printf 'create-github-app: %s\n' "$1" >&2; exit "${2:-65}"; }
say() { printf '%s\n' "$1"; }

CONFIG="${1:-}"
ORG="${2:-}"
[ $# -le 2 ] || die "lifecycle/create-github-app.sh was given more than it takes: $3" 64
[ -n "$CONFIG" ] || die 'usage: lifecycle/create-github-app.sh <config> [organisation]' 64

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for tool in curl openssl perl; do
  command -v "$tool" >/dev/null 2>&1 \
    || die "$tool is not on this path, and this act is curl against GitHub, openssl signing the App's JWT and perl listening for the browser"
done
# shellcheck disable=SC1091
. "$HERE/require-owner-only.sh" \
  || die 'require-owner-only.sh is not beside this file. It is the guard every launcher puts on a config' 66
[ -r "$CONFIG" ] \
  || die "there is no config at $CONFIG. It is the installation's own, the one install-machine is given: name it as the first argument" 66

# THE VALUE OF ONE KEY of the config, READ AND NEVER EXECUTED. A shell `.` runs
# every line, and two values are all this reads out of a file that carries
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
# THE LINE IS REPLACED WHERE IT STANDS AND APPENDED ONLY WHERE THE FILE HAS NONE,
# and the file is truncated where it stands rather than replaced by a copy: a
# copy would carry the copy's access list, and the guard below asks for the
# file's own.
write_config_value() { # KEY, value -> KEY='value' rewritten in place, appended when absent
  local key="$1" value="$2" line i found=0
  local -a lines=()
  while IFS= read -r line || [ -n "$line" ]; do lines+=("$line"); done < "$CONFIG"
  for ((i = 0; i < ${#lines[@]}; i++)); do
    case "${lines[$i]}" in
      "$key="*) lines[$i]="$key='$value'"; found=1; break ;;
    esac
  done
  [ "$found" = '1' ] || lines+=("$key='$value'")
  : > "$CONFIG"
  for line in "${lines[@]}"; do printf '%s\n' "$line" >> "$CONFIG"; done
}
make_owner_only() { # a file -> nobody but the owner reaches it, in this platform's own words
  if [ -n "${MSYSTEM:-}" ] || [ "$(uname -o 2>/dev/null)" = 'Msys' ]; then
    icacls "$(cygpath -aw "$1")" /inheritance:r /grant:r "${USERNAME:-$(stat -c '%U' "$1")}:(F)" >/dev/null
  else
    chmod 600 "$1"
  fi
}
# THE BROWSER IS $BROWSER WHERE IT IS SET, the way gh reads it, and the
# platform's own opener otherwise: start on Git Bash, open on macOS, xdg-open
# on Linux. Each returns once the browser was asked, and the listener is
# already standing when it is.
open_in_browser() { # a URL -> 0 when a browser was asked to open it
  if [ -n "${BROWSER:-}" ]; then "$BROWSER" "$1"; return; fi
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) start '' "$1" ;;
    Darwin) open "$1" ;;
    *) xdg-open "$1" ;;
  esac
}

# ================================================================== READ
# THE THREE ANSWERS DECIDE WHAT THIS RUN IS: none of them stands and the App is
# created; the id and the key stand and the App is installed; all three stand
# and nothing is done. Any other mix cannot be told apart from a hand-filled
# mistake and is refused.
APP_ID="$(config_value GITHUB_APP_ID)"
INSTALLATION_ID="$(config_value GITHUB_APP_INSTALLATION_ID)"
PEM_JSON="$(config_value GITHUB_APP_PRIVATE_KEY)"
if [ -n "$APP_ID" ] && [ -n "$INSTALLATION_ID" ] && [ -n "$PEM_JSON" ]; then
  die "$CONFIG already carries GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID and GITHUB_APP_PRIVATE_KEY. Nothing has been changed" 65
elif [ -n "$APP_ID" ] && [ -n "$PEM_JSON" ] && [ -z "$INSTALLATION_ID" ]; then
  APP_STANDS=yes
elif [ -z "$APP_ID" ] && [ -z "$PEM_JSON" ] && [ -z "$INSTALLATION_ID" ]; then
  APP_STANDS=no
else
  CARRIED=''; MISSING=''
  for key in GITHUB_APP_ID GITHUB_APP_INSTALLATION_ID GITHUB_APP_PRIVATE_KEY; do
    if [ -n "$(config_value "$key")" ]; then CARRIED="$CARRIED, $key"; else MISSING="$MISSING, $key"; fi
  done
  die "$CONFIG carries ${CARRIED#, } and not ${MISSING#, }, and this act cannot tell which App they belong to. Empty all three to create an App, or fill all three by hand. Nothing has been changed" 65
fi

if [ -n "$ORG" ]; then
  ORG_FROM='named as the second argument'
else
  CATALOG_REPO="$(config_value CATALOG_REPO)"
  [ -n "$CATALOG_REPO" ] \
    || die "$CONFIG states no CATALOG_REPO, and the organisation the App is created in is its owner: state it, or name the organisation as the second argument" 65
  ORG="${CATALOG_REPO%%/*}"
  ORG_FROM="the owner of CATALOG_REPO in $CONFIG"
fi
[[ "$ORG" =~ ^[A-Za-z0-9-]+$ ]] \
  || die "'$ORG' is not a GitHub organisation name, which is letters, digits and hyphens" 65
UNIT_APEX="$(config_value UNIT_APEX)"
[ -n "$UNIT_APEX" ] \
  || die "$CONFIG states no UNIT_APEX, and the App's homepage is https://manager.<unit apex>" 65
APP_NAME="$ORG-platform-manager"
HOMEPAGE="https://manager.$UNIT_APEX"

# ================================================================= GUARD
# ASKED BEFORE THE BROWSER OPENS: the private key lands in this file.
require_owner_only "$CONFIG" \
  || die "$CONFIG $REACH and is where the App's private key lands. Run: $OWNER_ONLY_COMMAND. Nothing has been changed" 77

GITHUB='https://github.com'
GITHUB_API='https://api.github.com'
# The six repository permissions the Manager creates and drives a tenant's own
# apps repository with, as GitHub spells them, in byte order.
PERMISSIONS='actions:write administration:write contents:write metadata:read webhooks:write workflows:write'
WAIT_SECONDS=600
POLL_SECONDS=5

WORK="$(mktemp -d)"
LISTENER=''
trap '[ -n "$LISTENER" ] && kill "$LISTENER" 2>/dev/null; rm -rf "$WORK"' EXIT

# ONE CALL TO THE API: the JWT rides the Authorization header, handed to curl
# through a config on its standard input so it stands in no argument list. The
# status rides behind the body on a line of its own, because a 404 is an answer
# here (not installed yet) and not a failure.
RE_MESSAGE='"message":"([^"]*)"'
gh_api() { # method, path, [JWT] -> BODY and STATUS; 1 with WHY when GitHub could not be reached
  local method="$1" path="$2" jwt="${3:-}" answer rc
  if [ -n "$jwt" ]; then
    answer="$(printf 'header = "Authorization: Bearer %s"\n' "$jwt" \
      | curl -sS -K - -X "$method" -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' -w '\n%{http_code}' "$GITHUB_API$path" 2>&1)"
  else
    answer="$(curl -sS -X "$method" -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' -w '\n%{http_code}' "$GITHUB_API$path" 2>&1)"
  fi
  rc=$?
  if [ "$rc" -ne 0 ]; then
    WHY="GitHub could not be reached for $method $path (curl exit $rc: $(printf '%s' "$answer" | tr '\n' ' '))"
    return 1
  fi
  STATUS="${answer##*$'\n'}"
  BODY="${answer%$'\n'*}"
  MESSAGE=''
  [[ $BODY =~ $RE_MESSAGE ]] && MESSAGE=": ${BASH_REMATCH[1]}"
  return 0
}
# THE APP'S OWN JWT: RS256 over {iat, exp, iss}, iss being the App id, dated a
# minute into the past because GitHub refuses a token ahead of its own clock,
# and nine minutes long under GitHub's ten-minute ceiling. The same shape the
# Manager mints.
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
app_jwt() { # -> the JWT; 1 when openssl does not read KEYFILE as a private key
  local now header payload signature
  now="$(date +%s)"
  header="$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)"
  payload="$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$((now - 60))" "$((now + 540))" "$APP_ID" | b64url)"
  signature="$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -sign "$KEYFILE" 2>/dev/null | b64url)" || return 1
  [ -n "$signature" ] || return 1
  printf '%s.%s.%s\n' "$header" "$payload" "$signature"
}
write_key_file() { # PEM_JSON, one line with \n for each line break -> KEYFILE holds the PEM, owner-only
  KEYFILE="$WORK/app.pem"
  : > "$KEYFILE"
  make_owner_only "$KEYFILE"
  printf '%s' "${PEM_JSON//'\n'/$'\n'}" > "$KEYFILE"
}
# The App's id and html_url stand at the top of GitHub's answer, and so do the
# owner's under `owner`: that object is cut out before the first match is read.
RE_ID='"id":([0-9]+)'
RE_SLUG='"slug":"([^"]+)"'
RE_HTML_URL='"html_url":"([^"]+)"'
RE_PEM='"pem":"([^"]+)"'
RE_PERMISSIONS='"permissions":\{([^}]*)\}'
RE_SELECTION='"repository_selection":"([a-z]+)"'
field() { [[ $2 =~ $1 ]] && printf '%s' "${BASH_REMATCH[1]}"; } # regex, text -> the group; 1 when the text does not carry it
without_object() { printf '%s' "$2" | sed "s/\"$1\":{[^}]*}//"; } # key, json -> the json with that object cut out

# ================================================================ CREATE
if [ "$APP_STANDS" = no ]; then
  say "create-github-app: the App $APP_NAME is created in the organisation $ORG, $ORG_FROM, with its homepage $HOMEPAGE"
  NONCE="$(openssl rand -hex 16)"
  LISTEN="$WORK/listen"
  mkdir -p "$LISTEN"
  perl - "$LISTEN" "$WAIT_SECONDS" <<'PERL' &
use strict;
use warnings;
use IO::Socket::INET;
use IO::Select;
my ($dir, $wait) = @ARGV;
my $server = IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => 0, Proto => 'tcp', Listen => 5, ReuseAddr => 1);
unless ($server) { open(my $e, '>', "$dir/error") or exit 1; print $e "$!\n"; close $e; exit 1 }
open(my $p, '>', "$dir/port") or exit 1; print $p $server->sockport, "\n"; close $p;
sub answer {
  my ($client, $status, $type, $body) = @_;
  print $client "HTTP/1.1 $status\r\nContent-Type: $type\r\nContent-Length: " . length($body) . "\r\nConnection: close\r\n\r\n$body";
  close $client;
}
my $deadline = time + $wait;
my $waiting = IO::Select->new($server);
while (time < $deadline) {
  next unless $waiting->can_read($deadline - time);
  my $client = $server->accept or next;
  # The request line is what is read; a connection that sends nothing within
  # five seconds (a browser opening one ahead of need) is dropped.
  my $arriving = IO::Select->new($client);
  my $request = '';
  while ($request !~ /\r?\n\r?\n/ && length($request) < 65536) {
    last unless $arriving->can_read(5);
    my $read = sysread($client, my $chunk, 4096);
    last unless $read;
    $request .= $chunk;
  }
  if ($request =~ m{^GET /\?(\S*code=\S*) HTTP/}) {
    open(my $q, '>', "$dir/query") or exit 1; print $q "$1\n"; close $q;
    answer($client, '200 OK', 'text/html; charset=utf-8', '<!DOCTYPE html><html><head><meta charset="utf-8"><title>done</title></head><body>done, back to the terminal</body></html>');
    exit 0;
  }
  if ($request =~ m{^GET /(\?\S*)? HTTP/}) {
    open(my $f, '<', "$dir/page.html") or exit 1; my $page = do { local $/; <$f> }; close $f;
    answer($client, '200 OK', 'text/html; charset=utf-8', $page);
    next;
  }
  answer($client, '404 Not Found', 'text/plain', 'not the page this run serves');
}
exit 1;
PERL
  LISTENER=$!
  i=0
  while [ $i -lt 50 ] && [ ! -s "$LISTEN/port" ]; do sleep 0.1; i=$((i + 1)); done
  [ -s "$LISTEN/port" ] \
    || die "no listener could be opened on 127.0.0.1, so GitHub would have nowhere to send the browser back to: $(cat "$LISTEN/error" 2>/dev/null). Nothing has been changed" 69
  PORT="$(cat "$LISTEN/port")"
  PAGE_URL="http://127.0.0.1:$PORT/"
  # THE MANIFEST, and the page that posts it. The page submits itself, so the
  # one click a person makes is GitHub's own Create GitHub App; the button is
  # there for a browser that runs no script. The JSON stands in a single-quoted
  # attribute, so what is escaped is what a single-quoted attribute cannot hold.
  DEFAULT_PERMISSIONS=''
  for pair in $PERMISSIONS; do DEFAULT_PERMISSIONS="$DEFAULT_PERMISSIONS,\"${pair%%:*}\":\"${pair#*:}\""; done
  MANIFEST="{\"name\":\"$APP_NAME\",\"url\":\"$HOMEPAGE\",\"redirect_url\":\"$PAGE_URL\",\"public\":false,\"hook_attributes\":{\"active\":false},\"default_permissions\":{${DEFAULT_PERMISSIONS#,}}}"
  ATTRIBUTE="${MANIFEST//&/&amp;}"; ATTRIBUTE="${ATTRIBUTE//</&lt;}"; ATTRIBUTE="${ATTRIBUTE//\'/&#39;}"
  {
    printf '<!DOCTYPE html>\n<html><head><meta charset="utf-8"><title>Create the GitHub App %s</title></head>\n' "$APP_NAME"
    printf '<body onload="document.forms[0].submit()">\n'
    printf '<form method="post" action="%s/organizations/%s/settings/apps/new?state=%s">\n' "$GITHUB" "$ORG" "$NONCE"
    printf "<input type=\"hidden\" name=\"manifest\" value='%s'>\n" "$ATTRIBUTE"
    printf '<button type="submit">Create GitHub App</button>\n</form></body></html>\n'
  } > "$LISTEN/page.html"
  say "create-github-app: listening on 127.0.0.1 for GitHub to send the browser back, for up to 10 minutes"
  if open_in_browser "$PAGE_URL" >/dev/null 2>&1; then
    say "create-github-app: opened the manifest page in the browser; it posts to $GITHUB/organizations/$ORG/settings/apps/new. In the browser: click Create GitHub App"
  else
    say "create-github-app: no browser could be opened; open $PAGE_URL yourself. It posts to $GITHUB/organizations/$ORG/settings/apps/new. In the browser: click Create GitHub App"
  fi
  wait "$LISTENER"
  LISTENER=''
  [ -s "$LISTEN/query" ] \
    || die 'GitHub did not send the browser back within 10 minutes. Nothing has been written' 69
  CODE=''; STATE=''
  IFS='&' read -r -a PAIRS < "$LISTEN/query"
  for pair in ${PAIRS[@]+"${PAIRS[@]}"}; do
    case "$pair" in code=*) CODE="${pair#code=}" ;; state=*) STATE="${pair#state=}" ;; esac
  done
  [ "$STATE" = "$NONCE" ] \
    || die "GitHub sent the browser back with a state that is not this run's, so the code is not trusted. Nothing has been written" 65
  [ -n "$CODE" ] || die 'GitHub sent the browser back without a code. Nothing has been written' 65
  say "create-github-app: GitHub sent the browser back with a code, and the state is this run's"

  # THE CODE BECOMES THE APP in one unauthenticated request. The answer carries
  # the key and two more secrets, so no part of it is printed.
  gh_api POST "/app-manifests/$CODE/conversions" || die "$WHY. Nothing has been written" 69
  [ "$STATUS" = 201 ] \
    || die "GitHub refused to turn the code into an App (HTTP $STATUS$MESSAGE). Nothing has been written" 69
  APP="$(without_object owner "$BODY")"
  APP_ID="$(field "$RE_ID" "$APP")" || die "GitHub's answer to the conversion carries no id, so the App cannot be recorded. Nothing has been written" 69
  SLUG="$(field "$RE_SLUG" "$APP")" || die "GitHub's answer to the conversion carries no slug, so the App cannot be recorded. Nothing has been written" 69
  HTML_URL="$(field "$RE_HTML_URL" "$APP")" || die "GitHub's answer to the conversion carries no html_url, so the App cannot be recorded. Nothing has been written" 69
  PEM_JSON="$(field "$RE_PEM" "$BODY")" || die "GitHub's answer to the conversion carries no pem, so the App at $HTML_URL has no key this can write. Delete it there and run this again. Nothing has been written" 69
  ANSWERED="$(field "$RE_PERMISSIONS" "$APP")" || die "GitHub's answer to the conversion names no permissions, so the App at $HTML_URL cannot be held to the six asked. Delete it there and run this again. Nothing has been written" 69
  GOT="$(printf '%s' "$ANSWERED" | tr ',' '\n' | tr -d '" ' | LC_ALL=C sort | tr '\n' ' ')"
  GOT="${GOT% }"
  [ "$GOT" = "$PERMISSIONS" ] \
    || die "the App was created at $HTML_URL with the permissions $GOT and not the six asked: $PERMISSIONS. Delete it there and run this again. Nothing has been written" 65
  say "create-github-app: the App stands at $HTML_URL (id $APP_ID) with the six permissions $GOT"

  # ================================================================= WRITE
  write_config_value GITHUB_APP_ID "$APP_ID"
  write_config_value GITHUB_APP_PRIVATE_KEY "$PEM_JSON"
  require_owner_only "$CONFIG" \
    || die "$CONFIG $REACH now that it carries the App's private key. Run: $OWNER_ONLY_COMMAND" 77
  say "create-github-app: GITHUB_APP_ID and GITHUB_APP_PRIVATE_KEY written into $CONFIG in place"
else
  say "create-github-app: $CONFIG carries GITHUB_APP_ID and GITHUB_APP_PRIVATE_KEY and no GITHUB_APP_INSTALLATION_ID, so the App stands and this run installs it"
fi

# =============================================================== INSTALL
STANDS="The App stands, and $CONFIG carries GITHUB_APP_ID and GITHUB_APP_PRIVATE_KEY"
write_key_file
if [ "$APP_STANDS" = yes ]; then
  # THE APP IS ASKED FOR ITSELF, so the slug is GitHub's and the key is proven
  # to belong to the id the config states before a person is sent to install.
  JWT="$(app_jwt)" || die "the key in $CONFIG is not a private key this can sign a JWT with. Nothing has been changed" 65
  gh_api GET /app "$JWT" || die "$WHY. Nothing has been changed" 69
  [ "$STATUS" = 200 ] \
    || die "GitHub does not answer an App for the key in $CONFIG (HTTP $STATUS$MESSAGE). Nothing has been changed" 69
  APP="$(without_object owner "$BODY")"
  ANSWERED_ID="$(field "$RE_ID" "$APP")" || die "GitHub's answer for the App carries no id. Nothing has been changed" 69
  [ "$ANSWERED_ID" = "$APP_ID" ] \
    || die "GitHub answers App $ANSWERED_ID for the key in $CONFIG, and the config states GITHUB_APP_ID='$APP_ID'. Nothing has been changed" 65
  SLUG="$(field "$RE_SLUG" "$APP")" || die "GitHub's answer for the App carries no slug. Nothing has been changed" 69
  HTML_URL="$(field "$RE_HTML_URL" "$APP")" || die "GitHub's answer for the App carries no html_url. Nothing has been changed" 69
  say "create-github-app: the App stands at $HTML_URL (id $APP_ID)"
else
  app_jwt >/dev/null || die "the App's key is not a private key this can sign a JWT with. $STANDS" 65
fi
INSTALL_URL="$GITHUB/apps/$SLUG/installations/new"
SETTINGS="$GITHUB/organizations/$ORG/settings/installations"
if open_in_browser "$INSTALL_URL" >/dev/null 2>&1; then
  say "create-github-app: opened $INSTALL_URL in the browser. In the browser: choose All repositories and click Install"
else
  say "create-github-app: no browser could be opened; open $INSTALL_URL yourself. There: choose All repositories and click Install"
fi
say "create-github-app: asking GitHub every $POLL_SECONDS seconds whether the App is installed in $ORG, for up to 10 minutes"
DEADLINE=$(( $(date +%s) + WAIT_SECONDS ))
while :; do
  JWT="$(app_jwt)" || die "the App's key is not a private key this can sign a JWT with. $STANDS" 65
  gh_api GET "/orgs/$ORG/installation" "$JWT" || die "$WHY. $STANDS: install it at $INSTALL_URL with All repositories and run this again" 69
  case "$STATUS" in
    200) break ;;
    404) ;;
    *) die "GitHub answered HTTP $STATUS$MESSAGE when asked whether the App is installed in $ORG. $STANDS: install it at $INSTALL_URL with All repositories and run this again" 69 ;;
  esac
  [ "$(date +%s)" -lt "$DEADLINE" ] \
    || die "the App was not installed in $ORG within 10 minutes. $STANDS: install it at $INSTALL_URL with All repositories and run this again" 69
  sleep "$POLL_SECONDS"
done
INSTALLATION="$(without_object account "$BODY")"
INSTALLATION_ID="$(field "$RE_ID" "$INSTALLATION")" || die "GitHub's answer for the installation in $ORG carries no id. $STANDS: run this again" 69
SELECTION="$(field "$RE_SELECTION" "$INSTALLATION")" || die "GitHub's answer for the installation in $ORG carries no repository_selection. $STANDS: run this again" 69
[ "$SELECTION" = all ] \
  || die "the App is installed in $ORG with repository_selection $SELECTION, and the Manager needs all. Choose All repositories at $SETTINGS/$INSTALLATION_ID, then run this again: $STANDS, and the next run writes GITHUB_APP_INSTALLATION_ID" 65
say "create-github-app: installed in $ORG on all repositories, installation $INSTALLATION_ID: $SETTINGS/$INSTALLATION_ID"

# ================================================================= WRITE
write_config_value GITHUB_APP_INSTALLATION_ID "$INSTALLATION_ID"
require_owner_only "$CONFIG" \
  || die "$CONFIG $REACH now that it carries the App's private key. Run: $OWNER_ONLY_COMMAND" 77
say "create-github-app: GITHUB_APP_INSTALLATION_ID written into $CONFIG in place"
say "create-github-app: $CONFIG carries GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID and GITHUB_APP_PRIVATE_KEY, and nobody but the owner can read it. The App: $HTML_URL. Its installation: $SETTINGS/$INSTALLATION_ID"
