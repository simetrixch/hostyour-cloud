# The two calls every push to the registry is made of: `push` and `copy-sources` of the publish pipeline
# include this file, and both hold the push identity in REGISTRY_USERNAME and REGISTRY_PASSWORD.

# One bounded call to the registry, the URL last: the HTTP status, or a failure that names curl's exit.
registry_call() { # <body file> <curl arguments...>
  local out="$1" code rc=0
  shift
  code="$(curl -sS --connect-timeout 10 --max-time 600 -u "${REGISTRY_USERNAME}:${REGISTRY_PASSWORD}" -o "${out}" -w '%{http_code}' "$@")" || rc=$?
  if [ "${rc}" != 0 ]; then
    echo "publish: FAIL — curl exited ${rc} on ${*: -1} (28 is the 600s ceiling, reached when the registry is still fetching from an upstream)" >&2
    return 1
  fi
  printf '%s' "${code}"
}
push_blob() { # <repository URL> <file> <digest> <scratch folder>: the blob stands in the repository afterwards
  local base="$1" file="$2" digest="$3" tmp="$4" code location
  code="$(registry_call /dev/null -I "${base}/blobs/${digest}")" || return 1
  [ "${code}" != 200 ] || return 0
  code="$(registry_call /dev/null -D "${tmp}/headers" -X POST "${base}/blobs/uploads/")" || return 1
  if [ "${code}" != 202 ]; then
    echo "publish: FAIL — ${base}/blobs/uploads/ answered ${code} to the start of an upload" >&2
    return 1
  fi
  location="$(tr -d '\r' < "${tmp}/headers" | awk 'tolower($1) == "location:" { print $2 }' | tail -n 1)"
  case "${location}" in
    /*) location="https://${REGISTRY}${location}" ;;
    https://*) ;;
    *) echo "publish: FAIL — the upload to ${base} named no location to put ${digest}" >&2; return 1 ;;
  esac
  case "${location}" in *\?*) location="${location}&digest=${digest}" ;; *) location="${location}?digest=${digest}" ;; esac
  # -T streams the file from disk; --data-binary reads all of it into memory first, which a tool of 220 MB
  # does not fit beside the limit of the step.
  code="$(registry_call /dev/null -X PUT -H 'Content-Type: application/octet-stream' -T "${file}" "${location}")" || return 1
  if [ "${code}" != 201 ]; then
    echo "publish: FAIL — the blob ${digest} was answered ${code} at ${base}" >&2
    return 1
  fi
}
