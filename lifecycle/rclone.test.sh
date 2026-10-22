#!/usr/bin/env bash
# ===========================================================================
# rclone.test.sh — the rclone that master-backup and master-restore run: how a machine is given it, and what it does.
#
#   bash lifecycle/rclone.test.sh        (lifecycle/test.sh runs it)
#
# PART A, THE PROVISIONING, against stand-ins of sudo, dpkg, curl and rclone. The pin and the two package rows are read from
# a copy of this tree with the digests of two fixture packages, by the launchers' own reader, which is held to yq and to
# scripts/list-mirror-sources.sh. Each launcher is run against a stand-in ssh that keeps what it sends, and the program
# it sent (the config, require-rclone.sh, the metadata and, for a restore, the carried package) is what the cases run:
# the driver is cut off the end of it and require_rclone is called in its place.
#
# PART B, THE EXECUTABLES, against the real packages. The pinned release is fetched through require_rclone itself, from the
# owned addresses of the two rows, and extracted; the two packages that produced the defect are fetched from the places
# that publish them (Ubuntu 26.04's, which the master runs today, and Debian 12's, which the Manager's dbtools image
# runs), held to their sha256 and extracted. Nothing is installed on this machine. The pinned executable serves a file of
# 300 MiB, above rclone's multi-thread cutoff of 250 MiB, over SFTP on loopback at a port the kernel gives it, under
# credentials made for the run, and each executable copies it back, as the read-back of the master does.
# The planted defects of part A are copies of the helper, the reader and the launcher with one line changed; each must turn
# its case red, and the unchanged copy beside it must stay green.
# ===========================================================================
set -Eeuo pipefail
trap 'echo "rclone.test: RED — a command ended with status $? at line $LINENO of lifecycle/rclone.test.sh" >&2' ERR

