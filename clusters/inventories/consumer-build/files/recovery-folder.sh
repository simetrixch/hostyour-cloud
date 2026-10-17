# shellcheck shell=bash
# =============================================================================
# recovery-folder.sh — what the recovery folder of the owner's master holds, and the test each archive
# of it passes. SOURCED, NEVER RUN. Three runs on the owner's master write the folder, each before the pin
# its archives serve can be read: the release run of the platform's own builds before its bump pins them
# (pipeline-release.yaml), the publish run of the engine before it tags the release that
# release/release.sh of ansiwise-cli waits for, and the publish run of every platform tag for the whole
# tree (both pipeline-publish.yaml). The two release runs include this file as the chart renders it; the
# platform's publish run sources it from the tree at its tag. lifecycle/driver.sh sources it from the
# installation's checkout and fetches the folder into a cold node. All of them name every archive the
# same way because all of them run these lines, and all refuse an archive for the same reasons.
#
#   recovery_archives <tree> <stage>
#       one line per archive the tree names: <path in the folder> <name:tag> <manifest digest, or ->
#   recovery_build_archive <registry>/<owner> <image> <tag>
#       the line of one build of the platform's own images
#   recovery_engine_archive <registry>/<owner> <release> [<manifest digest>]
#       the line of one release of the engine
#   recovery_archive_digest <folder> <path in it> <name:tag> <manifest digest, or -> <ansiwise.sha256, or -> <a folder of its own>
#       the digest of the one manifest the archive holds, or on standard error what is wrong with it
#
# THE DIGESTS ARE THE TREE'S, never the folder's. A pinned image is held to the digest the tree names for
# it in clusters/platform/recovery-images.list, which scripts/check.sh holds to the render. The engine is
# held to clusters/platform/ansiwise.sha256, and by its publish run, which writes that file's lines only
# afterwards, to the manifest it pushed. The platform's own images are pinned by tag alone (builds[] of
# the manager and gate-runner values-<stage>.yaml), so their manifest digest is the archive's own, and
# each of their blobs is still held to its name. Needs bash, awk, tar, sha256sum and jq.
# =============================================================================

