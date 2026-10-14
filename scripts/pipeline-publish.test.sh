#!/usr/bin/env bash
# The publish pipeline's own shell, where it decides something a fixture can hold it to: which
# package.json a release tag publishes and which registry it may name; that the release commit is on
# the default branch, or differs from it in stamped versions only; that every package declares the
# version of the tag before it is packed, workspace ranges included; that the one-time seed publishes
# only tarballs whose sha256 its npm-seed/pins.tsv line names and that hold no .npmrc, .env* or
# gitleaks finding; and that the push refuses another scope and another content under a published
# version, pushes nothing once one tarball is refused, reads every tarball back, and logs one line per
# tarball. The functions are read out of the template
# (clusters/inventories/consumer-build/templates/pipeline-publish.yaml), as the Pipeline carries
# them, and run against fixture repositories, tarballs and a registry served on 127.0.0.1. Then the
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
# Stand-ins for what the cluster has and this machine must not change: curl that reaches the fixture
# registry, and corepack, whose enable would write into this machine's Node.
mkdir -p "$work/standin-bin"
real_curl="$(command -v curl)"
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
for fn in scan_packages stamp_only reviewed_commit release_version stamp_versions build_packages pack_packages \
  seed_check seed_leaks registry_call push_blob npm_push; do
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
repo "$work/seeded" "npm-seed/pins.tsv=x" \
  "packages/a/package.json=$(json '{"name":"@digitaplatform/a","version":"1.0.0","publishConfig":{"registry":"https://registry.test/v2/npm/"}}')"
(cd "$work/seeded" && MODE='' && scan_packages "$work/list" >/dev/null && echo "$MODE") > "$work/mode" || fail 'a seed was refused at its scan'
[ "$(cat "$work/mode")" = seed ] && [ ! -s "$work/list" ] || fail 'a tag that holds npm-seed/ also listed its source packages'
ok 'a tag that holds npm-seed/ is the seed and lists nothing else'

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

