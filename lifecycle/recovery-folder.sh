# shellcheck shell=bash
# =============================================================================
# recovery-folder.sh — what the recovery folder of the owner's master holds, and the test each archive
# of it passes. SOURCED, NEVER RUN: the `recovery-export` task of the platform's publish run reads it
# from the tree at the release tag and writes the folder, and driver.sh reads it from the installation's
# checkout and fetches the folder into a cold node. Both name every archive the same way because both
# run these lines, and both refuse an archive for the same reasons.
#
#   recovery_archives <tree> <stage>
#       one line per archive the tree names: <path in the folder> <name:tag> <manifest digest, or ->
#   recovery_archive_digest <folder> <path in it> <name:tag> <manifest digest, or -> <tree> <a folder of its own>
#       the digest of the one manifest the archive holds, or on standard error what is wrong with it
#
# THE DIGESTS ARE THE TREE'S, never the folder's. A pinned image is held to the digest the tree names for
# it in clusters/platform/recovery-images.list, which scripts/check.sh holds to the render. The engine is
# held to clusters/platform/ansiwise.sha256. The platform's own images are pinned by tag alone
# (builds[] of the manager and gate-runner values-<stage>.yaml), so their manifest digest is the
# archive's own, and each of their blobs is still held to its name. Needs bash, awk, tar, sha256sum and jq.
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
      if ! [[ "$image" =~ ^[a-z0-9]+([._-][a-z0-9]+)*$ && "$tag" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]]; then
        echo "$values names a build '$image' at '$tag'" >&2
        return 1
      fi
      echo "own/$image/$tag.tar $registry/$image:$tag -"
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
  if ! [[ "$pin" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[a-z]+-[0-9]{14}$ ]]; then
    echo "clusters/platform/versions.yaml pins ansiwise at '$pin'" >&2
    return 1
  fi
  echo "engine/$pin.tar $registry/ansiwise-cli:$pin -"
}

# A SUBSHELL, so the unpacked archive goes on every path out.
recovery_archive_digest() (
  folder="$1" path="$2" name="$3" want="$4" tree="$5" unpacked="$6"
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
  [ "$want" = - ] || [ "$digest" = "$want" ] || { echo "$path holds $name at $digest, and the tree names $want" >&2; exit 1; }
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
      for tool in ansiwise ansiwise-rest; do
        hex=$(awk -v asset="$tool-${name##*:}-linux-x64" '$2 == asset { print $1 }' "$tree/clusters/platform/ansiwise.sha256")
        [[ "$hex" =~ ^[0-9a-f]{64}$ && -f "$unpacked/blobs/sha256/$hex" ]] \
          || { echo "$path holds no $tool-${name##*:}-linux-x64 at the digest clusters/platform/ansiwise.sha256 states" >&2; exit 1; }
      done
      ;;
  esac
  echo "$digest"
)
