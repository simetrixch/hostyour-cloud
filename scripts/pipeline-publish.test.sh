#!/usr/bin/env bash
# The publish pipeline's own shell, where it decides something a fixture can hold it to: which
# package.json a release tag publishes and which registry it may name, and that a tree holding npm-seed/
# is no publication of its own; that the release commit is on the default branch, or differs from it in
# stamped versions only; that every package declares the version of the tag before it is packed,
# workspace ranges included; that pack installs the tools a source release's ci-tools.json names; that
# every packed tarball holds files under package/ only, no .npmrc, no .env* and no gitleaks finding; and that the push refuses another scope and another content under a
# published version, pushes nothing once one tarball is refused, reads every tarball back, and logs one
# line per tarball; that a tag tracking release/build.sh publishes the binaries that script leaves, and
# only regular files of a plain name, as one manifest <owner>/<repository>:<tag> that a second run
# reuses and another build under the same tag cannot replace; that the platform tree copies every image
# its list names into the mirror at the digest it pins, after the tag upstream is found to name that
# digest, and reads each back without a login at that digest and its own media type; that the platform
# tree's list of tools and charts refuses a row of another form by its line, that fetch downloads every
# row the mirror does not serve and holds it to its sha256, that copy-sources pushes each as the one layer
# under its tag, after every line is held to its row, to the mirror and to the file fetch staged, and
# replaces nothing, and that read-back-sources reads each back without a login as its bytes, and that
# nothing runs after the mirror; that the engine on the owner's master is put under its tag by tag right
# after push put it under its digest, with the push login in the steps of push and tag alone; and that a
# binaries build reads the owned yq and jq of files/ci-fixed-tools.sh from the mirror and holds them to
# their sha256. The functions
# are read out of the template (clusters/inventories/consumer-build/templates/pipeline-publish.yaml) and
# the files it includes, as the Pipeline carries them, and run against fixture repositories, tarballs, a
# registry served on 127.0.0.1 and upstreams served from files. Then the
# Pipeline as helm renders it runs end to end, every step in Tekton's order, on fixture repositories
# and the same registry, so each step is held to calling its functions.
#
#   bash scripts/pipeline-publish.test.sh
set -uo pipefail
root="$(git rev-parse --show-toplevel)" || exit 1
template="$root/clusters/inventories/consumer-build/templates/pipeline-publish.yaml"
fail() { echo "pipeline-publish.test: RED — $*" >&2; exit 1; }
ok() { echo "pipeline-publish.test: ok — $*"; }
for tool in git jq node pnpm tar gzip sha256sum gitleaks curl helm yq; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is not on this path, and the functions under test run it"
done
work="$(mktemp -d)" || fail "no temporary directory could be made"
registry_pid=""
trap '[ -z "$registry_pid" ] || kill "$registry_pid" 2>/dev/null; rm -rf "$work"' EXIT
# No git call of a fixture leaves a process behind it, which a case removing its repository would
# race: scripts/standin/git-quiet.sh sets the template that prevents it and measures that it does.
# shellcheck disable=SC1091
. "$root/scripts/standin/git-quiet.sh"
planted="$(git_quiet_proof "$work")" || fail 'a fixture git starts a background maintenance'
ok "a fixture commits and pushes without starting a background maintenance; the planted defect, repositories made without the template, starts $planted"
# Stand-ins for what the cluster has and this machine must not change: curl that reaches the fixture
# registry, and corepack, whose enable would write into this machine's Node.
mkdir -p "$work/standin-bin"
real_curl="$(command -v curl)" real_helm="$(command -v helm)"
PATH="$work/standin-bin:$PATH"

# A function from its first line to the brace that closes it at the same indent.
extract() { # function name -> its text out of the template
  awk -v fn="$1" '
    $0 ~ "^ *" fn "\\(\\) \\{" { indent = match($0, /[^ ]/); on = 1 }
    on { print }
    on && /^ *\}$/ && match($0, /[^ ]/) == indent { exit }
  ' "$template"
}
[ -f "$template" ] || fail "the template $template does not exist"
# shellcheck source=../clusters/inventories/consumer-build/files/registry-push.sh
. "$root/clusters/inventories/consumer-build/files/registry-push.sh"
# shellcheck source=../clusters/inventories/consumer-build/files/mirror-sources.sh
. "$root/clusters/inventories/consumer-build/files/mirror-sources.sh"
for fn in scan_packages stamp_only reviewed_commit release_version stamp_versions build_packages pack_packages \
  check_tarballs scan_leaks npm_push build_binaries binaries_push mirror_copy mirror_read_back mirror_fetch mirror_copy_sources mirror_read_back_sources; do
  extract "$fn" > "$work/$fn.sh"
  [ -s "$work/$fn.sh" ] || fail "the template carries no $fn function"
  # shellcheck source=/dev/null
  . "$work/$fn.sh"
done

# Fixture repositories commit as nobody and run no hook of this machine.
export GIT_CONFIG_GLOBAL="$work/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.name fixture
git config --global user.email fixture@example.invalid
git config --global init.defaultBranch master
git config --global advice.detachedHead false
export pnpm_config_store_dir="$work/pnpm-store" npm_config_store_dir="$work/pnpm-store" TMPDIR="$work/tmp"
mkdir -p "$TMPDIR"
json() { node -e 'process.stdout.write(JSON.stringify(JSON.parse(process.argv[1]), null, 2) + "\n")' "$1"; }
repo() { # $1 folder, then path=content pairs -> a repository with one commit holding them
  local dir="$1" pair; shift
  mkdir -p "$dir"
  git -C "$dir" init -q
  for pair in "$@"; do
    mkdir -p "$dir/$(dirname "${pair%%=*}")"
    printf '%s\n' "${pair#*=}" > "$dir/${pair%%=*}"
  done
  git -C "$dir" add -A && git -C "$dir" commit -q -m init --allow-empty
}
export NPM_REGISTRY='https://registry.test/v2/npm/'

# ── scan_packages: what a release tag publishes ─────────────────────────────────────────────
repo "$work/scan" \
  "package.json=$(json '{"name":"root","private":true,"version":"1.0.0"}')" \
  "packages/a/package.json=$(json '{"name":"@digitaplatform/a","version":"1.0.0","publishConfig":{"registry":"https://registry.test/v2/npm/"}}')" \
  "packages/b/package.json=$(json '{"name":"@digitaplatform/b","version":"1.0.0"}')" \
  "packages/c/package.json=$(json '{"name":"@digitaplatform/c","version":"1.0.0","private":true,"publishConfig":{"registry":"https://registry.test/v2/npm/"}}')" \
  "pakete/ü d/package.json=$(json '{"name":"@digitaplatform/umlaut","version":"1.0.0","publishConfig":{"registry":"https://registry.test/v2/npm/"}}')"
(cd "$work/scan" && MODE='' && scan_packages "$work/list" >/dev/null && echo "$MODE") > "$work/mode" || fail 'a repository that publishes to this registry was refused'
[ "$(cat "$work/mode")" = source ] || fail "the scan named the mode '$(cat "$work/mode")', not source"
[ "$(cut -f2 "$work/list" | sort | tr '\n' ' ')" = '@digitaplatform/a @digitaplatform/umlaut ' ] \
  || fail "the scan listed $(cut -f2 "$work/list" | tr '\n' ' '): private packages and packages without publishConfig.registry are no publication, a folder git quotes is one"
grep -qxF "pakete/ü d	@digitaplatform/umlaut" "$work/list" || fail 'the folder of a package whose path git would quote is not the folder itself'
ok 'the scan lists every package that is not private and names this registry, with its folder'
printf '%s\n' "$(json '{"name":"@digitaplatform/old","version":"1.0.0","publishConfig":{"registry":"https://npm.pkg.github.com"}}')" > "$work/scan/packages/b/package.json"
git -C "$work/scan" commit -q -am 'another registry'
OUT="$(cd "$work/scan" && scan_packages "$work/list" 2>&1)" && fail 'PLANTED DEFECT: a package that names npm.pkg.github.com was not refused'
case "$OUT" in *"@digitaplatform/old (packages/b/package.json) names publishConfig.registry https://npm.pkg.github.com"*) ;; *) fail "the refusal does not name the package and its registry: $OUT" ;; esac
ok 'a package that names another registry fails the scan, naming both'
repo "$work/none" "package.json=$(json '{"name":"app","version":"1.0.0"}')" "src/index.js=x"
(cd "$work/none" && MODE='' && scan_packages "$work/list" >/dev/null && echo "$MODE") > "$work/mode" || fail 'a repository with nothing to publish failed'
[ "$(cat "$work/mode")" = none ] && [ ! -s "$work/list" ] || fail 'a repository with nothing to publish was not none'
repo "$work/bare" "main.go=package main"
(cd "$work/bare" && MODE='' && scan_packages "$work/list" >/dev/null && echo "$MODE") > "$work/mode" || fail 'a repository without package.json failed'
[ "$(cat "$work/mode")" = none ] || fail 'a repository without package.json was not none'
ok 'PLANTED INNOCENT: an application and a repository without package.json publish nothing and pass'
# The one-time seed is over: a tree holding npm-seed/ publishes its packages like any other, and its
# tarballs are no publication.
repo "$work/seeded" "npm-seed/pins.tsv=x" "npm-seed/digitaplatform-a-0.9.0.tgz=x" \
  "packages/a/package.json=$(json '{"name":"@digitaplatform/a","version":"1.0.0","publishConfig":{"registry":"https://registry.test/v2/npm/"}}')"
(cd "$work/seeded" && MODE='' && scan_packages "$work/list" >/dev/null && echo "$MODE") > "$work/mode" || fail 'a tree holding npm-seed/ was refused at its scan'
[ "$(cat "$work/mode")" = source ] && [ "$(cat "$work/list")" = "packages/a	@digitaplatform/a" ] \
  || fail "PLANTED DEFECT: a tree holding npm-seed/ took the seed path, which the cut-over deleted: mode $(cat "$work/mode"), list $(cat "$work/list")"
ok 'a tree holding npm-seed/ lists its own packages and nothing of npm-seed/'
repo "$work/binaries" "release/build.sh=exit 0" \
  "packages/a/package.json=$(json '{"name":"@digitaplatform/a","version":"1.0.0","publishConfig":{"registry":"https://registry.test/v2/npm/"}}')"
(cd "$work/binaries" && MODE='' && scan_packages "$work/list" >/dev/null && echo "$MODE") > "$work/mode" || fail 'a tag tracking release/build.sh was refused at its scan'
[ "$(cat "$work/mode")" = binaries ] && [ ! -s "$work/list" ] || fail "PLANTED DEFECT: a tag tracking release/build.sh was scanned as '$(cat "$work/mode")' or listed its packages"
git -C "$work/binaries" rm -q --cached release/build.sh && git -C "$work/binaries" commit -q -m untrack
(cd "$work/binaries" && MODE='' && scan_packages "$work/list" >/dev/null && echo "$MODE") > "$work/mode" || fail 'a tag with an untracked release/build.sh was refused'
[ "$(cat "$work/mode")" = source ] || fail "PLANTED INNOCENT: a release/build.sh git does not track made the scan '$(cat "$work/mode")', not source"
ok 'a tag that tracks release/build.sh publishes its binaries and nothing else; an untracked one changes nothing'

# ── build_binaries: what release/build.sh leaves is what is published ──────────────────────
build() { # $1 the body of release/build.sh -> the exit status of build_binaries, its output in $work/build.out
  rm -rf "$work/bb" "$work/bb-out"; repo "$work/bb" "release/build.sh=$1"
  (cd "$work/bb" && RELEASE_TAG=1.0.000-stable-20261014000000 build_binaries "$work/bb-out") > "$work/build.out" 2>&1
}
build 'printf a > "$2/tool-$1-linux-x64"; printf b > "$2/tool-rest-$1-linux-x64"' \
  || fail "PLANTED INNOCENT: two binaries release/build.sh left were refused: $(cat "$work/build.out")"
[ "$(ls "$work/bb-out" | tr '\n' ' ')" = 'tool-1.0.000-stable-20261014000000-linux-x64 tool-rest-1.0.000-stable-20261014000000-linux-x64 ' ] \
  || fail "release/build.sh was not handed the tag and the folder: $(ls "$work/bb-out")"
build 'mkdir "$2/folder"' && fail 'PLANTED DEFECT: a folder release/build.sh left was taken for a binary'
grep -qF 'left folder, which is no regular file' "$work/build.out" || fail "the folder was not named: $(cat "$work/build.out")"
build 'printf a > "$2/x"; ln -s x "$2/link"' && fail 'PLANTED DEFECT: a link release/build.sh left was taken for a binary'
build 'printf a > "$2/.hidden"' && fail 'PLANTED DEFECT: a hidden file release/build.sh left was taken for a binary'
build 'exit 0' && fail 'PLANTED DEFECT: a release/build.sh that left nothing passed'
build 'exit 3' && fail 'PLANTED DEFECT: a release/build.sh that failed passed'
ok 'the binaries are the regular files release/build.sh leaves; a folder, a link, a hidden file, nothing or a failed build are refused'

# ── reviewed_commit: only the default branch is published ──────────────────────────────────
repo "$work/rev" \
  "package.json=$(json '{"name":"unit","version":"1.2.3","peerDependencies":{"react":"18.0.0"}}')" \
  "packages/a/package.json=$(json '{"name":"@x/a","version":"1.2.3"}')" \
  "package-lock.json=$(json '{"name":"unit","version":"1.2.3","lockfileVersion":3,"packages":{"":{"name":"unit","version":"1.2.3"},"packages/a":{"name":"@x/a","version":"1.2.3"},"node_modules/react":{"version":"18.0.0"}}}')" \
  "src.txt=code"