fail() { echo "rclone.test: RED — $*" >&2; exit 1; }
ok() { echo "rclone.test: ok — $*"; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"
SERVERS=()
cleanup() {
  local pid
  for pid in ${SERVERS[@]+"${SERVERS[@]}"}; do kill "$pid" 2> /dev/null || true; done
  rm -rf "$WORK"
}
trap cleanup EXIT
export LC_ALL=C

command -v yq > /dev/null 2>&1 || fail 'yq is not on this path, and the pin and the rows are compared with its reading'
command -v python3 > /dev/null 2>&1 || fail 'python3 is not on this path, and the two production readers of cliTools are executed with it'
command -v dpkg-deb > /dev/null 2>&1 || fail 'dpkg-deb is not on this path, and the packages are extracted with it'

# ── the tree the launchers read: this one, with the digests of two fixture packages in the rclone rows ──
PIN="$(yq e '.cliTools.rclone.version' "$ROOT/clusters/platform/versions.yaml")"
[[ "$PIN" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "clusters/platform/versions.yaml states no cliTools.rclone.version of the form vX.Y.Z that yq can read: $PIN"
TREE="$WORK/tree"
mkdir -p "$TREE/lifecycle" "$TREE/clusters/platform" "$TREE/clusters/inventories/consumer-build/files" "$TREE/scripts"
for file in master-backup.sh master-restore.sh master-backup-driver.sh master-restore-driver.sh require-owner-only.sh require-config-assignments.sh \
  require-rclone.sh read-rclone-pin.sh config.example.env; do
  cp "$HERE/$file" "$TREE/lifecycle/$file"
done
cp "$ROOT/clusters/platform/versions.yaml" "$ROOT/clusters/platform/values-common.yaml" "$TREE/clusters/platform/"
cp "$ROOT/clusters/inventories/consumer-build/files/mirror-sources.sh" "$TREE/clusters/inventories/consumer-build/files/"
cp "$ROOT/scripts/list-mirror-sources.sh" "$TREE/scripts/"
printf 'fixture package of rclone %s for amd64\n' "$PIN" > "$WORK/fixture-amd64.deb"
printf 'fixture package of rclone %s for arm64, a different one\n' "$PIN" > "$WORK/fixture-arm64.deb"
DIGEST_AMD64="$(sha256sum "$WORK/fixture-amd64.deb" | cut -d' ' -f1)"
DIGEST_ARM64="$(sha256sum "$WORK/fixture-arm64.deb" | cut -d' ' -f1)"
write_table() { # <tree> — the platform's table with the rows of the two rclone packages at the digests of the fixture packages
  sed -e "s#^\\(tool [^ ]*/rclone/rclone/[^ ]*/rclone-$PIN-linux-amd64.deb\\) .*#\\1 $DIGEST_AMD64#" \
    -e "s#^\\(tool [^ ]*/rclone/rclone/[^ ]*/rclone-$PIN-linux-arm64.deb\\) .*#\\1 $DIGEST_ARM64#" \
    "$ROOT/clusters/platform/mirror-sources.table" > "$1/clusters/platform/mirror-sources.table"
}
write_table "$TREE"
[ "$(grep -c "^tool .*rclone-$PIN-linux-\(amd64\|arm64\).deb [0-9a-f]\{64\}$" "$TREE/clusters/platform/mirror-sources.table")" = 2 ] \
  || fail "the platform table has not exactly the two rows of the rclone $PIN packages that this test puts its fixture digests in"

# ── A1: the reader of the launchers is the reader of yq and of scripts/list-mirror-sources.sh ──
rows_by_list() { # <tree> — "<arch> <sha256> <address>" for the rclone rows, as scripts/list-mirror-sources.sh derives them
  bash "$1/scripts/list-mirror-sources.sh" "$1/clusters/platform/mirror-sources.table" \
    | awk -v pin="$PIN" '$1 == "tool" && $2 ~ ("/rclone-" pin "-linux-(amd64|arm64)[.]deb$") { arch = $2; sub(/.*linux-/, "", arch); sub(/[.]deb$/, "", arch); print arch, $3, $5 }' | sort
}
reads_as() { # <reader file> <tree> — runs the reader of the launchers; prints "<pin>" then the rows, or its error
  ( . "$1" && if read_rclone_pin "$2"; then printf '%s\n' "$RCLONE_PIN"; printf '%s\n' "$RCLONE_ROWS" | sort; else printf 'ERROR %s\n' "$RCLONE_METADATA_ERROR"; fi )
}
reader_agrees() { # <reader file> <tree> — ends 0 when the reader gives the pin of yq and the rows of the list
  local got want
  got="$(reads_as "$1" "$2")"
  want="$(printf '%s\n' "$(yq e '.cliTools.rclone.version' "$2/clusters/platform/versions.yaml")"; rows_by_list "$2")"
  [ "$got" = "$want" ]
}
reader_agrees "$TREE/lifecycle/read-rclone-pin.sh" "$TREE" || fail "the reader of the launchers does not give the pin of yq and the rows of scripts/list-mirror-sources.sh: $(reads_as "$TREE/lifecycle/read-rclone-pin.sh" "$TREE" | cut -c1-300)"
reader_agrees "$HERE/read-rclone-pin.sh" "$ROOT" || fail 'the reader of the launchers does not give the pin of yq and the rows of scripts/list-mirror-sources.sh on this tree itself'
[ "$(rows_by_list "$ROOT" | wc -l | tr -d ' ')" = 2 ] || fail 'scripts/list-mirror-sources.sh does not derive exactly two rows for the pinned rclone on this tree'
sed 's#rclone-\$RCLONE_PIN-linux-\$arch.deb#rclone-$RCLONE_PIN-linux-amd64.deb#' "$HERE/read-rclone-pin.sh" > "$WORK/reader-wrong-row.sh"
! cmp -s "$WORK/reader-wrong-row.sh" "$HERE/read-rclone-pin.sh" || fail 'the planted reader that selects the amd64 row for every architecture was not made'
! reader_agrees "$WORK/reader-wrong-row.sh" "$TREE" || fail 'the planted reader that selects one row for both architectures agrees with the list — the comparison proves nothing'
shape_refused() { # <what is changed> <file under the tree> <sed expression> — the reader refuses the changed copy of the tree and agrees with the unchanged one
  local copy="$WORK/shape-tree" got
  rm -rf "$copy"; cp -R "$TREE" "$copy"
  sed -i.bak "$3" "$copy/$2"; rm -f "$copy/$2.bak"
  ! cmp -s "$copy/$2" "$TREE/$2" || fail "the planted tree with $1 was not made"
  got="$(reads_as "$TREE/lifecycle/read-rclone-pin.sh" "$copy")"
  case "$got" in ERROR*) ;; *) fail "the reader took a tree with $1: $(cut -c1-200 <<< "$got")" ;; esac
}
shape_refused 'a pin that is no vX.Y.Z' clusters/platform/versions.yaml 's#^    version: "v1.75.2"#    version: "1.75"#'
shape_refused 'the rclone row of one architecture missing' clusters/platform/mirror-sources.table "/linux-arm64.deb/d"
shape_refused 'a digest that is not hex' clusters/platform/mirror-sources.table "s#\\(linux-amd64.deb\\) $DIGEST_AMD64#\\1 ${DIGEST_AMD64%?}G#"
shape_refused 'no global.buildRegistry' clusters/platform/values-common.yaml 's#^  buildRegistry:#  buildRegistryX:#'
shape_refused 'two rows of the same package' clusters/platform/mirror-sources.table "s#^\\(tool .*linux-amd64.deb .*\\)\$#\\1\\
\\1#"
ok "the launchers' reader gives the pin $PIN of yq and the amd64 and arm64 rows that scripts/list-mirror-sources.sh derives, on this tree and on the copy with fixture digests; it refuses a pin that is no vX.Y.Z, a missing row, a digest that is not hex, a missing registry and a doubled row; a reader that selects one row for both architectures is caught"

# ── A2: the two production readers of cliTools still find the ansiwise pin, and the rclone entry stands where they read ──
cliTools_read() { # <versions.yaml> <entry> — ends 0 when the two regular expressions of driver.sh and of regenerate-driver.sh, executed as they stand there, find the entry's version where yq does
  python3 -I - "$1" "$2" "$HERE" << 'PY'
from pathlib import Path
import re, subprocess, sys
path, entry, here = sys.argv[1], sys.argv[2], sys.argv[3]
text = Path(path).read_text()
want = subprocess.check_output(['yq', 'e', '.cliTools.%s.version' % entry, path], text=True).strip()
assert want and want != 'null', entry
for name in ['driver.sh', 'regenerate-driver.sh']:
    lines = [l for l in Path(here, name).read_text().splitlines() if l.startswith(('block = re.search(', 'found = re.search('))]
    assert len(lines) == 2, name
    lines = [l.replace('  ansiwise:', '  %s:' % entry) for l in lines]
    scope = {'re': re, 'text': text}
    exec('\n'.join(lines), scope)
    if not (scope['found'] and scope['found'].group(1) == want):
        sys.exit(1)
PY
}
for entry in ansiwise rclone; do
  cliTools_read "$ROOT/clusters/platform/versions.yaml" "$entry" || fail "the production readers of cliTools in driver.sh and regenerate-driver.sh do not find the $entry version of clusters/platform/versions.yaml where yq does"
done
awk '/^  rclone:$/ && !done { print "# a comment at column zero stops the block both readers cut out of cliTools"; done = 1 } { print }' "$ROOT/clusters/platform/versions.yaml" > "$WORK/versions-column-zero.yaml"
awk '/^  rclone:$/ && !done { print "  # an indented comment stays inside the block"; done = 1 } { print }' "$ROOT/clusters/platform/versions.yaml" > "$WORK/versions-indented.yaml"
! cliTools_read "$WORK/versions-column-zero.yaml" rclone || fail 'a comment at column zero before the rclone entry did not hide it from the production readers — the check proves nothing'
cliTools_read "$WORK/versions-indented.yaml" rclone || fail 'an indented comment before the rclone entry hid it from the production readers'
cliTools_read "$WORK/versions-indented.yaml" ansiwise || fail 'an indented comment before the rclone entry changed the ansiwise pin the production readers find'
ok 'the two production readers of cliTools (driver.sh, regenerate-driver.sh) find both the ansiwise and the rclone version where yq does; a comment at column zero before the rclone entry hides it and is caught, an indented one does not'

# ── A3: the program a launcher sends ──
SD="$WORK/standin"
mkdir -p "$SD/bin" "$SD/mirror" "$SD/tmp"
cat > "$SD/bin/sudo" << 'STANDIN'
#!/usr/bin/env bash
# sudo as root() calls it: -S -p '' [-u USER] COMMAND...; reads the password line, logs the call, runs the command as the caller marked elevated.
here="$(dirname "$0")/.."
printf 'sudo %s\n' "$*" >> "$here/sudo.log"
shift 3
[ "$1" != -u ] || shift 2
IFS= read -r _
exec env -i PATH="$PATH" TMPDIR="$TMPDIR" STANDIN_ELEVATED=1 "$@"
STANDIN
cat > "$SD/bin/install" << 'STANDIN'
#!/usr/bin/env bash
# install without the ownership a caller who is not root cannot give.
args=(); while [ "$#" -gt 0 ]; do case "$1" in -o|-g) shift 2 ;; *) args+=("$1"); shift ;; esac; done
exec /usr/bin/install "${args[@]}"
STANDIN
cat > "$SD/bin/rclone" << 'STANDIN'
#!/usr/bin/env bash
here="$(dirname "$0")/.."
[ "${1:-}" = --version ] || { echo 'rclone stand-in: only --version is answered' >&2; exit 2; }
if [ -n "${STANDIN_ELEVATED:-}" ] && [ -f "$here/answer-root" ]; then cat "$here/answer-root"; else cat "$here/answer"; fi
STANDIN
cat > "$SD/bin/dpkg" << 'STANDIN'
#!/usr/bin/env bash
here="$(dirname "$0")/.."
printf 'dpkg %s\n' "$*" >> "$here/dpkg.log"
case "$1" in
  --print-architecture) cat "$here/arch" ;;
  -i) [ ! -e "$here/dpkg-fails" ] || { echo 'dpkg: error processing archive (stand-in)' >&2; exit 1; }
      cp "$here/rclone.stash" "$here/bin/rclone"
      cp "$here/answer-after" "$here/answer"; rm -f "$here/answer-root" ;;
  *) echo "dpkg stand-in: a call the helper does not make: $*" >&2; exit 2 ;;
esac
STANDIN
cat > "$SD/bin/curl" << 'STANDIN'
#!/usr/bin/env bash
# curl serving the mirror: the file mirror/<sha256> for the address .../blobs/sha256:<sha256>; every call is logged, an unknown address is a 404.
here="$(dirname "$0")/.."
printf 'curl %s\n' "$*" >> "$here/curl.log"
[ ! -e "$here/mirror-down" ] || { echo 'curl: (6) Could not resolve host (stand-in)' >&2; exit 6; }
out=''; url=''
while [ "$#" -gt 0 ]; do case "$1" in --output) out="$2"; shift 2 ;; --connect-timeout|--max-time) shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac; done
digest="${url##*/blobs/sha256:}"
[ -f "$here/mirror/$digest" ] || { echo 'curl: (22) The requested URL returned error: 404' >&2; exit 22; }
cp "$here/mirror/$digest" "$out"
STANDIN
chmod +x "$SD/bin/"*
cp "$SD/bin/rclone" "$SD/rclone.stash"
SD_PATH="$SD/bin:/usr/bin:/bin"

