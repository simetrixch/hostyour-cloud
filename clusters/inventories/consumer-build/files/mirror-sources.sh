# The tools and charts of the owner's mirror: the one form each kind of upstream may take, and the names
# the mirror serves it under, below the registry and owner REGISTRY and OWNER name. The list of the
# platform tree is written from the rows of clusters/platform/mirror-sources.table with these functions,
# and the steps fetch, copy-sources and read-back-sources of the mirror include this file and hold every
# line of that list to them again. Every form is a regular expression with escaped dots: a path component
# of a registry, a lower-case host name, and a chart version that is a tag of a registry.
mirror_source_component='[a-z0-9]+((\.|_|__|-+)[a-z0-9]+)*'
mirror_source_host='[a-z0-9]+(-+[a-z0-9]+)*(\.[a-z0-9]+(-+[a-z0-9]+)*)+'
mirror_source_tool="^https://github\.com/${mirror_source_component}/${mirror_source_component}/releases/download/${mirror_source_component}/${mirror_source_component}\$"
mirror_source_repository="^(https://${mirror_source_host}(/${mirror_source_component})*|oci://${mirror_source_host}(/${mirror_source_component})+)\$"
mirror_source_version='^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$'

mirror_source_line() { # tool <url> <sha256> | chart <repository> <chart> <version> <sha256>: the line of that row, or why it has none, and status 1
  local place tag
  case "${1:-} $#" in
    "tool 3" | "chart 5") ;;
    *)
      echo "a row is tool <url> <sha256> or chart <repository> <chart> <version> <sha256>"
      return 1
      ;;
  esac
  if ! [[ "${@: -1}" =~ ^[0-9a-f]{64}$ ]]; then
    echo "the sha256 ${*: -1} is not 64 lower-case hex digits"
    return 1
  fi
  case "$1" in
    tool)
      if ! [[ "$2" =~ ${mirror_source_tool} ]]; then
        echo "the url $2 is no asset of a GitHub Release whose owner, name, tag and file are lower-case path components"
        return 1
      fi
      # The tag of the release is the path component before the file name, and the tag of the owned reference.
      tag="${2%/*}"
      place="${OWNER}/${2#https://}"
      printf 'tool %s %s %s/%s:%s https://%s/v2/%s/blobs/sha256:%s\n' "$2" "$3" "${REGISTRY}" "${place}" "${tag##*/}" "${REGISTRY}" "${place}" "$3"
      ;;
    chart)
      if ! [[ "$2" =~ ${mirror_source_repository} ]]; then
        echo "the repository $2 is neither a chart repository index over https nor an oci registry, by a lower-case host and path without a trailing slash"
        return 1
      fi
      if ! [[ "$3" =~ ^${mirror_source_component}$ ]]; then
        echo "the chart $3 is no lower-case path component"
        return 1
      fi
      if ! [[ "$4" =~ ${mirror_source_version} ]]; then
        echo "the version $4 is no chart version a registry can carry as a tag"
        return 1
      fi
      place="${REGISTRY}/${OWNER}/${2#*://}"
      printf 'chart %s %s %s %s %s/%s:%s oci://%s\n' "$2" "$3" "$4" "$5" "${place}" "$3" "$4" "${place}"
      ;;
  esac
}

mirror_source_target() { # <line>: its owned reference, once the line is the line of its own row under REGISTRY and OWNER; else a refusal naming it
  local line="$1" row derived reference
  read -r -a row <<< "${line}"
  case "${row[0]:-} ${#row[@]}" in
    "tool 5") derived="$(mirror_source_line "${row[@]:0:3}")" && reference="${row[3]}" ;;
    "chart 7") derived="$(mirror_source_line "${row[@]:0:5}")" && reference="${row[5]}" ;;
    *) derived="it is no line of a tool or a chart"; false ;;
  esac || { echo "mirror: REFUSE — ${line}: ${derived}" >&2; return 1; }
  if [ "${derived}" != "${line}" ]; then
    echo "mirror: REFUSE — ${line} is not the line of its row under ${REGISTRY}/${OWNER}, which is ${derived}" >&2
    return 1
  fi
  printf '%s\n' "${reference}"
}

mirror_source_held() { # <owned reference> <sha256> <a folder of its own>: served, absent or other, then what the mirror answered to a read without a login
  local reference="$1" hex="$2" scratch="$3" path code layer rc=0
  path="${reference#*/}"
  mkdir -p "${scratch}" || return 1
  code="$(curl -sS --connect-timeout 10 --max-time 120 -H 'Accept: application/vnd.oci.image.manifest.v1+json' -o "${scratch}/held.json" -w '%{http_code}' \
    "https://${reference%%/*}/v2/${path%:*}/manifests/${path##*:}")" || rc=$?
  if [ "${rc}" != 0 ]; then
    echo "other was not read (curl exited ${rc})"
  elif [ "${code}" = 404 ]; then
    echo "absent answered 404"
  elif [ "${code}" != 200 ]; then
    echo "other answered ${code}"
  else
    layer="$(jq -r 'if (.layers | length) == 1 then "the one layer " + .layers[0].digest else "\(.layers | length) layers" end' "${scratch}/held.json" 2>/dev/null)" \
      || layer="no manifest"
    if [ "${layer}" = "the one layer sha256:${hex}" ]; then
      echo "served answered 200 with ${layer}"
    else
      echo "other answered 200 with ${layer}"
    fi
  fi
}