git -C "$work/rev" update-ref refs/publish/default HEAD
(cd "$work/rev" && reviewed_commit refs/publish/default >/dev/null) || fail 'PLANTED INNOCENT: a commit of the default branch was refused'
stamp() { # $1 version, $2 extra JSON merged into the root package.json
  local extra="${2:-}"
  [ -n "$extra" ] || extra='{}'
  json "$(node -e 'process.stdout.write(JSON.stringify({name: "unit", version: process.argv[1], peerDependencies: {react: "18.0.0"}, ...JSON.parse(process.argv[2])}))' "$1" "$extra")" > "$work/rev/package.json"
  json "{\"name\":\"@x/a\",\"version\":\"$1\"}" > "$work/rev/packages/a/package.json"
  json "{\"name\":\"unit\",\"version\":\"$1\",\"lockfileVersion\":3,\"packages\":{\"\":{\"name\":\"unit\",\"version\":\"$1\"},\"packages/a\":{\"name\":\"@x/a\",\"version\":\"$1\"},\"node_modules/react\":{\"version\":\"18.0.0\"}}}" > "$work/rev/package-lock.json"
  git -C "$work/rev" commit -q -am "release: $1"
}
# The stamp of a release minted with --from: made on the standing release's commit, on no branch.
git -C "$work/rev" checkout -q --detach
stamp 1.2.3-beta
(cd "$work/rev" && reviewed_commit refs/publish/default >/dev/null) || fail 'a stamp commit on no branch, which changes versions only, was refused'
stamp 1.2.3-alpha
(cd "$work/rev" && reviewed_commit refs/publish/default >/dev/null) || fail 'a stamp made on another stamp was refused'
ok 'a commit of the default branch passes, and so does a stamp off every branch that changes versions only'
echo 'code that master never had' > "$work/rev/src.txt"; git -C "$work/rev" commit -q -am code
OUT="$(cd "$work/rev" && reviewed_commit refs/publish/default 2>&1)" && fail 'PLANTED DEFECT: a commit off the default branch that changes code was published'
case "$OUT" in *"is not on the default branch of origin"*) ;; *) fail "the refusal does not say why: $OUT" ;; esac
git -C "$work/rev" reset -q --hard HEAD~1
stamp 1.2.3-beta '{"dependencies":{"left":"1.0.0"}}'
(cd "$work/rev" && reviewed_commit refs/publish/default >/dev/null 2>&1) && fail 'PLANTED DEFECT: a stamp that also adds a dependency was published'
git -C "$work/rev" reset -q --hard HEAD~1
stamp 1.2.3-beta '{"peerDependencies":{"version":"npm:evil-pkg@1.0.0","react":"18.0.0"}}'
(cd "$work/rev" && reviewed_commit refs/publish/default >/dev/null 2>&1) && fail 'PLANTED DEFECT: a dependency alias under a key named version passed as a stamp'
git -C "$work/rev" reset -q --hard HEAD~1
mkdir -p "$work/rev/packages/x"; git -C "$work/rev" mv src.txt packages/x/package.json; git -C "$work/rev" commit -q -m rename
(cd "$work/rev" && reviewed_commit refs/publish/default >/dev/null 2>&1) && fail 'PLANTED DEFECT: a file renamed onto a package.json path passed as a stamp'
ok 'a commit off the default branch that changes code, a dependency or a file name is refused'

# ── release_version and stamp_versions: the version comes from the tag ─────────────────────
for pair in 0.3.001-stable-20261014000000=0.3.1 1.2.000-beta-20261014000000=1.2.0-beta \
  0.8.446-alpha-20261014000000=0.8.446-alpha 0.4.13-stable-20261014000000=0.4.13 10.0.0-stable-20261014000000=10.0.0; do
  [ "$(release_version "${pair%%=*}")" = "${pair#*=}" ] || fail "the tag ${pair%%=*} gave the version $(release_version "${pair%%=*}"), not ${pair#*=} as the kit's release.sh stamps"
done
ok 'the version of a tag is the one the kit stamps: the third position without leading zeros, the channel off stable'
# A workspace whose package.json files declare a version the tag does not: a and its workspace
# dependency b publish, the root and c (no version line) do not.
repo "$work/ws" \
  "package.json=$(json '{"name":"root","private":true,"version":"0.0.1"}')" \
  "pnpm-workspace.yaml=packages: [a, b]" ".gitignore=node_modules" \
  "a/package.json=$(json '{"name":"@digitaplatform/a","version":"0.0.1","dependencies":{"@digitaplatform/b":"workspace:*"},"engines":{"node":">=24"},"publishConfig":{"registry":"https://registry.test/v2/npm/"},"x":{"version":"9.9.9"}}')" \
  "b/package.json=$(json '{"name":"@digitaplatform/b","version":"0.0.1","publishConfig":{"registry":"https://registry.test/v2/npm/"}}')" \
  "c/package.json=$(json '{"name":"c","private":true}')"
(cd "$work/ws" && pnpm install --offline >/dev/null 2>&1 && git add -A && git commit -q -m lock) || fail 'the fixture workspace could not be installed offline'
(cd "$work/ws" && scan_packages "$work/ws-list" >/dev/null) || fail 'the fixture workspace was refused at its scan'
packed_as() { tar -xzOf "$1" package/package.json | jq -r '.name + "@" + .version + " " + (.dependencies["@digitaplatform/b"] // "-")'; }
# PLANTED DEFECT: packed as committed, the tarball carries the version the tag does not name.
mkdir "$work/unstamped"
(cd "$work/ws" && pack_packages "$work/ws-list" "$work/unstamped" 0.3.1 >/dev/null 2>&1) \
  && fail 'PLANTED DEFECT: a package packed at 0.0.1 under a tag that names 0.3.1 was not refused'
(cd "$work/ws" && stamp_versions "$(release_version 0.3.001-stable-20261014000000)" >/dev/null) || fail 'the stamp failed'
[ "$(jq -r .version "$work/ws/a/package.json")" = 0.3.1 ] || fail 'the stamp did not write the version of the tag'
[ "$(jq -r .x.version "$work/ws/a/package.json")" = 9.9.9 ] || fail 'the stamp touched a version line that is not the manifest'"'"'s own'
git -C "$work/ws" diff --quiet -- c/package.json || fail 'a package.json that declares no version was changed'
mkdir "$work/stamped"
(cd "$work/ws" && build_packages "$work/ws-list" >/dev/null 2>&1) || fail 'the stamped workspace did not install from its frozen lockfile'
(cd "$work/ws" && pack_packages "$work/ws-list" "$work/stamped" 0.3.1 >/dev/null) || fail 'the stamped packages were refused at their pack'
[ "$(packed_as "$work/stamped/digitaplatform-a-0.3.1.tgz")" = '@digitaplatform/a@0.3.1 0.3.1' ] \
  || fail "a was packed as $(packed_as "$work/stamped/digitaplatform-a-0.3.1.tgz"): the version and its workspace range must be the tag's"
[ "$(packed_as "$work/stamped/digitaplatform-b-0.3.1.tgz")" = '@digitaplatform/b@0.3.1 -' ] || fail 'b was not packed at the version of the tag'
[ "$(find "$work/stamped" -name '*.tgz' | wc -l)" = 2 ] || fail 'the pack wrote another number of tarballs than packages to publish'
git -C "$work/ws" commit -q -am "release: 0.3.001-stable-20261014000000"
(cd "$work/ws" && stamp_versions 0.3.1 >/dev/null) && git -C "$work/ws" diff --quiet \
  || fail 'PLANTED INNOCENT: the stamp is not a no-op on a tag the kit stamped already'
ok 'every package.json declares the version of the tag before the pack, workspace ranges follow it, and a kit-stamped tag stays as it is'

# ── build_packages: the workspace builds what it publishes ─────────────────────────────────
repo "$work/build" "README.md=x"
mkdir -p "$work/build/a" "$work/build/loose" "$work/bin"
members="$(node -e 'process.stdout.write(JSON.stringify([{path: process.argv[1]}, {path: process.argv[1] + "/a"}]))' "$work/build")"
cat > "$work/bin/pnpm" <<STUB
#!/bin/sh
case "\$1" in
  ls) printf '%s\n' '$members' ;;
  *) echo "pnpm \$*" >> "$work/calls.log" ;;
esac
STUB
chmod +x "$work/bin/pnpm"
printf 'a\t@digitaplatform/a\n' > "$work/build-list"
(cd "$work/build" && PATH="$work/bin:$PATH" build_packages "$work/build-list" >/dev/null) || fail 'a workspace member was refused'
[ "$(cat "$work/calls.log")" = $'pnpm install --frozen-lockfile\npnpm --filter @digitaplatform/a... run --if-present build' ] \
  || fail "the build ran: $(cat "$work/calls.log")"
: > "$work/calls.log"
printf 'a\t@digitaplatform/a\nloose\t@digitaplatform/loose\n' > "$work/build-list"
OUT="$(cd "$work/build" && PATH="$work/bin:$PATH" build_packages "$work/build-list" 2>&1)" && fail 'PLANTED DEFECT: a package outside the workspace was built and would be published unbuilt'
case "$OUT" in *"@digitaplatform/loose (loose) is no package of this pnpm workspace"*) ;; *) fail "the refusal does not name the package: $OUT" ;; esac
[ "$(cat "$work/calls.log")" = 'pnpm install --frozen-lockfile' ] || fail 'a refused workspace still built'
ok 'the packages build with their workspace dependencies, and one outside the workspace is refused'

# ── check_tarballs and scan_leaks: what a packed tarball may carry ─────────────────────────
tgz() { # $1 the tarball, $2 the package.json, then extra path=content pairs inside package/
  local into pair out="$1" manifest="$2"
  into="$work/tgz-src/$(basename "$1")"; shift 2
  rm -rf "$into"; mkdir -p "$into/package"
  printf '%s\n' "$manifest" > "$into/package/package.json"
  for pair in "$@"; do mkdir -p "$into/package/$(dirname "${pair%%=*}")"; printf '%s\n' "${pair#*=}" > "$into/package/${pair%%=*}"; done
  tar -czf "$out" -C "$into" package
}
packed() { # $1 folder: two clean tarballs, minimal and theme, as the pack leaves them
  rm -rf "$1"; mkdir -p "$1"
  tgz "$1/digitaplatform-minimal-0.4.13.tgz" "$(json '{"name":"@digitaplatform/minimal","version":"0.4.13"}')" "dist/index.js=export const x = 1;"
  tgz "$1/digitaplatform-theme-0.3.13.tgz" "$(json '{"name":"@digitaplatform/theme","version":"0.3.13"}')" "dist/index.css=a{}"
  printf 'packages/minimal\t@digitaplatform/minimal\n' > "$1/publishable.tsv"
}
check_run() { # $1 the folder of tarballs -> the exit status of check_tarballs, its output in $work/check.out
  rm -rf "$work/unpacked"; mkdir -p "$work/unpacked"
  check_tarballs "$1" "$work/unpacked" > "$work/check.out" 2>&1
}
packed "$work/t"
check_run "$work/t" || fail "PLANTED INNOCENT: two clean tarballs were refused: $(cat "$work/check.out")"
[ "$(ls "$work/unpacked" | tr '\n' ' ')" = 'digitaplatform-minimal-0.4.13.tgz digitaplatform-theme-0.3.13.tgz ' ] \
  && [ -f "$work/unpacked/digitaplatform-theme-0.3.13.tgz/package/dist/index.css" ] || fail 'the checked tarballs were not unpacked for gitleaks'
scan_leaks "$work/unpacked" >/dev/null 2>&1 || fail 'PLANTED INNOCENT: the clean tarballs have a gitleaks finding'
ok 'clean tarballs pass, and are unpacked for a gitleaks scan that finds nothing'
refused() { # $1 what the case plants, $2 the words the refusal must carry
  check_run "$work/t" && fail "PLANTED DEFECT: $1 was not refused"
  grep -qF -- "$2" "$work/check.out" || fail "$1 was refused without saying '$2': $(cat "$work/check.out")"
}
theme() { json '{"name":"@digitaplatform/theme","version":"0.3.13"}'; }
packed "$work/t"; tgz "$work/t/digitaplatform-theme-0.3.13.tgz" "$(theme)" ".npmrc=//registry.example/:_authToken=x"
refused 'a tarball holding .npmrc' 'digitaplatform-theme-0.3.13.tgz holds package/.npmrc'
packed "$work/t"; tgz "$work/t/digitaplatform-theme-0.3.13.tgz" "$(theme)" "config/.env.local=A=1"
refused 'a tarball holding .env.local' 'digitaplatform-theme-0.3.13.tgz holds package/config/.env.local'
packed "$work/t"; mkdir -p "$work/tgz-src/link/package"; theme > "$work/tgz-src/link/package/package.json"
ln -sf /etc/passwd "$work/tgz-src/link/package/passwd"; tar -czf "$work/t/digitaplatform-theme-0.3.13.tgz" -C "$work/tgz-src/link" package
refused 'a tarball holding a symbolic link' 'digitaplatform-theme-0.3.13.tgz holds an entry that is neither a file nor a folder'
packed "$work/t"; mkdir -p "$work/tgz-src/outside/package"; theme > "$work/tgz-src/outside/package/package.json"; echo x > "$work/tgz-src/outside/loose.js"
tar -czf "$work/t/digitaplatform-theme-0.3.13.tgz" -C "$work/tgz-src/outside" package loose.js
refused 'a tarball holding a file outside package/' 'digitaplatform-theme-0.3.13.tgz holds loose.js, outside package/'
ok 'a tarball holding .npmrc, .env*, a link or a file outside package/ is refused'
packed "$work/t"
check_run "$work/t" || fail 'the clean tarballs were refused'
printf 'const token = "ghp_%s";\n' "$(head -c 400 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 36)" > "$work/unpacked/digitaplatform-theme-0.3.13.tgz/package/dist/leak.js"
scan_leaks "$work/unpacked" >/dev/null 2>&1 && fail 'PLANTED DEFECT: a token in a packed tarball was not found by gitleaks'
ok 'a gitleaks finding in an unpacked tarball fails its scan'