cat > "$WORK/config.env" << 'EOF'
FQDN='master.example.invalid'
OPERATOR_USER='op'
STAGE='prod'
ELEVATION_PASSWORD='planted-elevation-password'
STORAGE_BOX_HOST='box.example.invalid'
STORAGE_BOX_USER='boxuser'
STORAGE_BOX_PASSWORD='planted-box-password'
BACKUP_PASSPHRASE='planted-passphrase'
PLATFORM_REPO='acme/cloud'
PLATFORM_BRANCH='master'
PLATFORM_REPO_READ_PAT='planted-token'
EOF
chmod 600 "$WORK/config.env"
cat > "$SD/bin/ssh" << 'STANDIN'
#!/usr/bin/env bash
# ssh as the launchers call it: a probe (last argument "true") answers 0; the session keeps the program it is sent and its arguments.
here="$(dirname "$0")/.."
last=''; for last; do :; done
[ "$last" != true ] || exit 0
printf '%s\n' "$last" > "$here/session-command"
cat > "$here/session-stream"
exit "${STANDIN_SSH_EXIT:-0}"
STANDIN
chmod +x "$SD/bin/ssh"

send() { # <lifecycle folder> backup|restore [launcher arguments after the config...] — runs the launcher against the stand-in ssh; its code stands in $SEND_CODE, the program it sent in $SD/session-stream
  local dir="$1" act="$2"
  shift 2
  rm -f "$SD/session-stream" "$SD/session-command"
  SEND_CODE=0
  ( cd "$WORK" && PATH="$SD_PATH" bash "$dir/master-$act.sh" "$WORK/config.env" "$@" ) > "$WORK/send.out" 2> "$WORK/send.err" || SEND_CODE=$?
}
metadata_by_yq() { # <tree> — the metadata the launchers must send, made from yq and scripts/list-mirror-sources.sh
  printf "AW_RCLONE_PIN='%s'\nAW_RCLONE_ROWS='%s'\n" "$(yq e '.cliTools.rclone.version' "$1/clusters/platform/versions.yaml")" "$(rows_by_list "$1" | sort -k1,1 | tr '\n' '\001' | sed 's/\x01$//' | tr '\001' '\n')"
}
expected_program() { # <lifecycle folder> <driver name> — the program a launcher must send, put together here from the files and from yq
  local dir="$1" driver="$2"
  printf 'umask 077\ncat > "$1" <<%sAW_CONFIG_END%s\n' "'" "'"
  cat "$WORK/config.env"
  printf 'AW_CONFIG_END\n'
  cat "$dir/require-rclone.sh"
  metadata_by_yq "$TREE"
  cat "$dir/$driver"
}
send "$TREE/lifecycle" backup
[ "$SEND_CODE" = 0 ] || fail "master-backup.sh against a stand-in ssh ended $SEND_CODE: $(tail -n 2 "$WORK/send.err" | tr '\n' ' ' | cut -c1-300)"
expected_program "$TREE/lifecycle" master-backup-driver.sh > "$WORK/expected-backup"
cmp -s "$SD/session-stream" "$WORK/expected-backup" \
  || fail "the program master-backup.sh sent is not the config, require-rclone.sh, the metadata of yq and the list, and the driver: $(cmp "$SD/session-stream" "$WORK/expected-backup" 2>&1 | head -n 1)"
grep -qF -- '-- "$HOME/.aw-backup.env"' "$SD/session-command" || fail 'master-backup.sh did not start the program it sent with the file for the config'
send "$TREE/lifecycle" restore 20261021T120000Z
[ "$SEND_CODE" = 0 ] || fail "master-restore.sh against a stand-in ssh ended $SEND_CODE: $(tail -n 2 "$WORK/send.err" | tr '\n' ' ' | cut -c1-300)"
expected_program "$TREE/lifecycle" master-restore-driver.sh > "$WORK/expected-restore"
cmp -s "$SD/session-stream" "$WORK/expected-restore" \
  || fail "the program master-restore.sh sent is not the config, require-rclone.sh, the metadata of yq and the list, and the driver: $(cmp "$SD/session-stream" "$WORK/expected-restore" 2>&1 | head -n 1)"
# a launcher that leaves the helper and the metadata out sends another program
rm -rf "$WORK/mutant-tree"; cp -R "$TREE" "$WORK/mutant-tree"
sed -i.bak -e '/< "\$RCLONE_HELPER"$/d' -e '/"\$RCLONE_METADATA"$/d' "$WORK/mutant-tree/lifecycle/master-backup.sh"; rm -f "$WORK/mutant-tree/lifecycle/master-backup.sh.bak"
! cmp -s "$WORK/mutant-tree/lifecycle/master-backup.sh" "$TREE/lifecycle/master-backup.sh" || fail 'the planted launcher that sends neither the helper nor the metadata was not made'
send "$WORK/mutant-tree/lifecycle" backup
! cmp -s "$SD/session-stream" "$WORK/expected-backup" || fail 'a master-backup.sh that sends neither the helper nor the metadata sent the same program — the comparison proves nothing'
ok 'master-backup.sh and master-restore.sh send, through the one ssh session, the config, require-rclone.sh byte for byte, the pin and the rows that yq and the list give, and the driver; a launcher that leaves the helper and the metadata out is caught'

# ── A4: the program is run: the driver is cut off its end and require_rclone is called in its place ──
program_of() { # <expected program file> <driver file> — everything the launcher sent before the driver
  head -c "$(( $(wc -c < "$1") - $(wc -c < "$2") ))" "$1"
}
program_of "$WORK/expected-backup" "$TREE/lifecycle/master-backup-driver.sh" > "$WORK/prefix-backup"
run_helper() { # <prefix file> — runs the program with a harness behind it; $SD/result holds the verdict, the logs stay in $SD
  { cat "$1"
    cat << 'HARNESS'
say() { printf '%s\n' "$*"; }
good() { printf 'ok %s\n' "$*"; }
ELEVATION_PASSWORD=planted-elevation-password
root() { printf '%s\n' "$ELEVATION_PASSWORD" | sudo -S -p '' "$@"; }
HARNESS_CODE=0
require_rclone || HARNESS_CODE=$?
printf 'CODE=%s\nREFUSAL=%s\n' "$HARNESS_CODE" "$RCLONE_REFUSAL" > "$AW_RESULT"
rclone_cleanup
HARNESS
  } > "$SD/program.sh"
  : > "$SD/curl.log"; : > "$SD/dpkg.log"; : > "$SD/sudo.log"; rm -f "$SD/result"
  ( cd "$SD" && env -i PATH="$SD_PATH" TMPDIR="$SD/tmp" HOME="$SD/home" AW_RESULT="$SD/result" bash -s -- "$SD/config.out" < "$SD/program.sh" ) > "$SD/program.out" 2> "$SD/program.err" || true
}
setup() { # <rclone: pinned|old|absent> [<root's answer: pinned|old>] — the machine before require_rclone: its architecture, its mirror, its dpkg and the rclone it has
  local state="$1" root="${2:-}"
  rm -rf "$SD/tmp" "$SD/mirror" "$SD/home"; mkdir -p "$SD/tmp" "$SD/mirror" "$SD/home"
  rm -f "$SD/bin/rclone" "$SD/dpkg-fails" "$SD/mirror-down" "$SD/answer-root" "$SD/arch"
  [ "$state" = absent ] || cp "$SD/rclone.stash" "$SD/bin/rclone"
  cp "$WORK/fixture-amd64.deb" "$SD/mirror/$DIGEST_AMD64"; cp "$WORK/fixture-arm64.deb" "$SD/mirror/$DIGEST_ARM64"
  echo amd64 > "$SD/arch"
  printf 'rclone %s\n- os/version: stand-in\n' "$PIN" > "$SD/answer-after"
  printf 'rclone %s\n- os/version: stand-in\n' "$PIN" > "$SD/answer"
  [ "$state" != old ] || echo 'rclone v1.60.1-DEV' > "$SD/answer"
  [ "$root" != old ] || echo 'rclone v1.60.1-DEV' > "$SD/answer-root"
}
verdict() { sed -n "s/^$1=//p" "$SD/result" 2> /dev/null; }
installed_calls() { grep -c '^dpkg -i ' "$SD/dpkg.log" || true; }
fetch_calls() { grep -c '^curl ' "$SD/curl.log" || true; }
leftovers() { find "$SD/tmp" -mindepth 1 | wc -l | tr -d ' '; }
OWNED_AMD64="https://zot.master.digitacloud.app/v2/simetrixch/github.com/rclone/rclone/releases/download/$PIN/rclone-$PIN-linux-amd64.deb/blobs/sha256:$DIGEST_AMD64"

