#!/usr/bin/env bash
# The images the owner's mirror holds: every image ref the platform tree renders on ghcr.io or under a
# mirror of it.
#
#   bash scripts/list-mirror-images.sh              one entry per image: <source> <mirror name>
#   bash scripts/list-mirror-images.sh --rendered   every such ref as the tree renders it: <ref> <where>
#   bash scripts/list-mirror-images.sh --refs       the refs of one render, read on standard input
#   bash scripts/list-mirror-images.sh --entries    the entries of "<ref> [<where>]" lines read on standard input
#   bash scripts/list-mirror-images.sh --hub        the Docker Hub repositories the tree names: <namespace>/<name> <where>
#
# ONE LIST, THREE READERS. scripts/check.sh holds every rendered ref to where it may point, the
# `mirror` task of clusters/inventories/consumer-build/templates/pipeline-publish.yaml copies every
# entry into the mirror, and lifecycle/release-platform.sh pins nothing before the mirror serves every
# entry. All three run this script on the tree they act on.
#
# AN ENTRY is the source `ghcr.io/<path>:<tag>@sha256:<hex>` and the mirror name
# `<global.buildRegistry>/ghcr.io/<path>:<tag>@sha256:<hex>`. A ref without its tag or its digest has no
# entry and fails the list by name: the mirror copies one digest, and a tag alone names whatever the
# upstream moves it to.
#
# --hub lists, from the same render, the repositories of every `image:` that names Docker Hub, with or
# without docker.io before it: the names the Docker Hub pull-through of the registry must admit
# (clusters/inventories/registry, scripts/zot-sync.test.mjs). An official image is library/<name>.
#
# THE TREE IS RENDERED THE WAY scripts/check.sh RENDERS IT: every chart under clusters/inventories,
# clusters/units, clusters/slaves and clusters/argocd at every stage, from the trunk's values, else with
# the stand-in installation, else with the placeholder taken for a tag; the build chart for a unit with
# builds and for one without; and the four releases the deploy program installs before Argo CD exists,
# with their values under clusters/bootstrap, at the chart versions clusters/platform/versions.yaml pins.
# It fetches the charts these name and nothing else.
set -uo pipefail
export LC_ALL=C

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
cd "$root" || exit 1
fail() { echo "list-mirror-images: FAIL — $1" >&2; exit 1; }
for tool in helm yq; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is not on this path, and the tree is rendered with it"
done

mirror="$(yq '.global.buildRegistry' clusters/platform/values-common.yaml)/ghcr.io"
[[ "$mirror" =~ ^[a-z0-9.-]+/[a-z0-9._-]+/ghcr\.io$ ]] \
  || fail "clusters/platform/values-common.yaml names no global.buildRegistry of the form <host>/<owner>, so the mirror has no name"

# A ref under any other name of a mirror of ghcr.io is read too, so a stale mirror name fails the list. A
# word before ghcr.io that no registry name can spell, an oci:// chart source or a <placeholder> of a
# text, is no image ref.
refs_in() { # a render on standard input -> every string in it that names an image on ghcr.io or under a mirror of it, one per line
  yq '.. | select(tag == "!!str")' | tr -s "[:space:]\"',=" '[\n*]' | grep -E '^([a-z0-9._-]+/)*ghcr\.io/' || true
}

entries_of() { # "<ref> [<where>]" lines on standard input -> the sorted entries
  local entries twice
  entries="$(while read -r ref where; do
    [ -n "$ref" ] || continue
    case "$ref" in
      "$mirror/"*) image="${ref#"$mirror/"}" ;;
      ghcr.io/*) image="${ref#ghcr.io/}" ;;
      *) image="" ;;
    esac
    if ! [[ "$image" =~ ^([a-z0-9]+([._-][a-z0-9]+)*(/[a-z0-9]+([._-][a-z0-9]+)*)*):([A-Za-z0-9_][A-Za-z0-9._-]{0,127})@(sha256:[0-9a-f]{64})$ ]]; then
      echo "list-mirror-images: FAIL — $ref (${where:-read on standard input}) is no ref ghcr.io/<path>:<tag>@sha256:<digest> or $mirror/<path>:<tag>@sha256:<digest>, and the mirror copies one digest under its tag" >&2
      exit 1
    fi
    printf 'ghcr.io/%s:%s@%s %s/%s:%s@%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[5]}" "${BASH_REMATCH[6]}" \
      "$mirror" "${BASH_REMATCH[1]}" "${BASH_REMATCH[5]}" "${BASH_REMATCH[6]}"
  done | sort -u)" || return 1
  twice="$(printf '%s\n' "$entries" | sed 's/@.*//' | uniq -d | head -n 1)"
  if [ -n "$twice" ]; then
    echo "list-mirror-images: FAIL — $twice is named at two digests, and the mirror holds one digest under each tag" >&2
    return 1
  fi
  printf '%s\n' "$entries"
}