# ── npm_push: the registry, served on 127.0.0.1 ────────────────────────────────────────────
# A registry of the OCI distribution API, as much of it as the push and the mirror use, behind one basic
# login, which a read under simetrixch/ does not need, as zot's anonymousPolicy on <owner>/**
# lets it. It keeps blobs and manifests per repository, a manifest under its tag and its digest with
# the media type it was pushed as, refuses a manifest that names a blob or, for an index, a manifest
# the repository lacks and a blob whose bytes are not its digest, logs every request, answers a blob
# read with a changed byte while the file `corrupt` stands beside it (of the repositories whose path holds
# the text of that file, when it has any), and serves every manifest as an OCI image manifest while the
# file `retype` does.
mkdir -p "$work/registry"
cat > "$work/registry.mjs" <<'EOF'
import {createServer} from 'node:http';
import {createHash, randomUUID} from 'node:crypto';
import {appendFileSync, existsSync, readFileSync, writeFileSync} from 'node:fs';
const dir = process.argv[2];
const login = 'Basic ' + Buffer.from('fixture-push:fixture-password').toString('base64');
const blobs = new Map(), manifests = new Map();
const digest = (body) => 'sha256:' + createHash('sha256').update(body).digest('hex');
const server = createServer((req, res) => {
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    const body = Buffer.concat(chunks), url = new URL(req.url, 'http://x');
    appendFileSync(`${dir}/requests.log`, `${req.method} ${url.pathname}\n`);
    const anonymous = ['GET', 'HEAD'].includes(req.method) && url.pathname.startsWith('/v2/simetrixch/');
    if (req.headers.authorization !== login && !anonymous) { res.writeHead(401); return res.end(); }
    let m;
    if ((m = url.pathname.match(/^\/v2\/(.+)\/blobs\/uploads\/(.*)$/))) {
      if (req.method === 'POST') { res.writeHead(202, {Location: `/v2/${m[1]}/blobs/uploads/${randomUUID()}?state=x`}); return res.end(); }
      if (req.method === 'PUT') {
        const want = url.searchParams.get('digest');
        if (digest(body) !== want) { res.writeHead(400); return res.end('DIGEST_INVALID'); }
        blobs.set(`${m[1]}@${want}`, body); res.writeHead(201); return res.end();
      }
    }
    if ((m = url.pathname.match(/^\/v2\/(.+)\/blobs\/(sha256:[0-9a-f]{64})$/))) {
      const blob = blobs.get(`${m[1]}@${m[2]}`);
      if (!blob) { res.writeHead(404); return res.end(); }
      const sent = Buffer.from(blob);
      if (existsSync(`${dir}/corrupt`) && m[1].includes(readFileSync(`${dir}/corrupt`, 'utf8'))) sent[0] ^= 1;
      res.writeHead(200, {'Content-Length': sent.length});
      return res.end(req.method === 'HEAD' ? undefined : sent);
    }
    if ((m = url.pathname.match(/^\/v2\/(.+)\/manifests\/([^/]+)$/))) {
      const key = `${m[1]}:${m[2]}`;
      if (req.method === 'PUT') {
        const manifest = JSON.parse(body);
        if (manifest.manifests ? !manifest.manifests.every((d) => manifests.has(`${m[1]}:${d.digest}`))
          : ![manifest.config, ...manifest.layers].every((d) => blobs.has(`${m[1]}@${d.digest}`))) { res.writeHead(400); return res.end('MANIFEST_BLOB_UNKNOWN'); }
        const stored = {body, type: req.headers['content-type'] ?? 'application/vnd.oci.image.manifest.v1+json'};
        manifests.set(key, stored); manifests.set(`${m[1]}:${digest(body)}`, stored); res.writeHead(201); return res.end();
      }
      const manifest = manifests.get(key);
      if (!manifest) { res.writeHead(404); return res.end(); }
      res.writeHead(200, {'Content-Type': existsSync(`${dir}/retype`) ? 'application/vnd.oci.image.manifest.v1+json' : manifest.type,
        'Docker-Content-Digest': digest(manifest.body)});
      return res.end(req.method === 'HEAD' ? undefined : manifest.body);
    }
    res.writeHead(404); res.end();
  });
});
server.listen(0, '127.0.0.1', () => writeFileSync(`${dir}/port`, String(server.address().port)));
EOF
node "$work/registry.mjs" "$work/registry" & registry_pid=$!
for _ in $(seq 50); do [ -s "$work/registry/port" ] && break; sleep 0.1; done
[ -s "$work/registry/port" ] || fail 'the fixture registry did not start'
PORT="$(cat "$work/registry/port")"
# The pipeline names https://<REGISTRY>/v2/; the fixture serves plain http on its own port. The upstreams
# of the tools (any asset of a GitHub Release) and of the fixture charts are files under upstream-files/, and
# each read of one is logged; an asset no file stands for is no read of GitHub, it fails.
mkdir -p "$work/upstream-files"
cat > "$work/standin-bin/curl" <<EOF
#!/usr/bin/env bash
args=()
for a in "\$@"; do
  if [[ "\$a" =~ ^https://((github\.com/[^/]+/[^/]+/releases/download|charts\.example\.invalid)/.*)\$ ]]; then
    echo "curl \$a" >> "$work/upstream.log"
    a="file://$work/upstream-files/\${BASH_REMATCH[1]}"
  fi
  [[ "\$a" =~ ^https://[^/]+(/v2/.*)\$ ]] && a="http://127.0.0.1:${PORT}\${BASH_REMATCH[1]}"
  args+=("\$a")
done
exec "${real_curl}" "\${args[@]}"
EOF
chmod +x "$work/standin-bin/curl"
export REGISTRY=registry.test OWNER=digitaplatform REPO_URL=https://github.com/digitaplatform/digita-deploy.git
COMMIT="$(printf 'c%.0s' {1..40})"
export COMMIT REGISTRY_USERNAME=fixture-push REGISTRY_PASSWORD=fixture-password
push() { # $1 the folder of tarballs -> the exit status of npm_push, its output in $work/push.out
  npm_push "$1" "$work/push-tmp" > "$work/push.out" 2>&1
}
pushes() { grep -c '^PUT /v2/.*/manifests/' "$work/registry/requests.log"; }
packed "$work/p1"; rm "$work/p1/publishable.tsv"
push "$work/p1" || fail "PLANTED INNOCENT: two new tarballs were not published: $(cat "$work/push.out")"
for f in "$work/p1"/*.tgz; do
  hex="$(sha256sum "$f" | cut -d' ' -f1)"; name="$(tar -xzOf "$f" package/package.json | jq -r '.name + "@" + .version')"
  pkg="${name#@digitaplatform/}"; pkg="${pkg%@*}"
  grep -qxF "publish: ${name} https://registry.test/v2/npm/digitaplatform/${pkg}/blobs/sha256:${hex} sha256:${hex} published" "$work/push.out" \
    || fail "the log carries no line for ${name} with its blob URL, its digest and published: $(cat "$work/push.out")"
  manifest="$(command curl -sS -u "${REGISTRY_USERNAME}:${REGISTRY_PASSWORD}" "http://127.0.0.1:$PORT/v2/npm/digitaplatform/${pkg}/manifests/${name##*@}")"
  [ "$(jq -r '[(.layers | length), .layers[0].digest, .annotations["org.opencontainers.image.revision"], .annotations["org.opencontainers.image.source"], .annotations["org.opencontainers.image.version"]] | join(" ")' <<<"$manifest")" \
    = "1 sha256:${hex} ${COMMIT} ${REPO_URL} ${name##*@}" ] || fail "the manifest of ${name} is not one layer of the tarball with its revision, source and version: $manifest"
  [ "$(command curl -sS -u "${REGISTRY_USERNAME}:${REGISTRY_PASSWORD}" "http://127.0.0.1:$PORT/v2/npm/digitaplatform/${pkg}/blobs/sha256:${hex}" | sha256sum | cut -d' ' -f1)" = "$hex" ] \
    || fail "the blob of ${name} is not the tarball"
done
ok 'each new tarball is published as npm/<scope>/<name>:<version>, one layer, revision, source and version, and logged with its blob URL and digest'
before="$(pushes)"
push "$work/p1" || fail "a second run of the same tarballs failed: $(cat "$work/push.out")"
[ "$(grep -c ' reused$' "$work/push.out")" = 2 ] && [ "$(pushes)" = "$before" ] || fail "a second run pushed again or did not say reused: $(cat "$work/push.out")"
ok 'a second run of the same tarballs reuses them and pushes nothing'
mkdir -p "$work/p2"
tgz "$work/p2/digitaplatform-minimal-0.4.13.tgz" "$(json '{"name":"@digitaplatform/minimal","version":"0.4.13"}')" "dist/index.js=export const x = 2;"
tgz "$work/p2/digitaplatform-fresh-1.0.0.tgz" "$(json '{"name":"@digitaplatform/fresh","version":"1.0.0"}')"
before="$(pushes)"
push "$work/p2" && fail 'PLANTED DEFECT: another content under a published version was pushed'
grep -qF '@digitaplatform/minimal@0.4.13 stands in registry.test/npm/digitaplatform/minimal with other content' "$work/push.out" || fail "the refusal does not name the version: $(cat "$work/push.out")"
[ "$(pushes)" = "$before" ] && ! grep -q '/npm/digitaplatform/fresh/blobs/uploads' "$work/registry/requests.log" \
  || fail 'a run with one refused tarball still pushed another'
ok 'another content under a published version is refused, and nothing of that run is pushed'
mkdir -p "$work/p3"; tgz "$work/p3/other-x-1.0.0.tgz" "$(json '{"name":"@other/x","version":"1.0.0"}')"
push "$work/p3" && fail 'PLANTED DEFECT: a package of another scope than the repository owner was pushed'
grep -qF '@other/x is not of the scope @digitaplatform' "$work/push.out" || fail "the scope refusal does not say so: $(cat "$work/push.out")"
mkdir -p "$work/p4"; tgz "$work/p4/digitaplatform-x-1.0.0.tgz" "$(json '{"name":"@digitaplatform/x","version":"1.0.0+build.1"}')"
push "$work/p4" && fail 'PLANTED DEFECT: a version that is no OCI tag was pushed'
grep -qF 'version 1.0.0+build.1 of @digitaplatform/x is no tag' "$work/push.out" || fail "the version refusal does not say so: $(cat "$work/push.out")"
mkdir -p "$work/p5"
push "$work/p5" && fail 'PLANTED DEFECT: a run that packed nothing passed'
ok 'another scope, a version that is no tag and an empty pack are refused'
mkdir -p "$work/p6"; tgz "$work/p6/digitaplatform-readback-1.0.0.tgz" "$(json '{"name":"@digitaplatform/readback","version":"1.0.0"}')"
touch "$work/registry/corrupt"
push "$work/p6" && fail 'PLANTED DEFECT: a blob that reads back with other bytes passed'
grep -qF 'reads back' "$work/push.out" || fail "the readback refusal does not say so: $(cat "$work/push.out")"
rm "$work/registry/corrupt"
REGISTRY_PASSWORD=wrong push "$work/p6" && fail 'PLANTED DEFECT: a push the registry answered 401 passed'
grep -qF 'answered 401' "$work/push.out" || fail "a refused login does not name the answer: $(cat "$work/push.out")"
ok 'a blob that reads back other bytes and a refused login fail the push'

# ── binaries_push: one manifest <owner>/<repository>:<tag>, a layer per binary ─────────────
export BINARIES_REPOSITORY=simetrixch/ansiwise-cli RELEASE_TAG=1.0.000-stable-20261014000000
binaries() { binaries_push "$1" "$work/bin-tmp" > "$work/push.out" 2>&1; } # $1 the folder of binaries
mkdir -p "$work/b1"; printf 'one' > "$work/b1/ansiwise-$RELEASE_TAG-linux-x64"; printf 'two' > "$work/b1/ansiwise-rest-$RELEASE_TAG-linux-x64"
binaries "$work/b1" || fail "PLANTED INNOCENT: two new binaries were not published: $(cat "$work/push.out")"
manifest="$(command curl -sS -u "${REGISTRY_USERNAME}:${REGISTRY_PASSWORD}" "http://127.0.0.1:$PORT/v2/simetrixch/ansiwise-cli/manifests/$RELEASE_TAG")"
for f in "$work/b1"/*; do
  hex="$(sha256sum "$f" | cut -d' ' -f1)"
  grep -qxF "publish: ${f##*/} https://registry.test/v2/simetrixch/ansiwise-cli/blobs/sha256:${hex} sha256:${hex} published" "$work/push.out" \
    || fail "the log carries no line for ${f##*/} with its blob URL and digest: $(cat "$work/push.out")"
  [ "$(jq -r --arg d "sha256:$hex" '.layers[] | select(.digest == $d) | .mediaType + " " + .annotations["org.opencontainers.image.title"]' <<<"$manifest")" \
    = "application/octet-stream ${f##*/}" ] || fail "the manifest carries no octet-stream layer titled ${f##*/}: $manifest"
done
[ "$(jq -r '[(.layers | length), .artifactType, .config.mediaType, .annotations["org.opencontainers.image.revision"], .annotations["org.opencontainers.image.source"], .annotations["org.opencontainers.image.version"]] | join(" ")' <<<"$manifest")" \
  = "2 application/vnd.simetrixch.binaries.v1 application/vnd.oci.empty.v1+json ${COMMIT} ${REPO_URL} ${RELEASE_TAG}" ] \
  || fail "the manifest is not two layers with the artifact type, an empty config, revision, source and version: $manifest"
ok 'the binaries of a release are one manifest <owner>/<repository>:<tag>, a titled octet-stream layer each, logged with blob URL and digest'
before="$(pushes)"
binaries "$work/b1" || fail "a second run of the same binaries failed: $(cat "$work/push.out")"
[ "$(grep -c ' reused$' "$work/push.out")" = 2 ] && [ "$(pushes)" = "$before" ] || fail "a second run pushed again or did not say reused: $(cat "$work/push.out")"
ok 'a second run of the same binaries reuses them and pushes nothing'
mkdir -p "$work/b2"; printf 'one' > "$work/b2/ansiwise-$RELEASE_TAG-linux-x64"; printf 'rebuilt' > "$work/b2/ansiwise-rest-$RELEASE_TAG-linux-x64"
binaries "$work/b2" && fail 'PLANTED DEFECT: another build under a published release tag was pushed'
grep -qF "simetrixch/ansiwise-cli:$RELEASE_TAG stands in registry.test with other binaries" "$work/push.out" || fail "the refusal does not name the release: $(cat "$work/push.out")"
[ "$(pushes)" = "$before" ] && ! grep -q "sha256:$(printf rebuilt | sha256sum | cut -d' ' -f1)" "$work/registry/requests.log" \
  || fail 'a refused build still pushed a blob or a manifest'
mkdir -p "$work/b3"
binaries "$work/b3" && fail 'PLANTED DEFECT: a build that left no binary passed'
mkdir -p "$work/b4"; printf 'x' > "$work/b4/ansiwise-$RELEASE_TAG-linux-x64"
RELEASE_TAG='1.0.0+build' binaries "$work/b4" && fail 'PLANTED DEFECT: a release tag that is no registry tag was pushed'
touch "$work/registry/corrupt"
RELEASE_TAG=1.0.001-stable-20261014000000 binaries "$work/b4" && fail 'PLANTED DEFECT: a binary that reads back with other bytes passed'
grep -qF 'reads back' "$work/push.out" || fail "the readback refusal does not say so: $(cat "$work/push.out")"
rm "$work/registry/corrupt"
ok 'another build under a published tag, an empty build, a tag the registry cannot carry and a changed readback are refused'

# ── mirror_copy and mirror_read_back: the images of the platform tree, in the mirror ───────
# ghcr.io as a stand-in skopeo sees it: under upstream/, every blob and manifest by its digest and
# every tag as the digest it names. The stand-in reads a tag, and copies an image by its digest to
# the fixture registry, blobs first, as skopeo does: an index with every manifest under --all and
# with its first only without, and every manifest as its bytes under --preserve-digests and written
# again without, as a conversion would write it.
mkdir -p "$work/upstream/blobs"
cat > "$work/standin-bin/skopeo" <<EOF
#!/usr/bin/env bash
set -uo pipefail
echo "skopeo \$*" >> "$work/skopeo.log"
up="$work/upstream"
command="\$1"; shift
all=no preserve=no auth="" refs=()
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    --all) all=yes ;;
    --preserve-digests) preserve=yes ;;
    --dest-authfile) auth="\$2"; shift ;;
    --retry-times) shift ;;
    --*) ;;
    *) refs+=("\$1") ;;
  esac
  shift