case_correct() { # <prefix> — a machine whose rclone answers the pin to both accounts is left as it is, with no request
  setup pinned; run_helper "$1"
  [ "$(verdict CODE)" = 0 ] && [ "$(installed_calls)" = 0 ] && [ "$(fetch_calls)" = 0 ] && [ "$(leftovers)" = 0 ]
}
case_absent() { # <prefix> — a machine without rclone fetches the one package of its architecture from the owned address, checks it, installs it, and answers the pin
  setup absent; run_helper "$1"
  [ "$(verdict CODE)" = 0 ] && [ "$(installed_calls)" = 1 ] && [ "$(fetch_calls)" = 1 ] && [ "$(leftovers)" = 0 ] \
    && grep -qF -- "$OWNED_AMD64" "$SD/curl.log" && grep -Eq -- '--connect-timeout [1-9][0-9]* ' "$SD/curl.log" && grep -Eq -- '--max-time [1-9][0-9]* ' "$SD/curl.log" \
    && ! grep -qF -- ' https://github.com' "$SD/curl.log"
}
case_old() { # <prefix> — an old rclone is replaced like an absent one; the one whose root answers another version is as well
  setup old; run_helper "$1"
  [ "$(verdict CODE)" = 0 ] && [ "$(installed_calls)" = 1 ] && [ "$(fetch_calls)" = 1 ] || return 1
  setup pinned old; run_helper "$1"
  [ "$(verdict CODE)" = 0 ] && [ "$(installed_calls)" = 1 ] && [ "$(leftovers)" = 0 ]
}
case_bad_digest() { # <prefix> — a package whose bytes are not the row's is refused before it is installed, and nothing stays behind
  setup absent; echo 'not the package of the row' > "$SD/mirror/$DIGEST_AMD64"; run_helper "$1"
  [ "$(verdict CODE)" = 1 ] && [ "$(installed_calls)" = 0 ] && [[ "$(verdict REFUSAL)" == *"is not the rclone $PIN package for amd64"* ]] && [ "$(leftovers)" = 0 ]
}
case_failed_install() { setup absent; touch "$SD/dpkg-fails"; run_helper "$1"; [ "$(verdict CODE)" = 1 ] && [[ "$(verdict REFUSAL)" == *'could not be installed'* ]] && [ "$(leftovers)" = 0 ]; }
case_wrong_result() { # <prefix> — an installation after which rclone answers another version is refused
  setup old; echo 'rclone v1.60.1-DEV' > "$SD/answer-after"; run_helper "$1"
  [ "$(verdict CODE)" = 1 ] && [[ "$(verdict REFUSAL)" == *'after the installation'* ]] && [ "$(leftovers)" = 0 ]
}
case_architecture() { setup absent; echo s390x > "$SD/arch"; run_helper "$1"; [ "$(verdict CODE)" = 1 ] && [ "$(fetch_calls)" = 0 ] && [ "$(installed_calls)" = 0 ] && [[ "$(verdict REFUSAL)" == *'architecture'* ]]; }
case_mirror_down() { setup absent; touch "$SD/mirror-down"; run_helper "$1"; [ "$(verdict CODE)" = 1 ] && [ "$(installed_calls)" = 0 ] && [[ "$(verdict REFUSAL)" == *'could not be fetched'* ]] && [ "$(leftovers)" = 0 ]; }
case_upstream_address() { # <prefix> — an address that is not the owned address of the row is never requested
  sed "s#https://zot.master.digitacloud.app/v2/simetrixch/#https://github.com/#g" "$1" > "$SD/redirected-prefix"
  setup absent; run_helper "$SD/redirected-prefix"
  [ "$(verdict CODE)" = 1 ] && [ "$(fetch_calls)" = 0 ] && [ "$(installed_calls)" = 0 ]
}
for scenario in correct absent old bad_digest failed_install wrong_result architecture mirror_down upstream_address; do
  "case_$scenario" "$WORK/prefix-backup" || fail "the helper, as the backup launcher sent it, failed the case $scenario: $(cat "$SD/result" 2> /dev/null | tr '\n' ' ') $(cat "$SD/program.err" | head -n 3 | tr '\n' ' ') curl: $(cat "$SD/curl.log" | cut -c1-200 | head -n 2 | tr '\n' ' ') dpkg: $(cat "$SD/dpkg.log" | tr '\n' ' ')"
done
planted_helper() { # <name> <sed expression> <case> — a copy of the launcher's tree whose helper has one line changed sends a program that fails the case
  local name="$1" tree="$WORK/mutant-$1"
  rm -rf "$tree"; cp -R "$TREE" "$tree"
  sed -i.bak "$2" "$tree/lifecycle/require-rclone.sh"; rm -f "$tree/lifecycle/require-rclone.sh.bak"
  ! cmp -s "$tree/lifecycle/require-rclone.sh" "$TREE/lifecycle/require-rclone.sh" || fail "the planted helper $name was not made"
  send "$tree/lifecycle" backup
  expected_program "$tree/lifecycle" master-backup-driver.sh > "$tree/expected"
  program_of "$tree/expected" "$tree/lifecycle/master-backup-driver.sh" > "$tree/prefix"
  if "case_$3" "$tree/prefix"; then fail "the planted helper $name passed the case $3 — the case proves nothing"; fi
}
planted_helper skips-the-digest '/sha256sum -c --quiet/s#.*#true \&\& true >/dev/null 2>\&1 \\#' bad_digest
planted_helper accepts-the-old-executable 's#^rclone_is_pinned() {#rclone_is_pinned() { return 0#' old
planted_helper takes-any-address '/the address of the row for \$arch is not the owned address/s#.*#    || true#' upstream_address
planted_helper installs-without-the-answer-check '/after the installation rclone answers/s#.*#    || true; true#' wrong_result
ok 'the helper of the program the backup launcher sent (its driver cut off, require_rclone called in its place), run with stand-ins: a pinned rclone is left alone with no request; an absent one, an old one and one whose root answers another version are replaced from the owned address with finite connection and total limits and a package held to the row'"'"'s digest; a package of other bytes, a failed installation, a wrong result, an unsupported architecture, a mirror that cannot be reached and an address that is not the owned one are each refused, with no installation and no folder left behind; a helper that skips the digest, one that accepts the old executable, one that takes any address and one that does not read the answer afterwards are each caught'