hub_repositories_in() { # a render on standard input -> the Docker Hub repository of every `image:` in it, one per line
  local ref name first
  yq --no-doc '.. | select(tag == "!!map") | .image | select(tag == "!!str")' | while read -r ref; do
    [ -n "$ref" ] || continue
    # A Tekton substitution is filled in at run time from a param, and every param of an image in this tree
    # carries the platform registry's host before it.
    [[ "$ref" == *'$('* ]] && continue
    [[ "$ref" =~ ^[a-z0-9._/-]+(:[A-Za-z0-9._-]+)?(@sha256:[0-9a-f]{64})?$ ]] \
      || { echo "list-mirror-images: FAIL — the image '$ref' is no ref, so its registry cannot be told" >&2; return 1; }
    name="${ref#docker.io/}"
    name="${name#index.docker.io/}"
    first="${name%%/*}"
    [[ "$name" == */* && ( "$first" == *.* || "$first" == localhost ) ]] && continue
    name="${name%%@*}"
    [[ "${name##*/}" == *:* ]] && name="${name%:*}"
    [[ "$name" == */* ]] || name="library/$name"
    printf '%s\n' "$name"
  done
}

case "${1:-}" in
  --hub) hub=1 ;;
  --refs) refs_in; exit 0 ;;
  --entries) entries_of; exit ;;
  --rendered|'') ;;
  *) fail "usage: bash scripts/list-mirror-images.sh [--rendered | --refs | --entries | --hub]" ;;
esac

work="$(mktemp -d)" && mkdir "$work/bootstrap" || fail "no temporary directory could be made"
trap 'rm -rf "$work"' EXIT
standin=(-f scripts/standin/installation-values.yaml -f scripts/standin/cluster-map.yaml -f scripts/standin/registration.yaml)
apis=(--api-versions monitoring.coreos.com/v1 --api-versions monitoring.coreos.com/v1alpha1)

render() { # <where> <helm template arguments...> -> "<ref> <where>" for every ref of that render
  local where="$1"
  shift
  helm template "$@" > "$work/render" 2> "$work/render.err" || return 1
  if [ -n "${hub:-}" ]; then
    hub_repositories_in < "$work/render" | sed "s|\$| $where|"
    return "${PIPESTATUS[0]}"
  fi
  grep -q 'ghcr\.io/' "$work/render" || return 0
  refs_in < "$work/render" | sed "s|\$| $where|"
}

render_chart() { # <chart> <stage> <extra helm arguments...> -> the refs of its first value chain that renders
  local chart="$1" stage="$2" name namespace values
  shift 2
  name="$(basename "$chart")"
  namespace="$(sed -n 's/^namespace:[[:space:]]*//p' "$chart/app.yaml" 2>/dev/null | head -n 1)"
  local args=("$name" "$chart" --namespace "${namespace:-check}" "${apis[@]}" -f clusters/platform/values-common.yaml)
  [ -f "clusters/platform/values-$stage.yaml" ] && args+=(-f "clusters/platform/values-$stage.yaml")
  for values in values-common.yaml values.yaml "values-$stage.yaml" values-size-small.yaml; do
    [ -f "$chart/$values" ] && args+=(-f "$chart/$values")
  done
  render "$name at stage $stage" "${args[@]}" "$@" \
    || render "$name at stage $stage" "${args[@]}" "${standin[@]}" "$@" \
    || render "$name at stage $stage" "${args[@]}" "${standin[@]}" --set global.placeholderTag=list-takes-the-placeholder-for-a-tag "$@" \
    || { cat "$work/render.err" >&2; fail "$name renders at stage $stage from no value chain, so its images cannot be listed"; }
}

# UPDATE, AND EVERY TIME: a library chart under clusters/charts is packaged into charts/ at the version
# its Chart.yaml states, and an edit of it keeps that version, so a copy packaged before the edit looks
# current to `helm dependency list` and renders the old templates. A chart whose dependencies name no
# repository is vendored, and helm refuses to update it.
dependencies_of() { # <chart>
  grep -qE '^[[:space:]]+repository:' "$1/Chart.yaml" || return 0
  helm dependency update "$1" > "$work/dependency.out" 2>&1 \
    || { cat "$work/dependency.out" >&2; fail "the dependencies of $1 could not be fetched"; }
}

{
  for chart in clusters/inventories/*/ clusters/units/*/ clusters/slaves/*/ clusters/argocd/; do
    chart="${chart%/}"
    [ -f "$chart/Chart.yaml" ] || continue
    grep -qE '^type:[[:space:]]*library[[:space:]]*$' "$chart/Chart.yaml" && continue
    dependencies_of "$chart"
    for stage in dev test prod; do
      render_chart "$chart" "$stage"
    done
  done

  # The build chart renders its pipelines per unit only: once for the unit whose builds are the
  # platform's own images and once for the platform tree itself, which builds nothing.
  for stage in dev test prod; do
    render_chart clusters/inventories/consumer-build "$stage" --set-json \
      'unit={"name":"hostyour-manager","repoURL":"https://github.com/simetrixch/hostyour-manager.git","buildsJson":"[\"manager\",\"gate-runner\",\"dbtools\"]"}'
    render_chart clusters/inventories/consumer-build "$stage" --set-json \
      'unit={"name":"hostyour-cloud","repoURL":"https://github.com/simetrixch/hostyour-cloud.git","buildsJson":"[]"}'
  done

  # The master's Argo CD is the argo-cd chart the slave chart depends on, at the version both share.
  argo_chart="$(ls clusters/slaves/slave/charts/argo-cd-*.tgz 2>/dev/null | head -n 1)"
  [ -n "$argo_chart" ] || fail "the argo-cd chart of clusters/slaves/slave was not fetched, so the master's Argo CD cannot be rendered"
  render "the argo-cd release with clusters/bootstrap/argocd/values.tpl" argocd "$argo_chart" --namespace argocd \
    -f clusters/bootstrap/argocd/values.tpl \
    || { cat "$work/render.err" >&2; fail "the argo-cd chart does not render with clusters/bootstrap/argocd/values.tpl"; }

  # The other three bootstrap releases, by the component of clusters/platform/versions.yaml that pins each.
  for pair in headlamp:headlamp idp:authentik vault:vault; do
    release="${pair%%:*}" component="${pair#*:}"
    name="$component"
    version="$(yq ".bootstrap.$component.version" clusters/platform/versions.yaml)"
    values="$(ls clusters/bootstrap/$release/values.yaml clusters/bootstrap/$release/values.tpl 2>/dev/null | head -n 1)"
    [ -n "$values" ] || fail "clusters/bootstrap/$release carries no values.yaml or values.tpl"
    # headlamp and authentik are pulled from the mirror, by the row of mirror-sources.table that holds the version
    # versions.yaml pins; vault, which the mirror does not hold, from its own repository.
    if [ "$component" = vault ]; then
      repository="$(yq ".bootstrap.$component.upstream.repository" clusters/platform/versions.yaml)"
      helm pull "$name" --repo "$repository" --version "$version" --destination "$work/bootstrap" > "$work/pull.out" 2>&1 \
        || { cat "$work/pull.out" >&2; fail "the $name chart $version could not be fetched from $repository"; }
    else
      repository="$(bash scripts/list-mirror-sources.sh --chart "$name" "$version")" \
        || fail "versions.yaml pins the $name chart at $version, and mirror-sources.table has no row for it"
      helm pull "$repository/$name" --version "$version" --destination "$work/bootstrap" > "$work/pull.out" 2>&1 \
        || { cat "$work/pull.out" >&2; fail "the $name chart $version could not be fetched from $repository"; }
    fi
    render "the $release release with $values" "$release" "$work/bootstrap/$name-$version.tgz" --namespace "$release" -f "$values" \
      || { cat "$work/render.err" >&2; fail "the $name chart $version does not render with $values"; }
  done
} > "$work/rendered" || exit 1

if [ -n "${hub:-}" ] || [ "${1:-}" = --rendered ]; then
  sort -u "$work/rendered"
else
  entries_of < "$work/rendered"
fi