# ── seed_check and seed_leaks: the one-time seed ───────────────────────────────────────────
tgz() { # $1 the tarball, $2 the package.json, then extra path=content pairs inside package/
  local into pair out="$1" manifest="$2"
  into="$work/tgz-src/$(basename "$1")"; shift 2
  rm -rf "$into"; mkdir -p "$into/package"
  printf '%s\n' "$manifest" > "$into/package/package.json"
  for pair in "$@"; do mkdir -p "$into/package/$(dirname "${pair%%=*}")"; printf '%s\n' "${pair#*=}" > "$into/package/${pair%%=*}"; done
  tar -czf "$out" -C "$into" package
}
seed() { # $1 folder: a seed repository with minimal and theme, and pins.tsv naming both
  rm -rf "$1"; mkdir -p "$1/npm-seed"
  tgz "$1/npm-seed/digitaplatform-minimal-0.4.13.tgz" "$(json '{"name":"@digitaplatform/minimal","version":"0.4.13"}')" "dist/index.js=export const x = 1;"
  tgz "$1/npm-seed/digitaplatform-theme-0.3.13.tgz" "$(json '{"name":"@digitaplatform/theme","version":"0.3.13"}')" "dist/index.css=a{}"
  pins "$1"
}
pins() { # $1 seed folder: npm-seed/pins.tsv names every .tgz in it with its sha256
  local f name
  for f in "$1"/npm-seed/*.tgz; do
    name="$(tar -xzOf "$f" package/package.json | jq -r '.name + "@" + .version')"
    printf '%s\tsha512-fixture\t%s\tdigita-platform:pnpm-lock.yaml@%s\n' "$name" "$(sha256sum "$f" | cut -d' ' -f1)" "$(printf 'a%.0s' {1..40})"
  done > "$1/npm-seed/pins.tsv"
}
seed_run() { # $1 the seed folder -> the exit status of seed_check, its output in $work/seed.out
  rm -rf "$work/seed-dest" "$work/seed-unpacked"; mkdir -p "$work/seed-dest" "$work/seed-unpacked"
  (cd "$1" && seed_check "$work/seed-dest" "$work/seed-unpacked") > "$work/seed.out" 2>&1
}
seed "$work/s"
seed_run "$work/s" || fail "PLANTED INNOCENT: a seed whose tarballs match their lines was refused: $(cat "$work/seed.out")"
[ "$(ls "$work/seed-dest" | tr '\n' ' ')" = 'digitaplatform-minimal-0.4.13.tgz digitaplatform-theme-0.3.13.tgz ' ] || fail 'the checked seed tarballs did not reach the push'
cmp -s "$work/s/npm-seed/digitaplatform-minimal-0.4.13.tgz" "$work/seed-dest/digitaplatform-minimal-0.4.13.tgz" || fail 'a seed tarball was not pushed as it is'
seed_leaks "$work/seed-unpacked" >/dev/null 2>&1 || fail 'PLANTED INNOCENT: the clean seed tree has a gitleaks finding'
ok 'a seed whose tarballs match their pins.tsv lines passes as it is, and its unpacked tree has no gitleaks finding'
refused() { # $1 what the case plants, $2 the words the refusal must carry
  seed_run "$work/s" && fail "PLANTED DEFECT: $1 was not refused"
  grep -qF -- "$2" "$work/seed.out" || fail "$1 was refused without saying '$2': $(cat "$work/seed.out")"
}
repin() { # $1 seed folder, $2 its tarball, $3 its line when the tarball names another: that line names the sha256 it has now
  awk -F'\t' -v OFS='\t' -v n="${3:-$(tar -xzOf "$1/npm-seed/$2" package/package.json | jq -r '.name + "@" + .version')}" \
    -v h="$(sha256sum "$1/npm-seed/$2" | cut -d' ' -f1)" '$1 == n { $3 = h } { print }' \
    "$1/npm-seed/pins.tsv" > "$work/pins" && mv "$work/pins" "$1/npm-seed/pins.tsv"
}
seed "$work/s"; tgz "$work/s/npm-seed/digitaplatform-extra-1.0.0.tgz" "$(json '{"name":"@digitaplatform/extra","version":"1.0.0"}')"
refused 'a .tgz that pins.tsv does not list' 'npm-seed/digitaplatform-extra-1.0.0.tgz has no line in npm-seed/pins.tsv'
seed "$work/s"; rm "$work/s/npm-seed/digitaplatform-theme-0.3.13.tgz"
refused 'a line that has no .tgz' 'pins.tsv lists @digitaplatform/theme@0.3.13, and npm-seed/ holds no digitaplatform-theme-0.3.13.tgz'
seed "$work/s"; tgz "$work/s/npm-seed/digitaplatform-theme-0.3.13.tgz" "$(json '{"name":"@digitaplatform/theme","version":"0.3.13"}')" "dist/index.css=b{}"
refused 'a .tgz whose sha256 differs from its line' 'digitaplatform-theme-0.3.13.tgz has the sha256'
seed "$work/s"; tgz "$work/s/npm-seed/digitaplatform-theme-0.3.13.tgz" "$(json '{"name":"@digitaplatform/theme","version":"0.3.13"}')" ".npmrc=//registry.example/:_authToken=x"
repin "$work/s" digitaplatform-theme-0.3.13.tgz
refused 'a .tgz holding .npmrc' 'digitaplatform-theme-0.3.13.tgz holds package/.npmrc'
seed "$work/s"; tgz "$work/s/npm-seed/digitaplatform-theme-0.3.13.tgz" "$(json '{"name":"@digitaplatform/theme","version":"0.3.13"}')" "config/.env.local=A=1"
repin "$work/s" digitaplatform-theme-0.3.13.tgz
refused 'a .tgz holding .env.local' 'digitaplatform-theme-0.3.13.tgz holds package/config/.env.local'
seed "$work/s"; tgz "$work/s/npm-seed/digitaplatform-theme-0.3.13.tgz" "$(json '{"name":"@digitaplatform/theme","version":"0.3.14"}')"
repin "$work/s" digitaplatform-theme-0.3.13.tgz @digitaplatform/theme@0.3.13
refused 'a .tgz whose package.json names another version than its line' 'digitaplatform-theme-0.3.13.tgz is @digitaplatform/theme@0.3.14'
seed "$work/s"; mkdir -p "$work/tgz-src/link/package"; json '{"name":"@digitaplatform/theme","version":"0.3.13"}' > "$work/tgz-src/link/package/package.json"
ln -s /etc/passwd "$work/tgz-src/link/package/passwd"; tar -czf "$work/s/npm-seed/digitaplatform-theme-0.3.13.tgz" -C "$work/tgz-src/link" package
repin "$work/s" digitaplatform-theme-0.3.13.tgz
refused 'a .tgz holding a symbolic link' 'digitaplatform-theme-0.3.13.tgz holds an entry that is neither a file nor a folder'
seed "$work/s"; rm "$work/s/npm-seed/pins.tsv"
refused 'an npm-seed/ without pins.tsv' 'npm-seed/ holds no pins.tsv'
seed "$work/s"; printf '@digitaplatform/theme@0.3.13\tsha512-fixture\tnot-a-digest\tdigita-platform:pnpm-lock.yaml@x\n' > "$work/s/npm-seed/pins.tsv"
refused 'a pins.tsv line without a sha256' 'is no line of pins.tsv'
ok 'the seed refuses a .tgz without a line, a line without a .tgz, another sha256, .npmrc, .env*, another name@version, a link and a broken pins.tsv'
seed "$work/s"
seed_run "$work/s" || fail 'the clean seed was refused'
printf 'const token = "ghp_%s";\n' "$(head -c 400 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 36)" > "$work/seed-unpacked/digitaplatform-theme-0.3.13.tgz/package/dist/leak.js"
seed_leaks "$work/seed-unpacked" >/dev/null 2>&1 && fail 'PLANTED DEFECT: a token in a seed tarball was not found by gitleaks'
ok 'a gitleaks finding in the unpacked seed fails its scan'

# ── npm_push: the registry, served on 127.0.0.1 ────────────────────────────────────────────
# A registry of the OCI distribution API, as much of it as the push uses, behind one basic login. It
# keeps blobs and manifests per repository, refuses a manifest that names a blob the repository lacks
# and a blob whose bytes are not its digest, logs every request, and answers a blob read with a
# changed byte while the file `corrupt` stands beside it.
mkdir -p "$work/registry"
cat > "$work/registry.mjs" <<'EOF'
import {createServer} from 'node:http';
import {createHash, randomUUID} from 'node:crypto';
import {appendFileSync, existsSync, writeFileSync} from 'node:fs';
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
    if (req.headers.authorization !== login) { res.writeHead(401); return res.end(); }
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
      if (existsSync(`${dir}/corrupt`)) sent[0] ^= 1;
      res.writeHead(200, {'Content-Length': sent.length});
      return res.end(req.method === 'HEAD' ? undefined : sent);
    }
    if ((m = url.pathname.match(/^\/v2\/(.+)\/manifests\/([^/]+)$/))) {
      const key = `${m[1]}:${m[2]}`;
      if (req.method === 'PUT') {
        const manifest = JSON.parse(body);
        if (![manifest.config, ...manifest.layers].every((d) => blobs.has(`${m[1]}@${d.digest}`))) { res.writeHead(400); return res.end('MANIFEST_BLOB_UNKNOWN'); }
        manifests.set(key, body); res.writeHead(201); return res.end();
      }
      const manifest = manifests.get(key);
      if (!manifest) { res.writeHead(404); return res.end(); }
      res.writeHead(200, {'Content-Type': 'application/vnd.oci.image.manifest.v1+json'});
      return res.end(req.method === 'HEAD' ? undefined : manifest);
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
# The pipeline names https://<REGISTRY>/v2/; the fixture serves plain http on its own port.
cat > "$work/standin-bin/curl" <<EOF
#!/usr/bin/env bash
args=()
for a in "\$@"; do
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
mkdir -p "$work/p1"; cp "$work/seed-dest/"*.tgz "$work/p1/"
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
# own shebang with its env and envFrom, and the run failed at the first step that fails. A path the pod
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
const mount = (text, mounts) => Object.keys(mounts).sort((a, b) => b.length - a.length).reduce((t, path) =>
  t.replace(new RegExp(`(^|[\\s"'=:(])${escape(path)}(?=/|$|[\\s"';)])`, 'gm'), (_, before) => before + mounts[path]), text);
const git = (...args) => spawnSync('git', args, {encoding: 'utf8'});
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
      ...Object.fromEntries((step.env ?? []).map((e) => [e.name, mount(fill(e.value, values), mounts)]))};
    const script = join(home, 'script');
    writeFileSync(script, mount(fill(step.script, values), mounts));
    chmodSync(script, 0o755);
    const ran = spawnSync(script, [], {cwd: step.workingDir ? mount(step.workingDir, mounts) : home, env, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024});
    process.stdout.write(ran.stdout + ran.stderr);
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
secrets="$(jq -nc --arg user "$REGISTRY_USERNAME" --arg password "$REGISTRY_PASSWORD" '{"build-git-https": {GITCREDENTIALS: "https://github.invalid"},
  "image-builder-registry-push": {REGISTRY_USERNAME: $user, REGISTRY_PASSWORD: $password}}')"
pipeline_run() { # $1 the fixture origin, $2 the release tag, [$3 the webhook's git-url] -> the run's status, its log in $work/run.out
  rm -rf "${work:?}/run" "${work:?}/corepack.log"; mkdir -p "$work/run"
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
ALL='run: gate ran|run: clone ran|run: scan ran|run: reviewed ran|run: pack ran|run: push ran|run: SUCCEEDED|'
STAMP=20261014000000
origin() { repo "$1" "README.md=fixture"; } # $1 folder -> a fixture origin whose default branch master holds one commit
commit_tag() { git -C "$1" add -A && git -C "$1" commit -q -m "$2" && git -C "$1" tag "$2"; } # $1 origin, $2 the tag
e2e_seed() { # $1 origin, then name@version[=path=content] per tarball: npm-seed/ holding them, pinned
  local dir="$1" spec name version file manifest; shift
  mkdir -p "$dir/npm-seed"
  for spec in "$@"; do
    name="${spec%%=*}"; version="${name##*@}"; name="${name%@*}"
    file="$dir/npm-seed/digitaplatform-${name#@digitaplatform/}-${version}.tgz"
    manifest="$(json "{\"name\":\"${name}\",\"version\":\"${version}\"}")"
    if [ "$spec" = "${spec#*=}" ]; then
      tgz "$file" "$manifest" "dist/index.js=export {};"
    else
      tgz "$file" "$manifest" "dist/index.js=export {};" "${spec#*=}"
    fi
  done
  pins "$dir"
}

origin "$work/e1"; e2e_seed "$work/e1" @digitaplatform/seed-a@1.0.0 @digitaplatform/seed-b@2.0.0; commit_tag "$work/e1" "0.1.000-stable-$STAMP"
pipeline_run "$work/e1" "0.1.000-stable-$STAMP" || fail "PLANTED INNOCENT: a clean seed on the default branch did not publish: $(cat "$work/run.out")"
[ "$(tasks_ran)" = "$ALL" ] || fail "the seed run took another course: $(tasks_ran)"
for name in @digitaplatform/seed-a@1.0.0 @digitaplatform/seed-b@2.0.0; do
  file="digitaplatform-$(tr '@/' '--' <<<"${name#@digitaplatform/}").tgz"
  [ "$(published "$name")" = "$(sha256sum "$work/e1/npm-seed/$file" | cut -d' ' -f1)" ] || fail "the seed did not publish ${name} as it is, with its log line: $(cat "$work/run.out")"
done
grep -q 'no leaks found' "$work/run.out" || fail "gitleaks did not scan the unpacked seed: $(cat "$work/run.out")"
[ ! -e "$work/corepack.log" ] || fail 'a seed run set up pnpm, which only a source run builds with'
ok 'end to end: a clean seed on the default branch is gated, cloned, scanned, reviewed, checked, scanned by gitleaks, and published as it is'

origin "$work/e2"; e2e_seed "$work/e2" @digitaplatform/seed-c@1.0.0 "@digitaplatform/seed-d@1.0.0=.npmrc=//registry.example/:_authToken=x"; commit_tag "$work/e2" "0.1.000-stable-$STAMP"
pipeline_run "$work/e2" "0.1.000-stable-$STAMP" && fail 'PLANTED DEFECT: a seed tarball holding .npmrc was published end to end'
grep -q 'holds package/.npmrc' "$work/run.out" && grep -qx 'run: pack failed at prepare' "$work/run.out" && ! grep -q '^publish:' "$work/run.out" \
  || fail "a seed tarball holding .npmrc was not refused at the pack before any push: $(cat "$work/run.out")"
origin "$work/e3"; e2e_seed "$work/e3" "@digitaplatform/seed-e@1.0.0=dist/leak.js=const token = \"ghp_$(head -c 400 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 36)\";"
commit_tag "$work/e3" "0.1.000-stable-$STAMP"
pipeline_run "$work/e3" "0.1.000-stable-$STAMP" && fail 'PLANTED DEFECT: a seed tarball holding a token was published end to end'
grep -qx 'run: pack failed at leaks' "$work/run.out" && ! grep -q '^publish:' "$work/run.out" \
  || fail "a token in a seed tarball did not fail the leaks step before any push: $(cat "$work/run.out")"
origin "$work/e4"; e2e_seed "$work/e4" @digitaplatform/seed-f@1.0.0
tgz "$work/e4/npm-seed/digitaplatform-seed-f-1.0.0.tgz" "$(json '{"name":"@digitaplatform/seed-f","version":"1.0.0"}')" "dist/index.js=export const changed = 1;"
commit_tag "$work/e4" "0.1.000-stable-$STAMP"
pipeline_run "$work/e4" "0.1.000-stable-$STAMP" && fail 'PLANTED DEFECT: a seed tarball whose sha256 its line does not name was published end to end'
grep -q 'digitaplatform-seed-f-1.0.0.tgz has the sha256' "$work/run.out" && grep -qx 'run: pack failed at prepare' "$work/run.out" \
  || fail "a seed tarball with another sha256 was not refused at the pack: $(cat "$work/run.out")"
origin "$work/e5"; git -C "$work/e5" checkout -q --detach
e2e_seed "$work/e5" @digitaplatform/seed-g@1.0.0; commit_tag "$work/e5" "0.1.000-stable-$STAMP"; git -C "$work/e5" checkout -q master
pipeline_run "$work/e5" "0.1.000-stable-$STAMP" && fail 'PLANTED DEFECT: a seed commit off the default branch was published end to end'
grep -q 'is not on the default branch of origin' "$work/run.out" && grep -qx 'run: reviewed failed at decide' "$work/run.out" \
  || fail "a seed commit off the default branch was not refused at reviewed: $(cat "$work/run.out")"
ok 'end to end: a seed tarball holding .npmrc, a token or another sha256, and a seed off the default branch, publish nothing'

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
ok 'end to end: a source release builds, stamps the version of the tag over 0.0.1, packs and publishes every package'

origin "$work/e7"; mkdir -p "$work/e7/p"; manifest @digitaplatform/e2e-old '{"publishConfig":{"registry":"https://npm.pkg.github.com"}}' > "$work/e7/p/package.json"
commit_tag "$work/e7" "0.1.000-stable-$STAMP"
pipeline_run "$work/e7" "0.1.000-stable-$STAMP" && fail 'PLANTED DEFECT: a package that names npm.pkg.github.com passed the scan end to end'
[ "$(tasks_ran)" = 'run: gate ran|run: clone ran|run: scan failed at scan|' ] || fail "a package that names another registry did not stop the run at its scan: $(tasks_ran)"
origin "$work/e8"; printf 'x\n' > "$work/e8/main.go"; commit_tag "$work/e8" "0.1.000-stable-$STAMP"
pipeline_run "$work/e8" "0.1.000-stable-$STAMP" || fail "PLANTED INNOCENT: a repository with nothing to publish failed: $(cat "$work/run.out")"
[ "$(tasks_ran)" = 'run: gate ran|run: clone ran|run: scan ran|run: reviewed skipped|run: pack skipped|run: push skipped|run: SUCCEEDED|' ] \
  || fail "a repository with nothing to publish took another course: $(tasks_ran)"
pipeline_run "$work/e8" "0.1.000-stable-$STAMP" https://github.com/digitaplatform/other.git && fail 'PLANTED DEFECT: a webhook that names another repository passed the gate'
[ "$(tasks_ran)" = 'run: gate failed at gate|' ] || fail "another repository was not stopped at the gate before the clone: $(tasks_ran)"
ok 'end to end: another registry stops the run at its scan, nothing to publish skips the rest, and another repository stops it at the gate'
echo "pipeline-publish.test: OK"