# ── A5: the restore carries the package as data ──
CARRIED_TREE="$TREE"
send "$TREE/lifecycle" restore 20261021T120000Z --rclone-package "$WORK/fixture-amd64.deb"
[ "$SEND_CODE" = 0 ] || fail "master-restore.sh --rclone-package against a stand-in ssh ended $SEND_CODE: $(tail -n 2 "$WORK/send.err" | tr '\n' ' ' | cut -c1-300)"
cp "$SD/session-stream" "$WORK/carried-stream"
grep -qF -- "AW_RCLONE_CARRIED_ARCH='amd64'" "$WORK/carried-stream" || fail 'the program does not state the architecture of the package it carries'
grep -qF -- 'aw_rclone_carried_package() { base64 -d; } <<'"'"'AW_RCLONE_PACKAGE_END'"'"'' "$WORK/carried-stream" || fail 'the package is not carried as data behind a quoted delimiter'
[ "$(grep -c '^AW_RCLONE_PACKAGE_END$' "$WORK/carried-stream")" = 1 ] || fail 'the carried package is not closed once'
DRIVER_SIZE="$(wc -c < "$TREE/lifecycle/master-restore-driver.sh")"
head -c "$(( $(wc -c < "$WORK/carried-stream") - DRIVER_SIZE ))" "$WORK/carried-stream" > "$WORK/prefix-carried"
case_carried() { # <prefix> — a bare machine with no route to the mirror installs the package carried with the session, and fetches nothing
  setup absent; touch "$SD/mirror-down"; run_helper "$1"
  [ "$(verdict CODE)" = 0 ] && [ "$(installed_calls)" = 1 ] && [ "$(fetch_calls)" = 0 ] && [ "$(leftovers)" = 0 ]
}
case_carried_damaged() { # <prefix> — one character of the carried package changed in transit: refused by the digest before the installation
  awk 'damage == 1 { sub(/^./, ($0 ~ /^A/) ? "B" : "A"); damage = 2 } /^aw_rclone_carried_package\(\)/ { damage = 1 } { print }' "$1" > "$SD/damaged-prefix"
  cmp -s "$SD/damaged-prefix" "$1" && return 1
  setup absent; touch "$SD/mirror-down"; run_helper "$SD/damaged-prefix"
  [ "$(verdict CODE)" = 1 ] && [ "$(installed_calls)" = 0 ] && [ "$(fetch_calls)" = 0 ] && [[ "$(verdict REFUSAL)" == *'is not the rclone'* || "$(verdict REFUSAL)" == *'could not be read'* ]] && [ "$(leftovers)" = 0 ]
}
case_carried_architecture() { setup absent; echo arm64 > "$SD/arch"; run_helper "$1"; [ "$(verdict CODE)" = 1 ] && [ "$(installed_calls)" = 0 ] && [ "$(fetch_calls)" = 0 ] && [[ "$(verdict REFUSAL)" == *'carried with this restore is for amd64 and this machine is arm64'* ]]; }
case_carried_truncated() { # <prefix> — a session that ended inside the package runs nothing of what follows it: no installation, no request
  setup absent; head -c "$(( $(wc -c < "$1") * 6 / 10 ))" "$1" > "$SD/truncated-prefix"
  ( cd "$SD" && env -i PATH="$SD_PATH" TMPDIR="$SD/tmp" HOME="$SD/home" bash -s -- "$SD/config.out" < "$SD/truncated-prefix" ) > /dev/null 2>&1 || true
  [ "$(installed_calls)" = 0 ] && [ "$(fetch_calls)" = 0 ] && [ ! -e "$SD/bin/rclone" ]
}
: > "$SD/dpkg.log"; : > "$SD/curl.log"
for scenario in carried carried_damaged carried_architecture carried_truncated; do
  "case_$scenario" "$WORK/prefix-carried" || fail "the helper, as the restore launcher sent it with --rclone-package, failed the case $scenario: $(cat "$SD/result" 2> /dev/null | tr '\n' ' ') curl: $(wc -l < "$SD/curl.log") dpkg: $(tr '\n' ' ' < "$SD/dpkg.log")"
done
sed 's#^  if \[ -n "${AW_RCLONE_CARRIED_ARCH:-}" \]; then#  if false; then#' "$HERE/require-rclone.sh" > "$WORK/helper-ignores-carried.sh"
! cmp -s "$WORK/helper-ignores-carried.sh" "$HERE/require-rclone.sh" || fail 'the planted helper that ignores the carried package was not made'
rm -rf "$WORK/mutant-carried"; cp -R "$TREE" "$WORK/mutant-carried"; cp "$WORK/helper-ignores-carried.sh" "$WORK/mutant-carried/lifecycle/require-rclone.sh"
send "$WORK/mutant-carried/lifecycle" restore 20261021T120000Z --rclone-package "$WORK/fixture-amd64.deb"
head -c "$(( $(wc -c < "$SD/session-stream") - DRIVER_SIZE ))" "$SD/session-stream" > "$WORK/prefix-carried-mutant"
if case_carried "$WORK/prefix-carried-mutant"; then fail 'a helper that ignores the carried package passed the case of a bare machine with no route to the mirror — the case proves nothing'; fi
# the launcher refuses a package that is not the row's, before a session is opened
printf 'not the package\n' > "$WORK/not-the-package.deb"
send "$TREE/lifecycle" restore --rclone-package "$WORK/not-the-package.deb"
{ [ "$SEND_CODE" = 65 ] && [ ! -e "$SD/session-stream" ] && grep -qF -- 'is not the rclone' "$WORK/send.err"; } || fail "master-restore.sh sent a package that is not the row's, or refused it with another code than 65: $SEND_CODE $(tail -n 1 "$WORK/send.err" | cut -c1-200)"
send "$TREE/lifecycle" restore --rclone-package "$WORK/missing.deb"
{ [ "$SEND_CODE" = 65 ] && [ ! -e "$SD/session-stream" ]; } || fail "master-restore.sh did not refuse a package file that is not there: $SEND_CODE"
send "$TREE/lifecycle" restore 20261021T120000Z --rclone-package
[ "$SEND_CODE" = 64 ] || fail "master-restore.sh did not refuse --rclone-package without a file: $SEND_CODE"
ok 'master-restore.sh --rclone-package, with or without a backup id, sends the package as data behind a quoted delimiter and the program installs it on a bare machine with no route to the mirror without one request; a package changed in transit, one for another architecture and a session cut inside the package install nothing; the launcher refuses a file that is not the row'"'"'s or not there before it opens a session; a helper that ignores the carried package is caught'

# ── A6: the launcher holds the carried package to the table with a tool an operator machine has ──
# A macOS operator machine has openssl and shasum and no sha256sum. Its path is every executable of this machine but the tools it lacks.
path_without() { # <folder> <tool>... — a folder of links to every executable of /usr/bin and /bin but those tools
  local folder="$1" file
  shift
  mkdir -p "$folder"
  for file in /usr/bin/* /bin/*; do
    [ -f "$file" ] && [ -x "$file" ] || continue
    case " $* " in *" ${file##*/} "*) continue ;; esac
    [ -e "$folder/${file##*/}" ] || ln -s "$file" "$folder/${file##*/}"
  done
}
NO_SHA256SUM="$WORK/path-no-sha256sum"
path_without "$NO_SHA256SUM" sha256sum
[ ! -e "$NO_SHA256SUM/sha256sum" ] && [ -x "$NO_SHA256SUM/openssl" ] && [ -x "$NO_SHA256SUM/awk" ] && [ -x "$NO_SHA256SUM/base64" ] \
  || fail 'the path of a machine without sha256sum was not made, or lacks openssl, awk or base64'