recovery_archives() {
  local tree="$1" stage="$2" registry ref name tag hex values image pin
  registry=$(awk '/^global:/ { on = 1; next } on && /^[^[:space:]#]/ { exit } on && /^  buildRegistry:/ { v = $2; gsub(/["\047]/, "", v); print v; exit }' \
    "$tree/clusters/platform/values-common.yaml")
  if ! [[ "$registry" =~ ^[a-z0-9.-]+/[a-z0-9._-]+$ ]]; then
    echo "clusters/platform/values-common.yaml names no global.buildRegistry of the form <host>/<owner>: '$registry'" >&2
    return 1
  fi
  while read -r ref; do
    case "$ref" in ''|'#'*) continue ;; esac
    if ! [[ "$ref" =~ ^([a-z0-9.-]+(/[a-z0-9._-]+)+):([A-Za-z0-9_][A-Za-z0-9._-]*)@sha256:([0-9a-f]{64})$ ]]; then
      echo "clusters/platform/recovery-images.list names $ref, which is no image named by tag and digest" >&2
      return 1
    fi
    name="${BASH_REMATCH[1]}" tag="${BASH_REMATCH[3]}" hex="${BASH_REMATCH[4]}"
    echo "images/$hex.tar $name:$tag sha256:$hex"
  done < "$tree/clusters/platform/recovery-images.list"
  # One line per item of builds[], so an item without an image or a tag is refused below rather than skipped.
  for values in manager gate-runner; do
    values="clusters/inventories/$values/values-$stage.yaml"
    [ -r "$tree/$values" ] || { echo "$values cannot be read, and it pins the builds of stage $stage" >&2; return 1; }
    while read -r image tag; do
      recovery_build_archive "$registry" "$image" "$tag" 2> /dev/null || { echo "$values names a build '$image' at '$tag'" >&2; return 1; }
    done < <(awk '
      /^builds:/ { on = 1; next }
      on && /^[^[:space:]#]/ { on = 0 }
      !on { next }
      /^[[:space:]]*- / { if (items++) print image, tag; image = tag = ""; sub(/^[[:space:]]*- /, "") }
      $1 == "image:" { image = $2; gsub(/["\047]/, "", image) }
      $1 == "tag:" { tag = $2; gsub(/["\047]/, "", tag) }
      END { if (items) print image, tag }
    ' "$tree/$values")
  done
  pin=$(awk '
    /^cliTools:[ \t]*$/ { block = 1; next }
    block && /^[^ \t#]/ { exit }
    block && /^  ansiwise:[ \t]*$/ { tool = 1; next }
    tool && /^[ \t]*$/ { next }
    tool { if (match($0, /^[ \t]+version:[ \t]*"[^"]+"/)) { v = substr($0, RSTART, RLENGTH); sub(/^[^"]*"/, "", v); sub(/"$/, "", v); print v }; exit }
  ' "$tree/clusters/platform/versions.yaml")
  recovery_engine_archive "$registry" "$pin" 2> /dev/null || { echo "clusters/platform/versions.yaml pins ansiwise at '$pin'" >&2; return 1; }
}

recovery_build_archive() {
  if ! [[ "$2" =~ ^[a-z0-9]+([._-][a-z0-9]+)*$ && "$3" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]]; then
    echo "a build '$2' at '$3' is no image a registry can carry under a tag" >&2
    return 1
  fi
  echo "own/$2/$3.tar $1/$2:$3 -"
}

recovery_engine_archive() {
  if ! [[ "$2" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[a-z]+-[0-9]{14}$ && "${3:--}" =~ ^(-|sha256:[0-9a-f]{64})$ ]]; then
    echo "'$2' at '${3:--}' is no release of the engine at the digest of its manifest" >&2
    return 1
  fi
  echo "engine/$2.tar $1/ansiwise-cli:$2 ${3:--}"
}

# A SUBSHELL, so the unpacked archive goes on every path out.
recovery_archive_digest() (
  folder="$1" path="$2" name="$3" want="$4" digests="$5" unpacked="$6"
  trap 'rm -rf "$unpacked"' EXIT
  mkdir -p "$unpacked" || exit 1
  tar -xf "$folder/$path" -C "$unpacked" 2>/dev/null || { echo "$path is no tar archive" >&2; exit 1; }
  for blob in "$unpacked"/blobs/sha256/*; do
    [ -f "$blob" ] || continue
    [ "$(sha256sum < "$blob" | cut -d' ' -f1)" = "${blob##*/}" ] \
      || { echo "$path holds a blob named sha256:${blob##*/} whose bytes have another digest" >&2; exit 1; }
  done
  held=$(jq -r '[.manifests[]? | "\(.digest) \(.annotations["org.opencontainers.image.ref.name"] // "")"] | join(", ")' "$unpacked/index.json" 2>/dev/null) \
    || { echo "$path holds no index.json that can be read" >&2; exit 1; }
  digest="${held%% *}"
  if [[ "$held" == *,* ]] || [ "${held#* }" != "$name" ] || ! [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo "$path holds '${held:-nothing}', not the one image $name" >&2
    exit 1
  fi
  [ "$want" = - ] || [ "$digest" = "$want" ] || { echo "$path holds $name at $digest, and it is held to $want" >&2; exit 1; }
  # Every manifest the index reaches, and every blob such a manifest names, is in the archive.
  manifests="$digest"
  while [ -n "$manifests" ]; do
    manifest="${manifests%% *}"
    [ "$manifest" = "$manifests" ] && manifests='' || manifests="${manifests#* }"
    [ -f "$unpacked/blobs/sha256/${manifest#sha256:}" ] || { echo "$path names the manifest $manifest and holds no blob of it" >&2; exit 1; }
    named=$(jq -r '(.manifests[]? | "manifest \(.digest)"), (.config.digest // empty | "blob \(.)"), (.layers[]? | "blob \(.digest)")' \
      "$unpacked/blobs/sha256/${manifest#sha256:}" 2>/dev/null) || { echo "$path holds the manifest $manifest, and it is no JSON" >&2; exit 1; }
    while read -r kind blob; do
      [ -n "$blob" ] || continue
      [ -f "$unpacked/blobs/sha256/${blob#sha256:}" ] || { echo "$path names the $kind $blob and does not hold it" >&2; exit 1; }
      [ "$kind" = blob ] || manifests="${manifests:+$manifests }$blob"
    done <<< "$named"
  done
  case "$path" in
    engine/*)
      # Held to the release's digests where they are written, and else to the manifest digest alone.
      [ "$digests" != - ] || [ "$want" != - ] || { echo "$path is held to no digest of the engine" >&2; exit 1; }
      [ "$digests" = - ] || for tool in ansiwise ansiwise-rest; do
        hex=$(awk -v asset="$tool-${name##*:}-linux-x64" '$2 == asset { print $1 }' "$digests")
        [[ "$hex" =~ ^[0-9a-f]{64}$ && -f "$unpacked/blobs/sha256/$hex" ]] \
          || { echo "$path holds no $tool-${name##*:}-linux-x64 at the digest $digests states" >&2; exit 1; }
      done
      ;;
  esac
  echo "$digest"
)