done
if [ "\$command" = inspect ]; then
  [[ "\${refs[0]}" =~ ^docker://ghcr\.io/(.+):([^:/]+)\$ ]] && [ -f "\$up/\${BASH_REMATCH[1]}/tags/\${BASH_REMATCH[2]}" ] \
    || { echo "skopeo: manifest unknown: \${refs[0]}" >&2; exit 1; }
  exec cat "\$up/blobs/\$(cat "\$up/\${BASH_REMATCH[1]}/tags/\${BASH_REMATCH[2]}")"
fi
[ "\$command" = copy ] && [[ "\${refs[0]}" =~ ^docker://ghcr\.io/.+@(sha256:[0-9a-f]{64})\$ ]] || { echo "skopeo: no copy of an image by its digest: \$*" >&2; exit 1; }
source="\${BASH_REMATCH[1]}"
[[ "\${refs[1]}" =~ ^docker://([^/]+)/(.+):([^:/]+)\$ ]] || { echo "skopeo: no destination by tag: \${refs[1]}" >&2; exit 1; }
host="\${BASH_REMATCH[1]}" repository="\${BASH_REMATCH[2]}" tag="\${BASH_REMATCH[3]}"
login="\$(jq -r --arg host "\$host" '.auths[\$host].auth' "\$auth" | base64 -d)" || exit 1
call() { "${real_curl}" -fsS -u "\$login" "\$@"; }
put_blob() { # <digest>
  local location
  location="\$(call -X POST -D - -o /dev/null "http://127.0.0.1:${PORT}/v2/\$repository/blobs/uploads/" | tr -d '\r' | sed -n 's/^Location: //p')" || return 1
  call -X PUT --data-binary "@\$up/blobs/\$1" "http://127.0.0.1:${PORT}\${location}&digest=\$1" -o /dev/null
}
put_manifest() { # <digest> <reference>
  local body="\$up/blobs/\$1" child
  [ -f "\$body" ] || { echo "skopeo: ghcr.io names no manifest \$1" >&2; return 1; }
  if jq -e '.manifests' "\$body" > /dev/null; then
    if [ "\$all" = no ]; then put_manifest "\$(jq -r '.manifests[0].digest' "\$body")" "\$2"; return; fi
    for child in \$(jq -r '.manifests[].digest' "\$body"); do put_manifest "\$child" "\$child" || return 1; done
  else
    for child in \$(jq -r '.config.digest, .layers[].digest' "\$body"); do put_blob "\$child" || return 1; done
  fi
  if [ "\$preserve" = yes ]; then cp "\$body" "\$up/sent"; else jq -c . "\$body" > "\$up/sent"; fi
  call -X PUT -H "Content-Type: \$(jq -r .mediaType "\$body")" --data-binary "@\$up/sent" "http://127.0.0.1:${PORT}/v2/\$repository/manifests/\$2" -o /dev/null
}
put_manifest "\$source" "\$tag"
EOF
chmod +x "$work/standin-bin/skopeo"
upstream_blob() { # standard input -> its digest, the blob stored under it upstream
  local hex
  cat > "$work/upstream/incoming"; hex="$(sha256sum "$work/upstream/incoming" | cut -d' ' -f1)"
  mv "$work/upstream/incoming" "$work/upstream/blobs/sha256:$hex"; printf 'sha256:%s' "$hex"
}
upstream_tag() { mkdir -p "$work/upstream/$1/tags"; printf '%s' "$3" > "$work/upstream/$1/tags/$2"; } # <path> <tag> <digest>
upstream_image() { # <manifest media type> <layer media type> <layer bytes> -> the digest of a manifest of one layer, written as a person reads it
  local config layer
  config="$(printf '{"architecture":"amd64","os":"linux"}' | upstream_blob)"; layer="$(printf '%s' "$3" | upstream_blob)"
  jq -n --arg type "$1" --arg config "$config" --arg ltype "$2" --arg layer "$layer" \
    '{schemaVersion: 2, mediaType: $type, config: {mediaType: "application/vnd.oci.image.config.v1+json", digest: $config, size: 37}, layers: [{mediaType: $ltype, digest: $layer, size: 1}]}' | upstream_blob
}
oci_image="$(upstream_image application/vnd.oci.image.manifest.v1+json application/vnd.oci.image.layer.v1.tar+gzip one)"
upstream_tag fixture/one 1.0.0 "$oci_image"
v2s2_amd64="$(upstream_image application/vnd.docker.distribution.manifest.v2+json application/vnd.docker.image.rootfs.diff.tar.gzip amd64)"
v2s2_arm64="$(upstream_image application/vnd.docker.distribution.manifest.v2+json application/vnd.docker.image.rootfs.diff.tar.gzip arm64)"
v2s2_list="$(jq -n --arg a "$v2s2_amd64" --arg b "$v2s2_arm64" '{schemaVersion: 2, mediaType: "application/vnd.docker.distribution.manifest.list.v2+json",
  manifests: [{mediaType: "application/vnd.docker.distribution.manifest.v2+json", digest: $a, size: 1, platform: {architecture: "amd64", os: "linux"}},
    {mediaType: "application/vnd.docker.distribution.manifest.v2+json", digest: $b, size: 1, platform: {architecture: "arm64", os: "linux"}}]}' | upstream_blob)"
upstream_tag fixture/multi 2.0 "$v2s2_list"
oci_amd64="$(upstream_image application/vnd.oci.image.manifest.v1+json application/vnd.oci.image.layer.v1.tar+gzip index-amd64)"
oci_arm64="$(upstream_image application/vnd.oci.image.manifest.v1+json application/vnd.oci.image.layer.v1.tar+gzip index-arm64)"
oci_index="$(jq -n --arg a "$oci_amd64" --arg b "$oci_arm64" '{schemaVersion: 2, mediaType: "application/vnd.oci.image.index.v1+json",
  manifests: [{mediaType: "application/vnd.oci.image.manifest.v1+json", digest: $a, size: 1, platform: {architecture: "amd64", os: "linux"}},
    {mediaType: "application/vnd.oci.image.manifest.v1+json", digest: $b, size: 1, platform: {architecture: "arm64", os: "linux"}}]}' | upstream_blob)"
upstream_tag fixture/index 3.0 "$oci_index"
entry() { printf 'ghcr.io/%s %s/%s/ghcr.io/%s\n' "$1" "${2:-registry.test}" "${3:-simetrixch}" "$1"; } # <path>:<tag>@<digest> [registry] [owner]
mirror() { # $1 the list -> the exit status of mirror_copy and then mirror_read_back, their output in $work/mirror.out
  rm -rf "$work/mirror-tmp"
  { OWNER=simetrixch mirror_copy "$1" "$work/mirror-tmp/copy" && mirror_read_back "$1" "$work/mirror-tmp/read"; } > "$work/mirror.out" 2>&1
}
{ entry "fixture/multi:2.0@$v2s2_list"; entry "fixture/one:1.0.0@$oci_image"; } > "$work/mirror.list"
mirror "$work/mirror.list" || fail "PLANTED INNOCENT: an OCI image and a Docker manifest list of two platforms were not mirrored: $(cat "$work/mirror.out")"
[ "$(grep '^mirror: ' "$work/mirror.out")" = "mirror: 2 images copied
mirror: registry.test/simetrixch/ghcr.io/fixture/multi:2.0@$v2s2_list application/vnd.docker.distribution.manifest.list.v2+json read back
mirror: registry.test/simetrixch/ghcr.io/fixture/one:1.0.0@$oci_image application/vnd.oci.image.manifest.v1+json read back" ] \
  || fail "the mirror does not log every image copied and read back at its digest and media type: $(cat "$work/mirror.out")"
for platform in "$v2s2_amd64" "$v2s2_arm64"; do
  [ "$(command curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/v2/simetrixch/ghcr.io/fixture/multi/manifests/$platform")" = 200 ] \
    || fail "the manifest $platform of the Docker manifest list was not copied beside it"
done
grep -q "^skopeo inspect --raw --no-creds .* docker://ghcr.io/fixture/one:1.0.0$" "$work/skopeo.log" \
  && grep -q "^skopeo copy .*--all --preserve-digests .*--src-no-creds .* docker://ghcr.io/fixture/one@$oci_image docker://registry.test/simetrixch/ghcr.io/fixture/one:1.0.0$" "$work/skopeo.log" \
  || fail "the copy was not made by the digest from the tag upstream, with every platform and its digests kept: $(cat "$work/skopeo.log")"
! grep -q 'fixture-password' "$work/skopeo.log" || fail 'the push credential reached the arguments of skopeo'
ok 'the mirror copies every entry by its digest with every platform, logs it, and reads it back without a login at that digest and its media type'
mirror "$work/mirror.list" || fail "a second run of the same list failed: $(cat "$work/mirror.out")"
ok 'a second run of the same list copies and reads back the same digests'

moved="$(upstream_image application/vnd.oci.image.manifest.v1+json application/vnd.oci.image.layer.v1.tar+gzip moved)"
upstream_tag fixture/one 1.0.0 "$moved"
mirror "$work/mirror.list" && fail 'PLANTED DEFECT: a tag that names another digest upstream than the tree pins was mirrored'
grep -qF "mirror: FAIL — ghcr.io/fixture/one:1.0.0 names $moved upstream, and the tree pins $oci_image" "$work/mirror.out" \
  || fail "the refusal does not name the tag and both digests: $(cat "$work/mirror.out")"
upstream_tag fixture/one 1.0.0 "$oci_image"
entry "fixture/gone:1.0.0@$oci_image" > "$work/mirror-gone.list"
mirror "$work/mirror-gone.list" && fail 'PLANTED DEFECT: an image that ghcr.io does not hold passed'
grep -qF 'mirror: FAIL — ghcr.io/fixture/gone:1.0.0 cannot be read upstream' "$work/mirror.out" || fail "the missing source is not named: $(cat "$work/mirror.out")"
for list in "ghcr.io/fixture/one:1.0.0 registry.test/simetrixch/ghcr.io/fixture/one:1.0.0" "$(entry "fixture/one:1.0.0@$oci_image" registry.test other)" \
  "docker.io/fixture/one:1.0.0@$oci_image registry.test/simetrixch/docker.io/fixture/one:1.0.0@$oci_image"; do
  printf '%s\n' "$list" > "$work/mirror-shape.list"
  mirror "$work/mirror-shape.list" && fail "PLANTED DEFECT: the entry '$list' was copied"
  grep -qF 'mirror: REFUSE — ' "$work/mirror.out" || fail "the entry '$list' was not refused by its shape: $(cat "$work/mirror.out")"
done
ok 'a tag that moved upstream, a source that is gone, a ref without its digest, another owner and another registry are refused by name'
# A copy that wrote another digest, an index copied as one platform, and a manifest served as another media
# type all stand in the mirror under the tag, and none of them is the image the tree pins.
extract mirror_copy | sed 's/ --preserve-digests//' > "$work/mirror_copy-converting.sh"
( . "$work/mirror_copy-converting.sh"; entry "fixture/one:1.0.0@$oci_image" | sed 's|/fixture/one|/fixture/converted|g' > "$work/mirror-converted.list"
  mkdir -p "$work/upstream/fixture/converted/tags"; cp "$work/upstream/fixture/one/tags/1.0.0" "$work/upstream/fixture/converted/tags/"
  mirror "$work/mirror-converted.list" ) && fail 'PLANTED DEFECT: a copy that changed the digest read back'
grep -qF "mirror: FAIL — registry.test/simetrixch/ghcr.io/fixture/converted:1.0.0@$oci_image answers 404" "$work/mirror.out" \
  || fail "a copy that changed the digest is not named at its read-back: $(cat "$work/mirror.out")"
extract mirror_copy | sed 's/ --all//' > "$work/mirror_copy-one-platform.sh"
( . "$work/mirror_copy-one-platform.sh"; entry "fixture/multi:2.0@$v2s2_list" | sed 's|/fixture/multi|/fixture/single|g' > "$work/mirror-single.list"
  mkdir -p "$work/upstream/fixture/single/tags"; cp "$work/upstream/fixture/multi/tags/2.0" "$work/upstream/fixture/single/tags/"
  mirror "$work/mirror-single.list" ) && fail 'PLANTED DEFECT: an index copied as one platform read back'
grep -qF "mirror: FAIL — registry.test/simetrixch/ghcr.io/fixture/single:2.0@$v2s2_list answers 404" "$work/mirror.out" \
  || fail "an index copied as one platform is not named at its read-back: $(cat "$work/mirror.out")"
touch "$work/registry/retype"
mirror "$work/mirror.list" && fail 'PLANTED DEFECT: a Docker manifest list served as an OCI image manifest read back'
grep -qF "mirror: FAIL — registry.test/simetrixch/ghcr.io/fixture/multi:2.0@$v2s2_list is served as $v2s2_list and application/vnd.oci.image.manifest.v1+json" "$work/mirror.out" \
  || fail "the media type the registry serves is not named: $(cat "$work/mirror.out")"
rm "$work/registry/retype"
ok 'a copy that changed the digest, an index copied as one platform and a manifest served as another media type fail the read-back by name'

# ── the tools and charts of the platform tree: the list, fetch, copy-sources and read-back-sources ──
# helm as the steps call it, a pull. charts.example.invalid stands for an upstream, a chart repository
# index or an oci registry, whose packaged charts are files under upstream-files/; every read of one is
# logged. Any other oci registry is the fixture registry, read without a login through the stand-in curl
# as helm reads a chart: the manifest by its tag, a config of the helm media type that names the chart and
# its version and whose text fields are strings, as helm unmarshals them, and the one chart layer, each blob
# as the bytes of its digest. Every other command is the real helm, which renders the Pipeline below and
# shows a chart.
cat > "$work/standin-bin/helm" <<EOF
#!/usr/bin/env bash
set -uo pipefail
[ "\${1:-}" = pull ] || exec "${real_helm}" "\$@"
shift
ref="" repo="" version="" dest=.
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    --repo) repo="\$2"; shift ;;
    --version) version="\$2"; shift ;;
    --destination) dest="\$2"; shift ;;
    *) ref="\$1" ;;
  esac
  shift
done
upstream() { # <path under upstream-files>
  echo "helm pull \$1" >> "$work/upstream.log"
  [ -f "$work/upstream-files/\$1" ] || { echo "Error: chart \$ref version \$version not found" >&2; exit 1; }
  exec cp "$work/upstream-files/\$1" "\$dest/"
}
if [ -n "\$repo" ]; then
  [[ "\$repo" =~ ^https://(charts\.example\.invalid(/.*)?)\$ ]] || { echo "Error: no fixture repository \$repo" >&2; exit 1; }
  upstream "\${BASH_REMATCH[1]}/\$ref-\$version.tgz"
fi
[[ "\$ref" =~ ^oci://(([^/]+)/(.+))/([^/]+)\$ ]] || { echo "Error: invalid chart reference \$ref" >&2; exit 1; }
[ "\${BASH_REMATCH[2]}" != charts.example.invalid ] || upstream "\${BASH_REMATCH[1]}/\${BASH_REMATCH[4]}-\$version.tgz"
chart="\${BASH_REMATCH[4]}" base="https://\${BASH_REMATCH[2]}/v2/\${BASH_REMATCH[3]}/\${BASH_REMATCH[4]}"
tmp="\$(mktemp -d)" && trap 'rm -rf "\$tmp"' EXIT || exit 1
blob() { # <digest> <file>: the blob, held to its digest
  curl -fsS -o "\$2" "\$base/blobs/\$1" && [ "sha256:\$(sha256sum "\$2" | cut -d' ' -f1)" = "\$1" ]
}
curl -fsS -H 'Accept: application/vnd.oci.image.manifest.v1+json' -o "\$tmp/manifest" "\$base/manifests/\$version" \
  || { echo "Error: \$ref:\$version: not found" >&2; exit 1; }
jq -e '.config.mediaType == "application/vnd.cncf.helm.config.v1+json" and (.layers | length) == 1
  and .layers[0].mediaType == "application/vnd.cncf.helm.chart.content.v1.tar+gzip"' "\$tmp/manifest" > /dev/null \
  || { echo "Error: \$ref:\$version is no helm chart" >&2; exit 1; }
blob "\$(jq -r .config.digest "\$tmp/manifest")" "\$tmp/config" \
  && jq -e --arg chart "\$chart" --arg version "\$version" '(.name == \$chart) and (.version == \$version)' "\$tmp/config" > /dev/null \
  || { echo "Error: the config of \$ref:\$version names no chart \$chart \$version" >&2; exit 1; }
jq -e '[.apiVersion, .name, .version, .kubeVersion, .description, .type, .home, .icon, .appVersion, .condition, .tags,
  (.keywords // [])[], (.sources // [])[], (.annotations // {})[]] | map(select(. != null)) | all(type == "string")' "\$tmp/config" > /dev/null \
  || { echo "Error: the config of \$ref:\$version carries a text field that is no string" >&2; exit 1; }
blob "\$(jq -r '.layers[0].digest' "\$tmp/manifest")" "\$tmp/chart.tgz" || { echo "Error: the chart layer of \$ref:\$version is not its digest" >&2; exit 1; }
mv "\$tmp/chart.tgz" "\$dest/\$chart-\$version.tgz"
EOF
chmod +x "$work/standin-bin/helm"
upstream_file() { # <path under upstream-files> <bytes> -> the sha256 of the file written there
  mkdir -p "$work/upstream-files/$(dirname "$1")" && printf '%s' "$2" > "$work/upstream-files/$1" && sha256sum "$work/upstream-files/$1" | cut -d' ' -f1
}
upstream_chart() { # <path under upstream-files> <chart> <version> [<appVersion as Chart.yaml writes it>] -> the sha256 of the packaged chart written there as <chart>-<version>.tgz
  mkdir -p "$work/chart-src/$2" "$work/upstream-files/$1"
  printf 'apiVersion: v2\nname: %s\nversion: %s\nappVersion: %s\n' "$2" "$3" "${4:-\"1.0\"}" > "$work/chart-src/$2/Chart.yaml"
  tar -czf "$work/upstream-files/$1/$2-$3.tgz" -C "$work/chart-src" "$2" && rm -rf "$work/chart-src"
  sha256sum "$work/upstream-files/$1/$2-$3.tgz" | cut -d' ' -f1
}
tool_url=https://github.com/fixture/tool/releases/download/v1.0.0/tool-linux-amd64
tool_hex="$(upstream_file github.com/fixture/tool/releases/download/v1.0.0/tool-linux-amd64 'the fixture tool 1.0.0')"
chart_hex="$(upstream_chart charts.example.invalid fixture-chart 1.0.0)"

# The list: one line per row, both names under global.buildRegistry, and a row of another form refused by its line.
owned="$(yq '.global.buildRegistry' "$root/clusters/platform/values-common.yaml")"
printf '# a comment\n\ntool %s %s\nchart https://charts.example.invalid fixture-chart 1.0.0 %s # a comment after a row\n' "$tool_url" "$tool_hex" "$chart_hex" > "$work/sources.table"
bash "$root/scripts/list-mirror-sources.sh" "$work/sources.table" > "$work/sources.lines" 2>&1 || fail "PLANTED INNOCENT: a tool row and a chart row were not listed: $(cat "$work/sources.lines")"
[ "$(cat "$work/sources.lines")" = "tool $tool_url $tool_hex $owned/github.com/fixture/tool/releases/download/v1.0.0/tool-linux-amd64:v1.0.0 https://${owned%%/*}/v2/${owned#*/}/github.com/fixture/tool/releases/download/v1.0.0/tool-linux-amd64/blobs/sha256:$tool_hex
chart https://charts.example.invalid fixture-chart 1.0.0 $chart_hex $owned/charts.example.invalid/fixture-chart:1.0.0 oci://$owned/charts.example.invalid" ] \
  || fail "the list does not name each row under $owned as the mirror serves it: $(cat "$work/sources.lines")"
ok 'the list writes one line per row of the table, with the tag it stands under and the address a consumer reads, under global.buildRegistry'
while IFS='|' read -r row reason; do
  printf 'tool %s %s\n%s\n' "$tool_url" "$tool_hex" "$row" > "$work/planted.table"
  bash "$root/scripts/list-mirror-sources.sh" "$work/planted.table" > "$work/sources.lines" 2>&1 && fail "PLANTED DEFECT: the row '$row' was listed"
  grep -qxF "list-mirror-sources: FAIL — $work/planted.table:2: $reason" "$work/sources.lines" || fail "the row '$row' is not refused by its line and its reason: $(cat "$work/sources.lines")"
done <<ROWS
tool $tool_hex|a row is tool <url> <sha256> or chart <repository> <chart> <version> <sha256>
tool https://github.com/Fixture/tool/releases/download/v1.0.0/tool-linux-amd64 $tool_hex|the url https://github.com/Fixture/tool/releases/download/v1.0.0/tool-linux-amd64 is no asset of a GitHub Release whose owner, name, tag and file are lower-case path components
tool https://github.com/fixture/tool/archive/v1.0.0.tar.gz $tool_hex|the url https://github.com/fixture/tool/archive/v1.0.0.tar.gz is no asset of a GitHub Release whose owner, name, tag and file are lower-case path components
chart https://charts.example.invalid/ fixture-chart 1.0.0 $chart_hex|the repository https://charts.example.invalid/ is neither a chart repository index over https nor an oci registry, by a lower-case host and path without a trailing slash
chart https://charts.example.invalid Fixture-Chart 1.0.0 $chart_hex|the chart Fixture-Chart is no lower-case path component
chart https://charts.example.invalid fixture-chart 1.0 $chart_hex|the version 1.0 is no chart version a registry can carry as a tag
tool $tool_url $(printf %s "$tool_hex" | tr a-f A-F)|the sha256 $(printf %s "$tool_hex" | tr a-f A-F) is not 64 lower-case hex digits
tool $tool_url $chart_hex|$owned/github.com/fixture/tool/releases/download/v1.0.0/tool-linux-amd64:v1.0.0 has a row above already
ROWS
ok 'a malformed row, an upper-case name, a tool url that is no Release asset, a chart repository with a trailing slash, a version that is no tag, a sha256 in upper case and a row that stands twice are refused by their line'

# The steps, on lines under the fixture registry, in the order the mirror runs them; the staging folder is
# the run's, and stays from one call to the next.
source_line() { OWNER=simetrixch mirror_source_line "$@"; }
tool_line="$(source_line tool "$tool_url" "$tool_hex")" chart_line="$(source_line chart https://charts.example.invalid fixture-chart 1.0.0 "$chart_hex")"
owned_reference() { read -r -a fields <<< "$1"; printf '%s' "${fields[${#fields[@]} - 2]}"; }
sources() { # $1 the list -> the exit status of fetch, copy-sources and read-back-sources run in order, their output in $work/sources.out
  rm -rf "$work/sources-tmp" "$work/upstream.log"
  { OWNER=simetrixch mirror_fetch "$1" "$work/sources-staged" "$work/sources-tmp/fetch" \
    && OWNER=simetrixch mirror_copy_sources "$1" "$work/sources-staged" "$work/sources-tmp/copy" \
    && OWNER=simetrixch mirror_read_back_sources "$1" "$work/sources-tmp/read"; } > "$work/sources.out" 2>&1
}
mirrored() { # <owned reference> -> the manifest it stands under, read without a login
  local path="${1#*/}"
  command curl -fsS -H 'Accept: application/vnd.oci.image.manifest.v1+json' "http://127.0.0.1:$PORT/v2/${path%:*}/manifests/${path##*:}"
}
printf '%s\n' "$tool_line" "$chart_line" > "$work/sources.list"
sources "$work/sources.list" || fail "PLANTED INNOCENT: a tool and a chart were not mirrored: $(cat "$work/sources.out")"
[ "$(grep '^mirror: ' "$work/sources.out")" = "mirror: $(owned_reference "$tool_line") fetched from $tool_url as sha256:$tool_hex
mirror: $(owned_reference "$chart_line") fetched from fixture-chart 1.0.0 of https://charts.example.invalid as sha256:$chart_hex
mirror: the tree at this tag names 2 tools and charts for the mirror: 2 fetched and held to their sha256, 0 already served
mirror: $(owned_reference "$tool_line") pushed
mirror: $(owned_reference "$chart_line") pushed
mirror: 2 tools and charts: 2 pushed, 0 kept
mirror: $(owned_reference "$tool_line") read back from https://registry.test/v2/simetrixch/github.com/fixture/tool/releases/download/v1.0.0/tool-linux-amd64/blobs/sha256:$tool_hex
mirror: $(owned_reference "$chart_line") read back from oci://registry.test/simetrixch/charts.example.invalid/fixture-chart
mirror: 2 of 2 tools and charts served" ] || fail "the steps do not log every row fetched, pushed and read back: $(cat "$work/sources.out")"
mirrored "$(owned_reference "$tool_line")" | jq -e --arg hex "sha256:$tool_hex" '.config.mediaType == "application/vnd.oci.empty.v1+json" and (.layers | length) == 1
  and .layers[0].digest == $hex and .layers[0].mediaType == "application/octet-stream" and .layers[0].annotations["org.opencontainers.image.title"] == "tool-linux-amd64"' > /dev/null \
  && mirrored "$(owned_reference "$chart_line")" | jq -e --arg hex "sha256:$chart_hex" '.config.mediaType == "application/vnd.cncf.helm.config.v1+json" and (.layers | length) == 1
  and .layers[0].digest == $hex and .layers[0].mediaType == "application/vnd.cncf.helm.chart.content.v1.tar+gzip"' > /dev/null \
  || fail "the tool or the chart does not stand as the one layer of its sha256 under the media types of its kind"
ok 'a tool and a chart are fetched, held to their sha256, pushed as the one layer of their kind and read back without a login, each counted'
before="$(pushes)"
mv "$work/upstream-files" "$work/upstream-files-away" && mkdir "$work/upstream-files"
sources "$work/sources.list" || fail "PLANTED INNOCENT: a second run of rows the mirror serves failed: $(cat "$work/sources.out")"
rm -rf "$work/upstream-files" && mv "$work/upstream-files-away" "$work/upstream-files"
grep -qxF 'mirror: the tree at this tag names 2 tools and charts for the mirror: 0 fetched and held to their sha256, 2 already served' "$work/sources.out" \
  && grep -qxF 'mirror: 2 tools and charts: 0 pushed, 2 kept' "$work/sources.out" && grep -qxF 'mirror: 2 of 2 tools and charts served' "$work/sources.out" \
  && [ ! -s "$work/upstream.log" ] && [ "$(pushes)" = "$before" ] \
  || fail "rows the mirror serves were downloaded or pushed again: $(cat "$work/sources.out") $(cat "$work/upstream.log" 2>/dev/null)"
ok 'rows the mirror already serves are neither downloaded nor pushed, and read back'
# A Chart.yaml that writes a text field as a number stands in the mirror with the config helm reads from the
# chart, where that field is text, so helm pulls it back, in this run and in the next.
numbered_hex="$(upstream_chart charts.example.invalid numbered-chart 1.0.0 1.10)"
source_line chart https://charts.example.invalid numbered-chart 1.0.0 "$numbered_hex" > "$work/sources-numbered.list"
numbered="$(owned_reference "$(cat "$work/sources-numbered.list")")"
sources "$work/sources-numbered.list" && grep -qxF "mirror: $numbered pushed" "$work/sources.out" && grep -qxF 'mirror: 1 of 1 tools and charts served' "$work/sources.out" \
  || fail "a chart whose Chart.yaml writes appVersion: 1.10 does not read back through helm: $(cat "$work/sources.out")"
sources "$work/sources-numbered.list" && grep -qxF "mirror: $numbered kept" "$work/sources.out" && grep -qxF 'mirror: 1 of 1 tools and charts served' "$work/sources.out" \
  || fail "a second run does not read back the chart whose Chart.yaml writes appVersion: 1.10: $(cat "$work/sources.out")"
ok 'a chart whose Chart.yaml writes appVersion: 1.10 is pushed with a config helm reads, and read back by the next run'

# What fetch refuses: an upstream that does not hold the row, and bytes that are not its sha256.
gone_url=https://github.com/fixture/gone/releases/download/v1.0.0/gone-linux-amd64
source_line tool "$gone_url" "$tool_hex" > "$work/sources-gone.list"
sources "$work/sources-gone.list" && fail 'PLANTED DEFECT: a tool its upstream does not hold passed'
grep -qF "mirror: FAIL — row $(owned_reference "$(cat "$work/sources-gone.list")"): $gone_url could not be fetched" "$work/sources.out" \
  || fail "a tool its upstream does not hold is not named by its row: $(cat "$work/sources.out")"
source_line chart https://charts.example.invalid fixture-chart 9.9.9 "$chart_hex" > "$work/sources-gone.list"
sources "$work/sources-gone.list" && fail 'PLANTED DEFECT: a chart version its repository does not hold passed'
grep -qF "mirror: FAIL — row $(owned_reference "$(cat "$work/sources-gone.list")"): fixture-chart 9.9.9 of https://charts.example.invalid could not be fetched" "$work/sources.out" \
  || fail "a chart version its repository does not hold is not named by its row: $(cat "$work/sources.out")"
moved_url=https://github.com/fixture/moved/releases/download/v1.0.0/moved-linux-amd64
moved_hex="$(upstream_file github.com/fixture/moved/releases/download/v1.0.0/moved-linux-amd64 'other bytes')"
source_line tool "$moved_url" "$tool_hex" > "$work/sources-moved.list"
sources "$work/sources-moved.list" && fail 'PLANTED DEFECT: upstream bytes that are not the row'\''s sha256 passed'
grep -qxF "mirror: FAIL — row $(owned_reference "$(cat "$work/sources-moved.list")"): $moved_url reads as sha256:$moved_hex, and the row pins sha256:$tool_hex" "$work/sources.out" \
  || fail "upstream bytes that are not the row's sha256 are not named by the row and both digests: $(cat "$work/sources.out")"
ok 'an upstream 404 of a tool and of a chart, and upstream bytes that differ from the row, stop fetch naming the row'

# What copy-sources refuses before it pushes anything: a staged file that changed after fetch, and a tag
# that stands in the mirror with another layer.
fresh_url=https://github.com/fixture/fresh/releases/download/v1.0.0/fresh-linux-amd64
fresh_hex="$(upstream_file github.com/fixture/fresh/releases/download/v1.0.0/fresh-linux-amd64 'a fresh tool')"
source_line tool "$fresh_url" "$fresh_hex" > "$work/sources-fresh.list"
OWNER=simetrixch mirror_fetch "$work/sources-fresh.list" "$work/sources-staged" "$work/sources-tmp/fetch" > "$work/sources.out" 2>&1 || fail "fetch failed: $(cat "$work/sources.out")"
printf 'changed' > "$work/sources-staged/$fresh_hex"
before="$(pushes)"
OWNER=simetrixch mirror_copy_sources "$work/sources-fresh.list" "$work/sources-staged" "$work/sources-tmp/copy" > "$work/sources.out" 2>&1 \
  && fail 'PLANTED DEFECT: a staged file changed between fetch and copy-sources was pushed'
grep -qxF "mirror: REFUSE — row $(owned_reference "$(cat "$work/sources-fresh.list")"): the file fetch staged for it is missing or is not sha256:$fresh_hex" "$work/sources.out" \
  && [ "$(pushes)" = "$before" ] || fail "a staged file that changed is not refused by its row before a push: $(cat "$work/sources.out")"
rm "$work/sources-staged/$fresh_hex"
taken_url=https://github.com/fixture/taken/releases/download/v1.0.0/taken-linux-amd64
taken_hex="$(upstream_file github.com/fixture/taken/releases/download/v1.0.0/taken-linux-amd64 'the taken tool')"
taken_line="$(source_line tool "$taken_url" "$taken_hex")"
other_hex="$(printf 'another layer' | sha256sum | cut -d' ' -f1)"
printf 'another layer' > "$work/other-layer"
taken="$(owned_reference "$taken_line")"; taken="${taken#*/}"
printf '{}' > "$work/empty.json"
empty_digest="sha256:$(sha256sum "$work/empty.json" | cut -d' ' -f1)"
push_blob "https://registry.test/v2/${taken%:*}" "$work/other-layer" "sha256:$other_hex" "$work" \
  && push_blob "https://registry.test/v2/${taken%:*}" "$work/empty.json" "$empty_digest" "$work" \
  && jq -n --arg empty "$empty_digest" --arg layer "sha256:$other_hex" \
    '{schemaVersion: 2, mediaType: "application/vnd.oci.image.manifest.v1+json", config: {mediaType: "application/vnd.oci.empty.v1+json", digest: $empty, size: 2},
      layers: [{mediaType: "application/octet-stream", digest: $layer, size: 13}]}' > "$work/taken.json" \
  && [ "$(registry_call /dev/null -X PUT -H 'Content-Type: application/vnd.oci.image.manifest.v1+json' --data-binary "@$work/taken.json" "https://registry.test/v2/${taken%:*}/manifests/${taken##*:}")" = 201 ] \
  || fail 'the fixture could not stand another layer under the tag'
printf '%s\n' "$(cat "$work/sources-fresh.list")" "$taken_line" > "$work/sources-taken.list"
before="$(pushes)"
sources "$work/sources-taken.list" && fail 'PLANTED DEFECT: a tag that stands in the mirror with another layer was replaced'
grep -qxF "mirror: REFUSE — row $(owned_reference "$taken_line"): the mirror answered 200 with the one layer sha256:$other_hex, not the one layer sha256:$taken_hex. A mirrored tool or chart is never replaced: give its row another version." "$work/sources.out" \
  && [ "$(pushes)" = "$before" ] || fail "a tag that stands with another layer is not refused by its row before anything is pushed: $(cat "$work/sources.out")"
ok 'a staged file changed after fetch and a tag that stands with another layer are refused by their row, and nothing is pushed'
# A mirror that does not answer says nothing about the tag: copy-sources fails naming what it found, and pushes nothing.
before="$(pushes)"
# shellcheck disable=SC2329 # mirror_source_held calls this curl, inside the subshell
(curl() { return 28; }; OWNER=simetrixch mirror_copy_sources "$work/sources-fresh.list" "$work/sources-staged" "$work/sources-tmp/copy") > "$work/sources.out" 2>&1 \
  && fail 'PLANTED DEFECT: copy-sources went on past a mirror it could not read'
grep -qxF "mirror: FAIL — row $(owned_reference "$(cat "$work/sources-fresh.list")"): the mirror was not read (curl exited 28), so what stands under its tag is not known, and nothing is pushed" "$work/sources.out" \
  && [ "$(pushes)" = "$before" ] || fail "a mirror that does not answer is not named as such by the row, or something was pushed: $(cat "$work/sources.out")"
ok 'a mirror that does not answer stops copy-sources naming the row and what it read, and nothing is pushed'

# A line that is not the line of its row under the owner is refused by each step, before it reads an upstream or pushes.
outside="$(source_line tool "$fresh_url" "$fresh_hex" | sed 's|/simetrixch/|/other/|g')"
printf '%s\n' "$outside" > "$work/sources-outside.list"
for step in mirror_fetch mirror_copy_sources; do
  rm -f "$work/upstream.log"; before="$(pushes)"
  OWNER=simetrixch "$step" "$work/sources-outside.list" "$work/sources-staged" "$work/sources-tmp/$step" > "$work/sources.out" 2>&1 && fail "PLANTED DEFECT: $step took a line outside the owner"
  grep -qxF "mirror: REFUSE — $outside is not the line of its row under registry.test/simetrixch, which is $(source_line tool "$fresh_url" "$fresh_hex")" "$work/sources.out" \
    && [ ! -s "$work/upstream.log" ] && [ "$(pushes)" = "$before" ] || fail "$step does not refuse a line outside the owner by name, before anything: $(cat "$work/sources.out")"
done
OWNER=simetrixch mirror_read_back_sources "$work/sources-outside.list" "$work/sources-tmp/read" > "$work/sources.out" 2>&1 && fail 'PLANTED DEFECT: read-back-sources passed a line outside the owner'
grep -qxF 'mirror: 0 of 1 tools and charts served' "$work/sources.out" || fail "read-back-sources counted a line outside the owner: $(cat "$work/sources.out")"
ok 'a line whose owned reference is outside the owner is refused by fetch, copy-sources and read-back-sources'

# What read-back-sources refuses: a mirror that serves other bytes, and one that serves nothing.
touch "$work/registry/corrupt"
OWNER=simetrixch mirror_read_back_sources "$work/sources.list" "$work/sources-tmp/read" > "$work/sources.out" 2>&1 && fail 'PLANTED DEFECT: a mirror that serves other bytes read back'
rm "$work/registry/corrupt"
grep -qF "mirror: FAIL — row $(owned_reference "$tool_line"): https://registry.test/v2/simetrixch/github.com/fixture/tool/releases/download/v1.0.0/tool-linux-amd64/blobs/sha256:$tool_hex reads back as sha256:" "$work/sources.out" \
  && grep -qF "mirror: FAIL — row $(owned_reference "$chart_line"): reading oci://registry.test/simetrixch/charts.example.invalid/fixture-chart failed (exit 1): Error: " "$work/sources.out" \
  && grep -qxF 'mirror: 0 of 2 tools and charts served' "$work/sources.out" || fail "other bytes are not named by each row: $(cat "$work/sources.out")"
printf '%s\n' "$(cat "$work/sources-fresh.list")" "$tool_line" > "$work/sources-unserved.list"
OWNER=simetrixch mirror_read_back_sources "$work/sources-unserved.list" "$work/sources-tmp/read" > "$work/sources.out" 2>&1 && fail 'PLANTED DEFECT: a row the mirror does not serve read back'
grep -qxF "mirror: FAIL — row $(owned_reference "$(cat "$work/sources-fresh.list")"): the mirror answered 404, not the one layer sha256:$fresh_hex" "$work/sources.out" \
  && grep -qxF 'mirror: 1 of 2 tools and charts served' "$work/sources.out" || fail "a row the mirror does not serve is not named, or the count is not of every row: $(cat "$work/sources.out")"
ok 'a mirror that serves other bytes or nothing fails read-back-sources, naming every row it does not serve'

# ── the rendered Pipeline, end to end ──────────────────────────────────────────────────────
# Every step of <unit>-publish as helm renders it, run on fixture repositories in Tekton's order, so
# a call dropped from a step, a step that runs another function, or a task out of its order goes red
# here although every function above stays green.
helm template consumer-build "$root/clusters/inventories/consumer-build" --namespace argocd \
  -f "$root/clusters/platform/values-common.yaml" -f "$root/clusters/platform/values-prod.yaml" \
  -f "$root/clusters/inventories/consumer-build/values-common.yaml" \
  -f "$root/scripts/standin/cluster-map.yaml" -f "$root/scripts/standin/registration.yaml" \
  --set-json "unit={\"name\":\"deploy\",\"repoURL\":\"${REPO_URL}\",\"buildsJson\":\"[]\"}" \
  | yq -o=json 'select(.kind == "Pipeline" and .metadata.name == "deploy-publish")' > "$work/pipeline.json" \
  && [ -s "$work/pipeline.json" ] || fail 'the chart renders no deploy-publish Pipeline for a unit without builds'
rendered_registry="$(jq -r '.spec.tasks[] | select(.name == "push") | .taskSpec.steps[0].env[] | select(.name == "REGISTRY") | .value' "$work/pipeline.json")"
rendered_npm="https://${rendered_registry}/v2/npm/"
# Tekton's part, as much of it as this Pipeline uses: the tasks in the order runAfter gives them, one at a
# time, as each works on what the one before left (a runAfter that lets two run at once fails the run), a
# task whose when does not hold skipped, the steps of a task in order, each script a file that runs by its
# own shebang with its env, an env taken from a key of a Secret, which the pod does not start without, and
# its envFrom, and the run failed at the first step that fails. A path the pod
# mounts (a workspace by its subPath, a volume, a step's own /tmp) is a folder of the run, written into
# the script and the environment of the step. The clone task, resolved from the cluster, is a git clone
# of the fixture origin at the revision it names, and only of the pinned repoURL.
cat > "$work/run-pipeline.mjs" <<'EOF'
import {spawnSync} from 'node:child_process';
import {chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync} from 'node:fs';
import {join} from 'node:path';
const [pipelineFile, run, origin, repoURL, paramsJson, secretsJson] = process.argv.slice(2);
const tasks = JSON.parse(readFileSync(pipelineFile, 'utf8')).spec.tasks, secrets = JSON.parse(secretsJson);
const scope = Object.fromEntries(Object.entries(JSON.parse(paramsJson)).map(([k, v]) => [`params.${k}`, v]));
const fill = (text, values) => String(text).replace(/\$\(([a-z.-]+)\)/g, (ref, key) => {
  if (!(key in values)) throw new Error(`nothing fills ${ref}`);
  return values[key];
});
const escape = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
// One pass over all mount paths, longest first, and before any $(...) is filled, so a folder of the run
// (which may itself lie under /tmp) is never mapped again.
const mount = (text, mounts) => text.replace(new RegExp(`(^|[\\s"'=:(])(${Object.keys(mounts).sort((a, b) => b.length - a.length).map(escape).join('|')})(?=/|$|[\\s"';)])`, 'gm'),
  (_, before, path) => before + mounts[path]);
const git = (...args) => spawnSync('git', args, {encoding: 'utf8'});
const secretKey = ({name, key}) => {
  if (secrets[name]?.[key] === undefined) throw new Error(`the Secret ${name} holds no key ${key}, so the pod does not start`);
  return secrets[name][key];
};
const done = new Set();
while (done.size < tasks.length) {
  const ready = tasks.filter((t) => !done.has(t.name) && (t.runAfter ?? []).every((n) => done.has(n)));
  if (ready.length !== 1) { console.log(`run: FAILED, runAfter lets ${ready.map((t) => t.name).join(' and ') || 'no task'} run next`); process.exit(1); }
  const [task] = ready;
  done.add(task.name);
  if (!(task.when ?? []).every((w) => (w.operator === 'in') === w.values.includes(fill(w.input, scope)))) {
    console.log(`run: ${task.name} skipped`);
    continue;
  }
  const params = Object.fromEntries((task.params ?? []).map((p) => [`params.${p.name}`, fill(p.value, scope)]));
  const workspace = (name) => join(run, 'workspace', (task.workspaces ?? []).find((w) => w.name === name).subPath ?? '');
  if (task.taskRef) {
    const dir = workspace('source');
    if (task.taskRef.params.find((p) => p.name === 'name').value !== 'git-clone' || params['params.url'] !== repoURL) {
      console.log(`run: ${task.name} failed, it is no clone of ${repoURL}`); process.exit(1);
    }
    const clone = git('clone', '-q', origin, dir), checkout = git('-C', dir, 'checkout', '-q', '--detach', params['params.revision']);
    if (clone.status || checkout.status) { console.log(`run: ${task.name} failed: ${clone.stderr}${checkout.stderr}`); process.exit(1); }
    scope[`tasks.${task.name}.results.commit`] = git('-C', dir, 'rev-parse', 'HEAD').stdout.trim();
    console.log(`run: ${task.name} ran`);
    continue;
  }
  const spec = task.taskSpec, base = join(run, task.name);
  const volumes = Object.fromEntries((spec.volumes ?? []).map((v) => {
    const dir = join(base, 'volumes', v.name);
    mkdirSync(dir, {recursive: true});
    for (const [key, value] of Object.entries(v.secret ? secrets[v.secret.secretName] ?? {} : {})) writeFileSync(join(dir, key), value);
    return [v.name, dir];
  }));
  const results = Object.fromEntries((spec.results ?? []).map((r) => [r.name, join(base, 'results', r.name)]));
  mkdirSync(join(base, 'results'), {recursive: true});
  const values = {...params, ...Object.fromEntries(Object.entries(results).map(([name, file]) => [`results.${name}.path`, file]))};
  for (const step of spec.steps) {
    const home = join(base, step.name);
    const mounts = {'/tmp': join(home, 'tmp'),
      ...Object.fromEntries((spec.workspaces ?? []).map((w) => [`/workspace/${w.name}`, workspace(w.name)])),
      ...Object.fromEntries((step.volumeMounts ?? []).map((m) => [m.mountPath, volumes[m.name]]))};
    Object.values(mounts).forEach((dir) => mkdirSync(dir, {recursive: true}));
    const env = {PATH: process.env.PATH, HOME: home, GIT_CONFIG_NOSYSTEM: '1',
      ...Object.assign({}, ...(step.envFrom ?? []).map((e) => secrets[e.secretRef.name] ?? {})),
      ...Object.fromEntries((step.env ?? []).map((e) => [e.name, e.valueFrom ? secretKey(e.valueFrom.secretKeyRef) : fill(mount(e.value, mounts), values)]))};
    const script = join(home, 'script');
    writeFileSync(script, fill(mount(step.script, mounts), values));
    chmodSync(script, 0o755);
    const ran = spawnSync(script, [], {cwd: step.workingDir ? mount(step.workingDir, mounts) : home, env, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024});
    process.stdout.write(ran.error ? `${ran.error}\n` : ran.stdout + ran.stderr);
    if (ran.status !== 0) { console.log(`run: ${task.name} failed at ${step.name}`); process.exit(1); }
  }
  for (const [name, file] of Object.entries(results)) scope[`tasks.${task.name}.results.${name}`] = existsSync(file) ? readFileSync(file, 'utf8') : '';
  console.log(`run: ${task.name} ran`);
}
console.log('run: SUCCEEDED');
EOF
cat > "$work/standin-bin/corepack" <<EOF
#!/bin/sh
echo "corepack \$*" >> "$work/corepack.log"
EOF
chmod +x "$work/standin-bin/corepack"
# A pod hands what root made to the user of the build with chown; whoever runs this test may give no file
# away, so the stand-in records what would be handed over.
cat > "$work/standin-bin/chown" <<EOF
#!/bin/sh
echo "chown \$*" >> "$work/chown.log"
EOF
chmod +x "$work/standin-bin/chown"
secrets="$(jq -nc --arg user "$REGISTRY_USERNAME" --arg password "$REGISTRY_PASSWORD" '{"build-git-https": {GITCREDENTIALS: "https://github.invalid"},
  "image-builder-registry-push": {REGISTRY_USERNAME: $user, REGISTRY_PASSWORD: $password}}')"
pipeline_run() { # $1 the fixture origin, $2 the release tag, [$3 the webhook's git-url] -> the run's status, its log in $work/run.out
  rm -rf "${work:?}/run" "${work:?}/corepack.log" "${work:?}/chown.log"; mkdir -p "$work/run"
  node "$work/run-pipeline.mjs" "$work/pipeline.json" "$work/run" "$1" "$REPO_URL" \
    "$(jq -nc --arg tag "$2" --arg url "${3:-$REPO_URL}" '{"release-tag": $tag, "git-url": $url}')" "$secrets" > "$work/run.out" 2>&1
}
tasks_ran() { grep '^run: ' "$work/run.out" | tr '\n' '|'; }
published() { # $1 name@version -> the published tarball's sha256, once its log line names the rendered registry
  local name="$1" pkg hex
  pkg="${name#@digitaplatform/}"; pkg="${pkg%@*}"
  hex="$(command curl -sS -u "${REGISTRY_USERNAME}:${REGISTRY_PASSWORD}" -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
    "http://127.0.0.1:$PORT/v2/npm/digitaplatform/${pkg}/manifests/${name##*@}" | jq -r '.layers[0].digest | ltrimstr("sha256:")')" || return 1
  grep -qxF "publish: ${name} https://${rendered_registry}/v2/npm/digitaplatform/${pkg}/blobs/sha256:${hex} sha256:${hex} published" "$work/run.out" || return 1
  printf '%s' "$hex"
}
blob() { command curl -sS -u "${REGISTRY_USERNAME}:${REGISTRY_PASSWORD}" "http://127.0.0.1:$PORT/v2/npm/digitaplatform/$1/blobs/sha256:$2"; }
ALL='run: gate ran|run: clone ran|run: scan ran|run: reviewed ran|run: pack ran|run: build-binaries skipped|run: push ran|run: SUCCEEDED|'
STAMP=20261014000000
origin() { repo "$1" "README.md=fixture"; } # $1 folder -> a fixture origin whose default branch master holds one commit
commit_tag() { git -C "$1" add -A && git -C "$1" commit -q -m "$2" && git -C "$1" tag "$2"; } # $1 origin, $2 the tag
# A source release: e2e-a builds dist/built.js and depends on e2e-b in the workspace; both declare 0.0.1,
# and the tag names 0.3.1.
manifest() { jq -n --arg name "$1" --arg npm "$rendered_npm" --argjson extra "${2:-"{}"}" '{name: $name, version: "0.0.1", publishConfig: {registry: $npm}} + $extra'; }
origin "$work/e6"; mkdir -p "$work/e6/a" "$work/e6/b"
json '{"name":"root","private":true,"version":"0.0.1"}' > "$work/e6/package.json"
printf 'packages: [a, b]\n' > "$work/e6/pnpm-workspace.yaml"; printf 'node_modules\ndist\n' > "$work/e6/.gitignore"
manifest @digitaplatform/e2e-a '{"files":["dist"],"dependencies":{"@digitaplatform/e2e-b":"workspace:*"},"scripts":{"build":"node build.js"}}' > "$work/e6/a/package.json"
printf '%s\n' "require('fs').mkdirSync('dist', {recursive: true}); require('fs').writeFileSync('dist/built.js', 'built');" > "$work/e6/a/build.js"
manifest @digitaplatform/e2e-b > "$work/e6/b/package.json"
(cd "$work/e6" && pnpm install --offline >/dev/null 2>&1) || fail 'the fixture source workspace could not be installed offline'
commit_tag "$work/e6" "0.3.001-stable-$STAMP"
pipeline_run "$work/e6" "0.3.001-stable-$STAMP" || fail "PLANTED INNOCENT: a source release on the default branch did not publish: $(cat "$work/run.out")"
[ "$(tasks_ran)" = "$ALL" ] || fail "the source run took another course: $(tasks_ran)"
hex="$(published @digitaplatform/e2e-a@0.3.1)" || fail "e2e-a was not published at the version of the tag, with its log line: $(cat "$work/run.out")"
published @digitaplatform/e2e-b@0.3.1 >/dev/null || fail "e2e-b was not published at the version of the tag, with its log line: $(cat "$work/run.out")"
blob e2e-a "$hex" > "$work/e2e-a.tgz"
[ "$(tar -xzOf "$work/e2e-a.tgz" package/dist/built.js 2>/dev/null)" = built ] || fail 'e2e-a was published without the dist/built.js its build writes'
[ "$(tar -xzOf "$work/e2e-a.tgz" package/package.json | jq -r '.dependencies["@digitaplatform/e2e-b"]')" = 0.3.1 ] || fail 'the workspace range of e2e-a was not published as the version of the tag'
[ "$(cat "$work/corepack.log")" = $'corepack enable\ncorepack prepare pnpm@11.7.0 --activate' ] || fail "the pack did not set up pnpm 11.7.0: $(cat "$work/corepack.log" 2>/dev/null)"
grep -qF 'pack: every tarball holds files under package/ only' "$work/run.out" && grep -q 'no leaks found' "$work/run.out" \
  || fail "the packed tarballs were not checked and scanned by gitleaks before the push: $(cat "$work/run.out")"
ok 'end to end: a source release builds, stamps the version of the tag over 0.0.1, packs, checks, scans and publishes every package'

# One package p in a workspace, with extra path=content pairs in its folder, installed and not yet committed.
one_package() { # $1 origin, $2 the package's name, then path=content pairs
  local dir="$1" name="$2" pair; shift 2
  origin "$dir"; mkdir -p "$dir/p"
  json '{"name":"root","private":true,"version":"0.0.1"}' > "$dir/package.json"
  printf 'packages: [p]\n' > "$dir/pnpm-workspace.yaml"; printf 'node_modules\n' > "$dir/.gitignore"
  manifest "$name" > "$dir/p/package.json"
  for pair in "$@"; do mkdir -p "$dir/p/$(dirname "${pair%%=*}")"; printf '%s\n' "${pair#*=}" > "$dir/p/${pair%%=*}"; done
  (cd "$dir" && pnpm install --offline >/dev/null 2>&1) || fail "the fixture package $name could not be installed offline"
}
one_package "$work/e2" @digitaplatform/e2e-env "index.js=export {};" "config/.env.local=A=1"; commit_tag "$work/e2" "0.1.000-stable-$STAMP"
pipeline_run "$work/e2" "0.1.000-stable-$STAMP" && fail 'PLANTED DEFECT: a packed tarball holding .env.local was published end to end'
grep -q 'holds package/config/.env.local' "$work/run.out" && grep -qx 'run: pack failed at prepare' "$work/run.out" && ! grep -q '^publish:' "$work/run.out" \
  || fail "a packed tarball holding .env.local was not refused at the pack before any push: $(cat "$work/run.out")"
one_package "$work/e3" @digitaplatform/e2e-leak "index.js=const token = \"ghp_$(head -c 400 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 36)\";"
commit_tag "$work/e3" "0.1.000-stable-$STAMP"
pipeline_run "$work/e3" "0.1.000-stable-$STAMP" && fail 'PLANTED DEFECT: a packed tarball holding a token was published end to end'
grep -qx 'run: pack failed at leaks' "$work/run.out" && ! grep -q '^publish:' "$work/run.out" \
  || fail "a token in a packed tarball did not fail the leaks step before any push: $(cat "$work/run.out")"
one_package "$work/e5" @digitaplatform/e2e-off "index.js=export {};"; git -C "$work/e5" checkout -q --detach
commit_tag "$work/e5" "0.1.000-stable-$STAMP"; git -C "$work/e5" checkout -q master
pipeline_run "$work/e5" "0.1.000-stable-$STAMP" && fail 'PLANTED DEFECT: a release commit off the default branch was published end to end'
grep -q 'is not on the default branch of origin' "$work/run.out" && grep -qx 'run: reviewed failed at decide' "$work/run.out" \
  || fail "a release commit off the default branch was not refused at reviewed: $(cat "$work/run.out")"
ok 'end to end: a packed tarball holding .env.local or a token, and a commit off the default branch, publish nothing'
# A source release hands pack the tools of its ci-tools.json: a version the table lacks ends pack
# before it builds anything.
one_package "$work/e10" @digitaplatform/e2e-tools "index.js=export {};"; printf '{"emcc": "0.0.1"}\n' > "$work/e10/ci-tools.json"
commit_tag "$work/e10" "0.1.000-stable-$STAMP"
pipeline_run "$work/e10" "0.1.000-stable-$STAMP" && fail 'PLANTED DEFECT: a source release whose ci-tools.json names a tool the table lacks was published end to end'
grep -qF 'check: ci-tools.json names emcc 0.0.1, which the tools table of this pipeline does not carry' "$work/run.out" && grep -qx 'run: pack failed at prepare' "$work/run.out" \
  && ! grep -q '^publish:' "$work/run.out" || fail "pack of a source release was not handed the tools of its ci-tools.json: $(cat "$work/run.out")"
ok 'end to end: pack of a source release installs the tools of its ci-tools.json first, and a version the table lacks publishes nothing'
origin "$work/e4"; mkdir -p "$work/e4/npm-seed"
tgz "$work/e4/npm-seed/digitaplatform-seed-a-1.0.0.tgz" "$(json '{"name":"@digitaplatform/seed-a","version":"1.0.0"}')" "dist/index.js=export {};"
printf '@digitaplatform/seed-a@1.0.0\tsha512-fixture\t%s\tdigita-platform:pnpm-lock.yaml@x\n' "$(sha256sum "$work/e4/npm-seed/digitaplatform-seed-a-1.0.0.tgz" | cut -d' ' -f1)" > "$work/e4/npm-seed/pins.tsv"
commit_tag "$work/e4" "0.1.000-stable-$STAMP"
pipeline_run "$work/e4" "0.1.000-stable-$STAMP" || fail "a tree holding only npm-seed/ failed: $(cat "$work/run.out")"
[ "$(tasks_ran)" = 'run: gate ran|run: clone ran|run: scan ran|run: reviewed skipped|run: pack skipped|run: build-binaries skipped|run: push skipped|run: SUCCEEDED|' ] \
  || fail "PLANTED DEFECT: a tree holding only npm-seed/ published its tarballs through the deleted seed path: $(tasks_ran)"
ok 'end to end: a tree holding only npm-seed/ publishes nothing'

origin "$work/e7"; mkdir -p "$work/e7/p"; manifest @digitaplatform/e2e-old '{"publishConfig":{"registry":"https://npm.pkg.github.com"}}' > "$work/e7/p/package.json"
commit_tag "$work/e7" "0.1.000-stable-$STAMP"
pipeline_run "$work/e7" "0.1.000-stable-$STAMP" && fail 'PLANTED DEFECT: a package that names npm.pkg.github.com passed the scan end to end'
[ "$(tasks_ran)" = 'run: gate ran|run: clone ran|run: scan failed at scan|' ] || fail "a package that names another registry did not stop the run at its scan: $(tasks_ran)"
origin "$work/e8"; printf 'x\n' > "$work/e8/main.go"; commit_tag "$work/e8" "0.1.000-stable-$STAMP"
pipeline_run "$work/e8" "0.1.000-stable-$STAMP" || fail "PLANTED INNOCENT: a repository with nothing to publish failed: $(cat "$work/run.out")"
[ "$(tasks_ran)" = 'run: gate ran|run: clone ran|run: scan ran|run: reviewed skipped|run: pack skipped|run: build-binaries skipped|run: push skipped|run: SUCCEEDED|' ] \
  || fail "a repository with nothing to publish took another course: $(tasks_ran)"
pipeline_run "$work/e8" "0.1.000-stable-$STAMP" https://github.com/digitaplatform/other.git && fail 'PLANTED DEFECT: a webhook that names another repository passed the gate'
[ "$(tasks_ran)" = 'run: gate failed at gate|' ] || fail "another repository was not stopped at the gate before the clone: $(tasks_ran)"
ok 'end to end: another registry stops the run at its scan, nothing to publish skips the rest, and another repository stops it at the gate'

# The build-binaries step and the list step of mirror read the owned yq and jq of files/ci-fixed-tools.sh from the
# mirror's address, which holds a sha256. So the mirror holds the two rows of clusters/platform/mirror-sources.table
# that file pins, copied by the mirror's own steps from upstream files: the bytes of this machine's yq and jq, which
# the sha256 of the row holds to the pinned release, as ci has installed it. The step reads what its address names.
fixed_tools="$root/clusters/inventories/consumer-build/files/ci-fixed-tools.sh"
: > "$work/fixed-tools.list"
for tool in yq jq; do
  pinned="$(sed -n "s/^${tool}_sha256=//p" "$fixed_tools")"
  row="$(grep -E "^tool [^ ]+ ${pinned:-no-pin}\$" "$root/clusters/platform/mirror-sources.table")" \
    || fail "$fixed_tools pins $tool by a sha256 that no row of the table holds"
  read -r _ url hex <<< "$row"
  mkdir -p "$work/upstream-files/$(dirname "${url#https://}")" && cp "$(command -v "$tool")" "$work/upstream-files/${url#https://}" \
    && source_line tool "$url" "$hex" >> "$work/fixed-tools.list" || fail "the row of $tool could not be made a line of the mirror"
done
sources "$work/fixed-tools.list" || fail "the owned yq and jq were not mirrored; this machine's must be the pinned release: $(cat "$work/sources.out")"

# A binaries release: release/build.sh writes two files named for the tag it is handed.
origin "$work/e9"; mkdir -p "$work/e9/release"
printf '%s\n' 'printf "%s" "a-$1" > "$2/tool-$1-linux-x64"' 'printf "%s" "b-$1" > "$2/tool-rest-$1-linux-x64"' > "$work/e9/release/build.sh"
commit_tag "$work/e9" "0.2.000-stable-$STAMP"
pipeline_run "$work/e9" "0.2.000-stable-$STAMP" || fail "PLANTED INNOCENT: a binaries release on the default branch did not publish: $(cat "$work/run.out")"
[ "$(tasks_ran)" = 'run: gate ran|run: clone ran|run: scan ran|run: reviewed ran|run: pack skipped|run: build-binaries ran|run: push ran|run: SUCCEEDED|' ] \
  || fail "the binaries run took another course: $(tasks_ran)"
[ "$(cat "$work/chown.log")" = "chown -R -h 10042 $work/run/workspace/repository $work/run/workspace/packed" ] \
  || fail "the clone and the output were not handed to the user of the build: $(cat "$work/chown.log" 2>/dev/null)"
for pair in tool=a tool-rest=b; do
  name="${pair%=*}"; hex="$(printf '%s' "${pair#*=}-0.2.000-stable-$STAMP" | sha256sum | cut -d' ' -f1)"
  grep -qxF "publish: $name-0.2.000-stable-$STAMP-linux-x64 https://${rendered_registry}/v2/digitaplatform/digita-deploy/blobs/sha256:${hex} sha256:${hex} published" "$work/run.out" \
    || fail "the binaries run did not publish $name under <owner>/<repository>:<tag> with its log line: $(cat "$work/run.out")"
done
ok 'end to end: a binaries release is gated, cloned, scanned, reviewed, built by release/build.sh and published as one manifest under <owner>/<repository>'

# The same release against a mirror that serves other bytes for the owned yq, then for the owned jq, builds nothing.
for tool in yq jq; do
  printf '/%s/' "$tool" > "$work/registry/corrupt"
  pipeline_run "$work/e9" "0.2.000-stable-$STAMP" && fail "PLANTED DEFECT: a binaries release whose owned $tool read with other bytes was published"
  rm "$work/registry/corrupt"
  [ "$(grep -c ': FAILED$' "$work/run.out")" = 1 ] && grep -qE "/ci-bin/$tool: FAILED\$" "$work/run.out" && grep -qx 'run: build-binaries failed at build' "$work/run.out" \
    && ! grep -q '^publish:' "$work/run.out" || fail "other bytes for the owned $tool did not fail the build at its sha256, alone: $(cat "$work/run.out")"
done
ok 'end to end: other bytes under the owned address of yq, or of jq, fail the build of a binaries release at their sha256 and publish nothing'

# The platform tree on the owner's master: its publish run copies the images its list names into the mirror,
# then the tools and charts its other list names, pushes no package, fails at the copy when an image is
# gone upstream, before any tool or chart is fetched, and at fetch when a tool is gone, with every image
# already read back. Nothing runs after the mirror.
helm template consumer-build "$root/clusters/inventories/consumer-build" --namespace argocd \
  -f "$root/clusters/platform/values-common.yaml" -f "$root/clusters/platform/values-prod.yaml" \
  -f "$root/clusters/inventories/consumer-build/values-common.yaml" \
  -f "$root/scripts/standin/cluster-map.yaml" -f "$root/scripts/standin/registration.yaml" \
  --set "global.buildRegistry=${rendered_registry}/simetrixch" \
  --set-json 'unit={"name":"hostyour-cloud","repoURL":"https://github.com/simetrixch/hostyour-cloud.git","buildsJson":"[]"}' \
  | yq -o=json 'select(.kind == "Pipeline" and .metadata.name == "hostyour-cloud-publish")' > "$work/platform-pipeline.json" \
  && [ -s "$work/platform-pipeline.json" ] || fail 'the chart renders no hostyour-cloud-publish Pipeline for the platform tree'
platform_run() { # $1 the fixture origin, $2 the release tag, [$3 the Pipeline file] -> the run's status, its log in $work/run.out
  rm -rf "${work:?}/run"; mkdir -p "$work/run"
  node "$work/run-pipeline.mjs" "${3:-$work/platform-pipeline.json}" "$work/run" "$1" https://github.com/simetrixch/hostyour-cloud.git \
    "$(jq -nc --arg tag "$2" '{"release-tag": $tag, "git-url": "https://github.com/simetrixch/hostyour-cloud.git"}')" "$secrets" > "$work/run.out" 2>&1
}
platform_tree() { # $1 folder, $2 the lines its list of tools and charts prints, then the entries its list of images prints -> a fixture platform tree whose two list scripts print them
  local dir="$1" lines="$2"; shift 2
  origin "$dir"; mkdir -p "$dir/scripts"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n"%s\n' "$(printf " '%s'" "$@")" > "$dir/scripts/list-mirror-images.sh"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" %s\n' "'$lines'" > "$dir/scripts/list-mirror-sources.sh"
  manifest @digitaplatform/e2e-platform > "$dir/package.json"
}
# The fixture registry keeps a repository by its path whatever host names it, so the run mirrors a tool and a
# chart of its own, which the cases above never pushed.
platform_tool_url=https://github.com/fixture/platform-tool/releases/download/v1.0.0/platform-tool-linux-amd64
platform_tool_hex="$(upstream_file github.com/fixture/platform-tool/releases/download/v1.0.0/platform-tool-linux-amd64 'the platform tool 1.0.0')"
platform_chart_hex="$(upstream_chart charts.example.invalid platform-chart 1.0.0)"
platform_sources="$(REGISTRY="$rendered_registry" source_line tool "$platform_tool_url" "$platform_tool_hex")
$(REGISTRY="$rendered_registry" source_line chart https://charts.example.invalid platform-chart 1.0.0 "$platform_chart_hex")"
platform_tree "$work/e11" "$platform_sources" "$(entry "fixture/multi:2.0@$v2s2_list" "$rendered_registry")" "$(entry "fixture/one:1.0.0@$oci_image" "$rendered_registry")" \
  "$(entry "fixture/index:3.0@$oci_index" "$rendered_registry")"
commit_tag "$work/e11" "0.5.000-stable-$STAMP"
platform_course='run: gate ran|run: clone ran|run: scan ran|run: reviewed ran|run: pack skipped|run: build-binaries skipped|run: push skipped|run: mirror ran|run: SUCCEEDED|'
platform_run "$work/e11" "0.5.000-stable-$STAMP" || fail "PLANTED INNOCENT: the platform tree did not mirror its images: $(cat "$work/run.out")"
[ "$(tasks_ran)" = "$platform_course" ] || fail "PLANTED INNOCENT: the platform run took another course: $(tasks_ran)"
grep -qxF "mirror: ${rendered_registry}/simetrixch/ghcr.io/fixture/multi:2.0@$v2s2_list application/vnd.docker.distribution.manifest.list.v2+json read back" "$work/run.out" \
  && grep -qxF "mirror: ${rendered_registry}/simetrixch/ghcr.io/fixture/one:1.0.0@$oci_image application/vnd.oci.image.manifest.v1+json read back" "$work/run.out" \
  && grep -qxF "mirror: ${rendered_registry}/simetrixch/ghcr.io/fixture/index:3.0@$oci_index application/vnd.oci.image.index.v1+json read back" "$work/run.out" \
  && ! grep -q '^publish:' "$work/run.out" || fail "the platform run did not read every image back, or published a package: $(cat "$work/run.out")"
grep -qxF 'mirror: the tree at this tag names 2 tools and charts for the mirror: 2 fetched and held to their sha256, 0 already served' "$work/run.out" \
  && grep -qxF 'mirror: 2 tools and charts: 2 pushed, 0 kept' "$work/run.out" && grep -qxF 'mirror: 2 of 2 tools and charts served' "$work/run.out" \
  && [ "$(grep -n ' read back$' "$work/run.out" | tail -n 1 | cut -d: -f1)" -lt "$(grep -n ' fetched from ' "$work/run.out" | head -n 1 | cut -d: -f1)" ] \
  || fail "the platform run did not mirror its tools and charts after its images were read back: $(cat "$work/run.out")"
# One more task after the mirror runs, and the course of the run is no longer the platform's.
jq '.spec.tasks += [.spec.tasks[] | select(.name == "mirror") | .name = "after-mirror" | .runAfter = ["mirror"]]' "$work/platform-pipeline.json" > "$work/platform-after-mirror.json" \
  && [ "$(jq -r '[.spec.tasks[].name] | join(" ")' "$work/platform-after-mirror.json")" = 'gate clone scan reviewed pack build-binaries push mirror after-mirror' ] \
  || fail 'the planted Pipeline with a task after the mirror was not made'
platform_run "$work/e11" "0.5.000-stable-$STAMP" "$work/platform-after-mirror.json" || fail "the planted Pipeline with a task after the mirror did not run: $(cat "$work/run.out")"
[ "$(tasks_ran)" != "$platform_course" ] || fail 'PLANTED DEFECT: a task ran after the mirror, and the course of the platform run stayed green'
echo "pipeline-publish.test: PLANTED DEFECT, red as it must be: the course $(tasks_ran)"
platform_tree "$work/e12" "$platform_sources" "$(entry "fixture/gone:1.0.0@$oci_image" "$rendered_registry")"
commit_tag "$work/e12" "0.5.000-stable-$STAMP"
platform_run "$work/e12" "0.5.000-stable-$STAMP" && fail 'PLANTED DEFECT: the platform tree passed with an image ghcr.io does not hold'
grep -qxF 'run: mirror failed at copy' "$work/run.out" && grep -qF 'mirror: FAIL — ghcr.io/fixture/gone:1.0.0 cannot be read upstream' "$work/run.out" \
  || fail "an image ghcr.io does not hold did not fail the run at the copy by name: $(cat "$work/run.out")"
! grep -q 'tools and charts' "$work/run.out" || fail "a tool or chart was fetched though an image was not copied: $(cat "$work/run.out")"
gone_line="$(REGISTRY="$rendered_registry" source_line tool "$gone_url" "$tool_hex")"
platform_tree "$work/e13" "$gone_line" "$(entry "fixture/one:1.0.0@$oci_image" "$rendered_registry")"
commit_tag "$work/e13" "0.5.000-stable-$STAMP"
platform_run "$work/e13" "0.5.000-stable-$STAMP" && fail 'PLANTED DEFECT: the platform tree passed with a tool its upstream does not hold'
grep -qxF 'run: mirror failed at fetch' "$work/run.out" \
  && grep -qxF "mirror: ${rendered_registry}/simetrixch/ghcr.io/fixture/one:1.0.0@$oci_image application/vnd.oci.image.manifest.v1+json read back" "$work/run.out" \
  && grep -qF "mirror: FAIL — row $(owned_reference "$gone_line"): $gone_url could not be fetched" "$work/run.out" \
  || fail "a tool its upstream does not hold did not fail the run at fetch by its row, after the images were read back: $(cat "$work/run.out")"
ok 'end to end: the platform tree mirrors every image its list names and reads it back, then every tool and chart, publishes no package and runs nothing after the mirror; an image gone upstream fails the run before a tool or chart is fetched, and a tool gone upstream fails it at fetch with the images read back'
# The engine on the owner's master: its publish run puts the release's manifest under its digest, and tag then
# puts it under the tag that release/release.sh of ansiwise-cli waits for before it pins the engine. The push
# login stands in the step of push and in the step of tag, and in no other.
helm template consumer-build "$root/clusters/inventories/consumer-build" --namespace argocd \
  -f "$root/clusters/platform/values-common.yaml" -f "$root/clusters/platform/values-prod.yaml" \
  -f "$root/clusters/inventories/consumer-build/values-common.yaml" \
  -f "$root/scripts/standin/cluster-map.yaml" -f "$root/scripts/standin/registration.yaml" \
  --set "global.buildRegistry=${rendered_registry}/simetrixch" \
  --set-json 'unit={"name":"ansiwise-cli","repoURL":"https://github.com/simetrixch/ansiwise-cli.git","buildsJson":"[]"}' \
  | yq -o=json 'select(.kind == "Pipeline" and .metadata.name == "ansiwise-cli-publish")' > "$work/engine-pipeline.json" \
  && [ -s "$work/engine-pipeline.json" ] || fail 'the chart renders no ansiwise-cli-publish Pipeline for the engine'
engine_run() { # $1 the fixture origin, $2 the release tag, [$3 the Pipeline file] -> the run's status, its log in $work/run.out
  rm -rf "${work:?}/run"; mkdir -p "$work/run"
  node "$work/run-pipeline.mjs" "${3:-$work/engine-pipeline.json}" "$work/run" "$1" https://github.com/simetrixch/ansiwise-cli.git \
    "$(jq -nc --arg tag "$2" '{"release-tag": $tag, "git-url": "https://github.com/simetrixch/ansiwise-cli.git"}')" "$secrets" > "$work/run.out" 2>&1
}
engine_manifest() { # $1 a tag or a digest -> the status the registry answers for the engine's manifest under it, its bytes in $work/engine-manifest.json
  command curl -sS -o "$work/engine-manifest.json" -w '%{http_code}' "http://127.0.0.1:$PORT/v2/simetrixch/ansiwise-cli/manifests/$1"
}
login_steps() { # $1 a Pipeline file -> every <task>/<step> whose pod holds the push login, and every <task>/volumes that mount it
  jq -r '[.spec.tasks[] | .name as $task | ((.taskSpec.steps // [])[] | select(tostring | contains("\"image-builder-registry-push\"")) | "\($task)/\(.name)"),
    ((.taskSpec.volumes // []) | select(tostring | contains("\"image-builder-registry-push\"")) | "\($task)/volumes")] | join(" ")' "$1"
}
engine_course='run: gate ran|run: clone ran|run: scan ran|run: reviewed ran|run: pack skipped|run: build-binaries ran|run: push ran|run: tag ran|run: SUCCEEDED|'
engine_tag="1.0.010-stable-$STAMP"
origin "$work/e15"; mkdir -p "$work/e15/release"
printf '%s\n' 'printf "%s" "a-$1" > "$2/ansiwise-$1-linux-x64"' 'printf "%s" "b-$1" > "$2/ansiwise-rest-$1-linux-x64"' > "$work/e15/release/build.sh"
commit_tag "$work/e15" "$engine_tag"
[ "$(engine_manifest "$engine_tag")" = 404 ] || fail 'the engine release was under its tag before its run'
engine_run "$work/e15" "$engine_tag" || fail "PLANTED INNOCENT: the engine release was not published: $(cat "$work/run.out")"
[ "$(tasks_ran)" = "$engine_course" ] || fail "PLANTED INNOCENT: the engine's run took another course: $(tasks_ran)"
pushed="$(cat "$work/run/push/results/digest" 2>/dev/null)"
[[ "$pushed" =~ ^sha256:[0-9a-f]{64}$ ]] && [ "$(engine_manifest "$pushed")" = 200 ] \
  && grep -qxF "publish: simetrixch/ansiwise-cli:$engine_tag tagged at $pushed" "$work/run.out" \
  && [ "$(engine_manifest "$engine_tag")" = 200 ] && [ "sha256:$(sha256sum < "$work/engine-manifest.json" | cut -d' ' -f1)" = "$pushed" ] \
  || fail "the engine was not tagged at the digest push put it under: $(cat "$work/run.out")"
# One more task between push and tag runs, and the course of the run is no longer the engine's.
jq '.spec.tasks |= map(if .name == "tag" then .runAfter = ["between"] else . end) + [.[] | select(.name == "push") | .name = "between" | .runAfter = ["push"]]' \
  "$work/engine-pipeline.json" > "$work/engine-between.json" \
  && [ "$(jq -c '[.spec.tasks[] | select(.name == "tag" or .name == "between") | {(.name): .runAfter}] | add' "$work/engine-between.json")" = '{"tag":["between"],"between":["push"]}' ] \
  || fail 'the planted Pipeline with a task between push and tag was not made'
engine_run "$work/e15" "$engine_tag" "$work/engine-between.json" || fail "the planted Pipeline with a task between push and tag did not run: $(cat "$work/run.out")"
[ "$(tasks_ran)" != "$engine_course" ] || fail 'PLANTED DEFECT: a task ran between push and tag, and the course of the engine run stayed green'
echo "pipeline-publish.test: PLANTED DEFECT, red as it must be: the course $(tasks_ran)"
# The push login beside the build of the binaries, which runs the repository's release/build.sh.
engine_login='push/push tag/tag'
[ "$(login_steps "$work/engine-pipeline.json")" = "$engine_login" ] || fail "PLANTED INNOCENT: the push login stands in $(login_steps "$work/engine-pipeline.json"), not in the steps of push and tag alone"
jq '(.spec.tasks[] | select(.name == "build-binaries") | .taskSpec.steps[] | select(.name == "build") | .envFrom) += [{secretRef: {name: "image-builder-registry-push"}}]' \
  "$work/engine-pipeline.json" > "$work/engine-login-in-build.json" || fail 'the planted Pipeline with the push login in build-binaries was not made'
[ "$(login_steps "$work/engine-login-in-build.json")" != "$engine_login" ] || fail 'PLANTED DEFECT: the push login stood beside the build of the binaries, and the check stayed green'
echo "pipeline-publish.test: PLANTED DEFECT, red as it must be: the push login in $(login_steps "$work/engine-login-in-build.json")"
ok 'end to end: the engine is pushed under its digest and tag then puts that digest under the release tag, with nothing between them and the push login in their two steps alone'
echo "pipeline-publish.test: OK"