NO_DIGEST_TOOL="$WORK/path-no-digest-tool"
cp -a "$NO_SHA256SUM" "$NO_DIGEST_TOOL"; rm "$NO_DIGEST_TOOL/openssl"
BROKEN_DIGEST_TOOL="$WORK/path-broken-digest-tool"
cp -a "$NO_SHA256SUM" "$BROKEN_DIGEST_TOOL"; rm "$BROKEN_DIGEST_TOOL/openssl"
printf '#!/bin/sh\nexit 0\n' > "$BROKEN_DIGEST_TOOL/openssl"; chmod +x "$BROKEN_DIGEST_TOOL/openssl"
carried_by() { # <path> <reader file> <package> — what carry_rclone_package of that reader answers on that path: the architecture it names, or ERROR and the reason
  ( PATH="$1"; . "$2"; if carry_rclone_package "$TREE" "$3"; then printf '%s\n' "$RCLONE_CARRIED_ARCH"; else printf 'ERROR %s\n' "$RCLONE_METADATA_ERROR"; fi )
}
carried_holds() { # <reader file> — ends 0 when, on the paths below, the reader names the architecture of each genuine package, refuses a file that is not one for what it is, and names a digest it cannot compute
  local reader answer
  [ "$(carried_by "$PATH" "$1" "$WORK/fixture-amd64.deb")" = amd64 ] && [ "$(carried_by "$PATH" "$1" "$WORK/fixture-arm64.deb")" = arm64 ] || return 1
  [ "$(carried_by "$NO_SHA256SUM" "$1" "$WORK/fixture-amd64.deb")" = amd64 ] && [ "$(carried_by "$NO_SHA256SUM" "$1" "$WORK/fixture-arm64.deb")" = arm64 ] || return 1
  answer="$(carried_by "$NO_SHA256SUM" "$1" "$WORK/not-the-package.deb")"
  [[ "$answer" == *'is neither of the digests'* ]] || return 1
  for reader in "$NO_DIGEST_TOOL" "$BROKEN_DIGEST_TOOL"; do
    answer="$(carried_by "$reader" "$1" "$WORK/fixture-amd64.deb")"
    [[ "$answer" == 'ERROR '*'could not be computed'* && "$answer" != *'is neither of the digests'* ]] || return 1
  done
}
carried_holds "$HERE/read-rclone-pin.sh" || fail "the reader of the launchers does not hold a carried package to the table on a machine without sha256sum: $(carried_by "$NO_SHA256SUM" "$HERE/read-rclone-pin.sh" "$WORK/fixture-amd64.deb" | cut -c1-300)"
READER_TEXT="$(cat "$HERE/read-rclone-pin.sh")"
DIGEST_LINES="$(sed -n '/^  # openssl and not sha256sum/,/^    || { RCLONE_METADATA_ERROR="the sha256 of /p' "$HERE/read-rclone-pin.sh")"
[ "$(printf '%s\n' "$DIGEST_LINES" | wc -l | tr -d ' ')" = 3 ] || fail 'the reader of the launchers does not compute the digest of the carried package in the three lines this test replaces'
printf '%s\n' "${READER_TEXT/"$DIGEST_LINES"/'  digest=$(sha256sum "$file" | cut -d'"' '"' -f1)'}" > "$WORK/reader-sha256sum.sh"
printf '%s\n' "${READER_TEXT/' && [[ "$digest" =~ ^[0-9a-f]{64}$ ]]'/}" > "$WORK/reader-accepts-empty-digest.sh"
for planted in sha256sum accepts-empty-digest; do
  ! cmp -s "$WORK/reader-$planted.sh" "$HERE/read-rclone-pin.sh" || fail "the planted reader $planted was not made"
  ! carried_holds "$WORK/reader-$planted.sh" 2> /dev/null || fail "the planted reader $planted passed the cases of a machine without a digest tool — the cases prove nothing"
done
[[ "$(carried_by "$NO_SHA256SUM" "$WORK/reader-sha256sum.sh" "$WORK/fixture-amd64.deb" 2> /dev/null)" == *' its sha256  is neither of the digests'* ]] \
  || fail 'the planted reader that computes the digest with sha256sum did not refuse the genuine package with an empty digest — the plant is not the old reader'
# the launcher on such a machine: the genuine package is sent, and with no tool to compute the digest nothing is sent
SD_PATH_OF_PART_A="$SD_PATH"
SD_PATH="$SD/bin:$NO_SHA256SUM"
send "$TREE/lifecycle" restore 20261021T120000Z --rclone-package "$WORK/fixture-amd64.deb"
{ [ "$SEND_CODE" = 0 ] && grep -qF -- "AW_RCLONE_CARRIED_ARCH='amd64'" "$SD/session-stream"; } || fail "master-restore.sh --rclone-package on a machine without sha256sum ended $SEND_CODE: $(tail -n 1 "$WORK/send.err" | cut -c1-300)"
rm -rf "$WORK/mutant-sha256sum"; cp -R "$TREE" "$WORK/mutant-sha256sum"; cp "$WORK/reader-sha256sum.sh" "$WORK/mutant-sha256sum/lifecycle/read-rclone-pin.sh"
send "$WORK/mutant-sha256sum/lifecycle" restore 20261021T120000Z --rclone-package "$WORK/fixture-amd64.deb"
[ "$SEND_CODE" != 0 ] || fail 'a launcher that computes the digest with sha256sum sent the genuine package from a machine without it — the case proves nothing'
for path in "$NO_DIGEST_TOOL" "$BROKEN_DIGEST_TOOL"; do
  SD_PATH="$SD/bin:$path"
  send "$TREE/lifecycle" restore 20261021T120000Z --rclone-package "$WORK/fixture-amd64.deb"
  { [ "$SEND_CODE" = 65 ] && [ ! -e "$SD/session-stream" ] && grep -qF -- 'could not be computed' "$WORK/send.err"; } \
    || fail "master-restore.sh --rclone-package on a machine whose digest tool is missing or silent ended $SEND_CODE: $(tail -n 1 "$WORK/send.err" | cut -c1-300)"
done
SD_PATH="$SD_PATH_OF_PART_A"
ok 'the launcher holds a carried package to the table with openssl: on a machine without sha256sum it names the architecture of each genuine package and sends the restore program, it refuses a file that is not one for what it is, and with no digest tool, or one that prints nothing, it ends 65 saying the digest could not be computed and sends nothing; a reader that computes it with sha256sum, which refuses the genuine package from that machine with a false reason, and one that takes an empty digest are caught'

echo "rclone.test: part A green"
[ "${1:-}" != --part-a ] || exit 0

# ═══ PART B: the real executables ═══════════════════════════════════════════════════════════════════════════════════════
case "$(uname -m)" in
  x86_64) ARCH=amd64 ;;
  aarch64 | arm64) ARCH=arm64 ;;
  *) echo "rclone.test: NOT RUN — part B (the executables) needs a machine of amd64 or arm64; this one is $(uname -m), so no real executable was started"; exit 0 ;;
esac
command -v curl > /dev/null 2>&1 || fail 'curl is not on this path, and the packages are fetched with it'
REAL="$WORK/real"
mkdir -p "$REAL/bin" "$REAL/tmp" "$REAL/new"
cp "$SD/bin/sudo" "$SD/bin/install" "$REAL/bin/"
cat > "$REAL/bin/dpkg" << 'STANDIN'
#!/usr/bin/env bash
# dpkg that extracts instead of installing: -i FILE puts the files of the package under real/new and the executable on the path of the helper.
here="$(dirname "$0")/.."
case "$1" in
  --print-architecture) cat "$here/arch" ;;
  -i) dpkg-deb -x "$2" "$here/new" && cp "$here/new/usr/bin/rclone" "$here/bin/rclone" ;;
  *) exit 2 ;;
esac
STANDIN
chmod +x "$REAL/bin/dpkg"
echo "$ARCH" > "$REAL/arch"

# ── B1: the pinned release arrives through the helper, from the owned address of its row, and is held to the row's digest ──
{ tr -d '\r' < "$HERE/require-rclone.sh"; ( . "$HERE/read-rclone-pin.sh"; read_rclone_pin "$ROOT" && printf '%s\n' "$RCLONE_METADATA" ); } > "$REAL/prefix"
{ cat "$REAL/prefix"
  cat << 'HARNESS'
say() { printf '%s\n' "$*"; }
good() { printf 'ok %s\n' "$*"; }
ELEVATION_PASSWORD=planted
root() { printf '%s\n' "$ELEVATION_PASSWORD" | sudo -S -p '' "$@"; }
require_rclone || { printf 'refused: %s\n' "$RCLONE_REFUSAL"; exit 1; }
rclone_cleanup
HARNESS
} > "$REAL/program.sh"
( cd "$REAL" && env -i PATH="$REAL/bin:/usr/bin:/bin" TMPDIR="$REAL/tmp" bash "$REAL/program.sh" ) > "$REAL/program.out" 2>&1 \
  || fail "the helper could not put the pinned rclone $PIN on a machine from the owned address of its row: $(tail -n 3 "$REAL/program.out" | tr '\n' ' ' | cut -c1-400)"
NEW_RCLONE="$REAL/bin/rclone"
rclone_version_of() { local answer; answer="$("$1" --version)" || return; printf '%s\n' "${answer%%$'\n'*}"; } # the first line of the answer of an rclone, read whole so that no writer is left on a closed pipe
NEW_ANSWER="$(rclone_version_of "$NEW_RCLONE")"
[ "$NEW_ANSWER" = "rclone $PIN" ] || fail "the executable the helper installed answers \"$NEW_ANSWER\", not \"rclone $PIN\""
[ -z "$(ls -A "$REAL/tmp")" ] || fail 'the helper left a folder behind in the temporary folder'
ok "the helper fetched the rclone $PIN package for $ARCH from the owned address of its row, held it to the row's digest, and the executable it extracted answers \"$NEW_ANSWER\" as the operator and as root"

# ── B2: the two packages that produced the defect, from the places that publish them, held to their digests ──
fetch_package() { # <name> <url> <sha256> <version> — a package into $WORK/pkg/<name>.deb, extracted under $WORK/pkg/<name>/
  mkdir -p "$WORK/pkg"
  curl --fail --silent --show-error --connect-timeout 20 --max-time 300 --output "$WORK/pkg/$1.deb" "$2" || fail "the package $1 could not be fetched from $2"
  [ "$(sha256sum "$WORK/pkg/$1.deb" | cut -d' ' -f1)" = "$3" ] || fail "the package $1 is not the one this test was written against: its sha256 is not $3"
  [ "$(dpkg-deb -f "$WORK/pkg/$1.deb" Version)" = "$4" ] || fail "the package $1 is not version $4: $(dpkg-deb -f "$WORK/pkg/$1.deb" Version)"
  dpkg-deb -x "$WORK/pkg/$1.deb" "$WORK/pkg/$1"
}
if [ "$ARCH" = amd64 ]; then
  UBUNTU_VERSION='1.60.1+dfsg-4ubuntu3.2'
  fetch_package ubuntu "https://security.ubuntu.com/ubuntu/pool/universe/r/rclone/rclone_${UBUNTU_VERSION}_amd64.deb" 37124f897112c536e4057cc3e4c68b7bcb8dadb88e415c959d900c7ff0378bee "$UBUNTU_VERSION"
  DEBIAN_VERSION='1.60.1+dfsg-2+b5'
  fetch_package debian12 "https://deb.debian.org/debian/pool/main/r/rclone/rclone_${DEBIAN_VERSION}_amd64.deb" 703722dcab0c487322690fe68c7f8d6787e54e1ecd1297800d1382687ddbd81a "$DEBIAN_VERSION"
  OLD_RCLONE="$WORK/pkg/ubuntu/usr/bin/rclone"; DBTOOLS_RCLONE="$WORK/pkg/debian12/usr/bin/rclone"
else
  echo "rclone.test: NOT RUN — the packages that produced the defect are published for amd64 only here; on $ARCH the old executable and the dbtools measurement are not run"
  OLD_RCLONE='' DBTOOLS_RCLONE=''
fi

# ── B3: a loopback SFTP server of the pinned executable, a file above the multi-thread cutoff, and each executable copying it back ──
DATA="$WORK/data"
mkdir -p "$DATA/big" "$DATA/small"
head -c $((300 * 1024 * 1024)) /dev/urandom > "$DATA/big/archive.bin"
head -c $((1024 * 1024)) /dev/urandom > "$DATA/small/archive.bin"
BIG_BYTES="$(wc -c < "$DATA/big/archive.bin")"
BIG_SHA="$(sha256sum "$DATA/big/archive.bin" | cut -d' ' -f1)"
SMALL_SHA="$(sha256sum "$DATA/small/archive.bin" | cut -d' ' -f1)"
[ "$BIG_BYTES" -gt $((250 * 1024 * 1024)) ] || fail 'the big file is not above the multi-thread cutoff of 250 MiB'
random_word() { head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
copy_back() { # <run> <executable> <remote folder: big|small> <seconds it is given> [extra rclone arguments...] — a copy of the folder from a server of its own into $WORK/run-<run>/out; the code stands in $COPY_CODE, the log in $WORK/run-<run>/log
  local run="$1" binary="$2" folder="$3" limit="$4" dir="$WORK/run-$1" user password port server _
  shift 4
  mkdir -p "$dir/out"
  user="u$(random_word)" password="$(random_word)"
  timeout -k 2 900 "$NEW_RCLONE" serve sftp "$DATA" --addr 127.0.0.1:0 --user "$user" --pass "$password" --config /dev/null --log-level INFO > "$dir/serve.log" 2>&1 &
  server=$!; SERVERS+=("$server")
  port=''
  for _ in $(seq 1 100); do
    port="$(sed -n 's/.*listening on[^0-9]*127\.0\.0\.1:\([0-9][0-9]*\).*/\1/p' "$dir/serve.log" | head -n 1 || true)"
    [ -z "$port" ] || break
    sleep 0.1
  done
  [ -n "$port" ] || fail "the SFTP server of run $run did not say which port it listens on: $(head -c 300 "$dir/serve.log")"
  COPY_CODE=0
  env RCLONE_CONFIG=/dev/null RCLONE_CONFIG_BOX_TYPE=sftp RCLONE_CONFIG_BOX_HOST=127.0.0.1 RCLONE_CONFIG_BOX_PORT="$port" RCLONE_CONFIG_BOX_USER="$user" \
    RCLONE_CONFIG_BOX_PASS="$("$NEW_RCLONE" obscure "$password")" RCLONE_CONFIG_BOX_DISABLE_HASHCHECK=true \
    timeout -k 5 "$limit" "$binary" copy "box:$folder" "$dir/out" --use-json-log --log-level DEBUG --stats 1s --stats-log-level NOTICE "$@" > "$dir/log" 2>&1 || COPY_CODE=$?
  kill "$server" 2> /dev/null || true
  wait "$server" 2> /dev/null || true
  printf '%s %s %s\n' "$user" "$password" "$port" > "$dir/credentials"
}
sha_of() { sha256sum "$WORK/run-$1/out/archive.bin" 2> /dev/null | cut -d' ' -f1; }
production() { # <name>... — the functions of the backup driver by those names, as they stand in it
  local name
  for name; do
    case "$name" in
      readback_project) sed -n '/^readback_project() {/,/^# readback_diagnose:/p' "$HERE/master-backup-driver.sh" | sed '$d' ;;
      *) sed -n "/^$name() {/,/^}/p" "$HERE/master-backup-driver.sh" ;;
    esac
  done
}
eval "$(production rate_of seconds_of readback_sample readback_known_names readback_project)"
STAGE=prod
STORES=("vault|data-vault-0|vault|statefulset")
sample_of() { READBACK_STATS="$WORK/run-$1/log" readback_sample; } # the newest "bytes milliseconds" the production sampler reads from the log of a run

copy_back new "$NEW_RCLONE" big 120
{ [ "$COPY_CODE" = 0 ] && [ "$(sha_of new)" = "$BIG_SHA" ]; } || fail "the pinned rclone $PIN copying $BIG_BYTES bytes over SFTP ended $COPY_CODE and left sha256 $(sha_of new), not $BIG_SHA"
read -r NEW_BYTES NEW_MILLIS <<< "$(sample_of new)"
[ "$NEW_BYTES" = "$BIG_BYTES" ] || fail "the production sampler reads $NEW_BYTES bytes in the log of the pinned rclone, not the $BIG_BYTES it copied"
ok "the pinned rclone $PIN ($NEW_ANSWER) copied a file of $BIG_BYTES bytes, above the multi-thread cutoff, over SFTP on loopback and ended 0 with the same sha256; the production sampler reads $NEW_BYTES bytes in $NEW_MILLIS ms from its log"
copy_back newsmall "$NEW_RCLONE" small 60
{ [ "$COPY_CODE" = 0 ] && [ "$(sha_of newsmall)" = "$SMALL_SHA" ]; } || fail 'the pinned rclone did not copy the small file whole'
if [ -n "$OLD_RCLONE" ]; then
  copy_back old "$OLD_RCLONE" big 45
  OLD_CODE="$COPY_CODE"
  OLD_VERSION="$(rclone_version_of "$OLD_RCLONE")"
  read -r OLD_BYTES OLD_MILLIS <<< "$(sample_of old)"
  OLD_FIRST_COMPLETE="$(READBACK_EXPECTED="$BIG_BYTES" READBACK_STATS="$WORK/run-old/log" readback_project < "$WORK/run-old/log" | sed -n 's/^first complete record: \(.*\), transfers .*elapsedTime \([0-9.]*\) s.*/\2/p')"
  { [ "$OLD_CODE" = 124 ] || [ "$OLD_CODE" = 137 ]; } \
    || fail "the rclone of Ubuntu ($OLD_VERSION, package $UBUNTU_VERSION) ended $OLD_CODE on the file above the multi-thread cutoff: it did not stay open after its last byte, so the diagnosis of hostyour-cloud#491 is not reproduced here and goes back to the plan"
  [ "$OLD_BYTES" = "$BIG_BYTES" ] && [ "$(sha_of old)" = "$BIG_SHA" ] \
    || fail "the rclone of Ubuntu ended $COPY_CODE but had not read every byte ($OLD_BYTES of $BIG_BYTES) or wrote another file"
  copy_back oldsmall "$OLD_RCLONE" small 60
  { [ "$COPY_CODE" = 0 ] && [ "$(sha_of oldsmall)" = "$SMALL_SHA" ]; } || fail 'the rclone of Ubuntu did not copy the small file whole — the stall is not a matter of the file size alone'
  ok "the rclone of Ubuntu ($OLD_VERSION, package $UBUNTU_VERSION, sha256 37124f89…8bee) reported all $OLD_BYTES of $BIG_BYTES bytes by ${OLD_FIRST_COMPLETE:-an unreadable time} s of its own clock (its newest statistics are of $OLD_MILLIS ms), wrote the file whole, and was still running when it was ended after 45 s (status $OLD_CODE); the same file below the cutoff ended 0"
  copy_back dbtools "$DBTOOLS_RCLONE" big 120
  { [ "$COPY_CODE" = 0 ] && [ "$(sha_of dbtools)" = "$BIG_SHA" ]; } \
    || fail "the rclone of Debian 12 ($(rclone_version_of "$DBTOOLS_RCLONE"), package $DEBIAN_VERSION), the one the dbtools image of hostyour-manager installs, ended $COPY_CODE on the file above the multi-thread cutoff: it stalls, so dbtools needs the pinned rclone too"
  ok "the rclone of Debian 12 ($(rclone_version_of "$DBTOOLS_RCLONE"), package $DEBIAN_VERSION, sha256 703722dc…d81a), the one the dbtools image of hostyour-manager installs, copied the same $BIG_BYTES bytes and ended 0 with the same sha256: it does not stall, and the image is left as it is"
fi

# ── B4: the actual log of the pinned executable through the production projection of the driver ──
READBACK_EXPECTED="$BIG_BYTES"
PROJECTED="$(READBACK_STATS="$WORK/run-new/log" readback_project < "$WORK/run-new/log")"
[ -n "$PROJECTED" ] || fail 'the production projection printed nothing for the log of a copy that reported every byte'
grep -qx "rclone version: $PIN" <<< "$PROJECTED" || fail "the production projection did not read the version $PIN from the startup record of the actual log: $(grep -m1 'rclone version' <<< "$PROJECTED")"
# rclone writes its first debug lines (the options taken from the environment) as plain text, before the JSON log is switched on: they are the only lines that are not records.
TEXT_LINES="$(grep -vc '^{' "$WORK/run-new/log" || true)"
grep -q "[( ]$TEXT_LINES line(s) unreadable, 0 statistics record(s) not valid" <<< "$PROJECTED" || fail "the production projection could not read every JSON record of the actual log ($TEXT_LINES line(s) are plain text): $(grep -m1 'retry records' <<< "$PROJECTED" | cut -c1-300)"
read -r SERVED_USER SERVED_PASSWORD SERVED_PORT < "$WORK/run-new/credentials"
for planted in "$SERVED_USER" "$SERVED_PASSWORD" "127.0.0.1" ":$SERVED_PORT" "$WORK" "archive.bin"; do
  ! grep -qF -- "$planted" <<< "$PROJECTED" || fail "the production projection of the actual log of the pinned rclone prints $planted, which is the host, the account, the credential or a path of the server"
done
grep -qE 'unavailable' <<< "$(grep -E '^(log of the completion|  20)' <<< "$PROJECTED")" && fail 'the production projection reads a level, a time or a source of the actual log as unavailable'
ok "the actual log of the pinned rclone, JSON with its statistics records, goes through the production projection of the driver: the version $PIN is read from the startup record, every JSON record is readable, and neither the account, the credential, the address and port of the server, the folder nor the file name of the fixture appears in what it prints"
LONG_PARAMETERS="$(head -c 6000 /dev/zero | tr '\0' 'p')PLANTED-SECRET-IN-PARAMETERS"
{ printf '{"level":"debug","msg":"Version \\"%s\\" starting with parameters [\\"rclone\\" \\"%s\\"]","source":"cmd/cmd.go:414","time":"2026-10-21T20:00:00.000000000+02:00"}\n' "$PIN" "$LONG_PARAMETERS"
  printf '{"level":"warning","msg":"stats","stats":{"bytes":%s,"checks":0,"deletedDirs":0,"deletes":0,"elapsedTime":30.5,"errors":0,"fatalError":false,"retryError":false,"totalChecks":0,"totalTransfers":1,"transfers":0},"time":"2026-10-21T20:00:31.000000000+02:00"}\n' "$BIG_BYTES"
} > "$WORK/long-version.log"
version_of() { READBACK_STATS="$WORK/long-version.log" readback_project < "$WORK/long-version.log"; }
LONG="$(version_of)"
grep -qx "rclone version: $PIN" <<< "$LONG" && grep -qF "Version \"$PIN\" starting with parameters [redacted]" <<< "$LONG" || fail "a startup record with 6000 characters of parameters did not keep its version: $(grep -m1 'rclone version' <<< "$LONG")"
! grep -qF PLANTED-SECRET <<< "$LONG" || fail 'the projection printed the tail of the long parameters'
eval "$(production readback_project | sed 's#/^Version "v#/^Version "x#' | sed '1s/^readback_project()/readback_project_unaware()/')"
LONG_UNAWARE="$(READBACK_STATS="$WORK/long-version.log" readback_project_unaware < "$WORK/long-version.log")"
! grep -qx "rclone version: $PIN" <<< "$LONG_UNAWARE" || fail 'the planted projection that does not recognise a startup record still read the version — the case proves nothing'
ok 'a startup record with 6000 characters of parameters keeps its validated version and redacts the whole tail; a projection that does not recognise the record loses the version and is caught'

# ── B5: two runs at once share no port and no file, and nothing is left running ──
( copy_back parallel_a "$NEW_RCLONE" big 120; exit "$COPY_CODE" ) & PID_A=$!
( copy_back parallel_b "$NEW_RCLONE" big 120; exit "$COPY_CODE" ) & PID_B=$!
wait "$PID_A" || fail 'the first of two copies at once did not end 0'
wait "$PID_B" || fail 'the second of two copies at once did not end 0'
[ "$(sha_of parallel_a)" = "$BIG_SHA" ] && [ "$(sha_of parallel_b)" = "$BIG_SHA" ] || fail 'a copy of two at once wrote another file'
[ "$(cut -d' ' -f3 "$WORK/run-parallel_a/credentials")" != "$(cut -d' ' -f3 "$WORK/run-parallel_b/credentials")" ] || fail 'two runs at once shared a port'
sleep 1
! pgrep -f "$WORK" > /dev/null || fail "a process that names this test's folder is still running: $(pgrep -fa "$WORK" | head -n 2 | cut -c1-200)"
ok 'two copies at once, each from a server of its own on a port the kernel gave it, ended 0 with the same sha256, and no process of this test is left running'
if [ -n "$OLD_RCLONE" ]; then
  echo "rclone.test: GREEN — part A (stand-ins) and part B (the executables of rclone $PIN, Ubuntu's and Debian 12's)"
else
  echo "rclone.test: GREEN — part A (stand-ins) and part B with the executable of rclone $PIN only; the executables of Ubuntu and Debian 12 did not run on $ARCH"
fi
