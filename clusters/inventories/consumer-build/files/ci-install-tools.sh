# Puts the tools a repository's ci-tools.json names first on PATH. The ci pipeline inlines this file in
# its check step after the fixed tools (helm, yq, jq) and before the repository's own install and check;
# scripts/build-contract.test.mjs runs it against a stand-in table and stand-in archives.
#
# CI_TOOLS is what the fetch task's list-tools step validated, one "<tool> <version>" per line, and empty
# for a repository without ci-tools.json. CI_TOOLS_TABLE is files/ci-tools.table, one
# "<tool> <version> <sha256> <url>" per line. A tool or version the table lacks ends the run before
# anything is downloaded, and an archive whose sha256 differs ends it before anything is unpacked: a
# check that ran with the image's own tool instead of the one it named reads exactly like a check that
# ran with the right one. Tools are installed in the order of the table, so npm stands before node on
# PATH, and everything installed stands before the image's own.
ci_tools_dir=/tmp/ci-tools
mkdir -p "${ci_tools_dir}/bin"
printf '%s\n' "${CI_TOOLS}" > "${ci_tools_dir}/wanted"
printf '%s\n' "${CI_TOOLS_TABLE}" > "${ci_tools_dir}/table"

while read -r tool version; do
  [ -n "${tool}" ] || continue
  if ! awk -v tool="${tool}" -v version="${version}" '$1 == tool && $2 == version { found = 1 } END { exit !found }' "${ci_tools_dir}/table"; then
    echo "check: ci-tools.json names ${tool} ${version}, which the tools table of this pipeline does not carry" >&2
    exit 1
  fi
done < "${ci_tools_dir}/wanted"

PATH="${ci_tools_dir}/bin:${PATH}"
while read -r tool version sha256 url; do
  grep -qxF "${tool} ${version}" "${ci_tools_dir}/wanted" || continue
  archive="${ci_tools_dir}/${tool}.download"
  curl -fsSL -o "${archive}" "${url}"
  echo "${sha256}  ${archive}" | sha256sum -c -
  case "${tool}" in
    node | go)
      mkdir -p "${ci_tools_dir}/${tool}"
      tar -xzf "${archive}" -C "${ci_tools_dir}/${tool}" --strip-components=1
      PATH="${ci_tools_dir}/${tool}/bin:${PATH}"
      ;;
    npm)
      # The tarball holds the package, not a prefix: npm-cli.js and npx-cli.js start with a node shebang.
      # Its own directory stands before node's, whose bin holds the npm that node ships with.
      mkdir -p "${ci_tools_dir}/npm" "${ci_tools_dir}/npm-bin"
      tar -xzf "${archive}" -C "${ci_tools_dir}/npm" --strip-components=1
      chmod +x "${ci_tools_dir}/npm/bin/npm-cli.js" "${ci_tools_dir}/npm/bin/npx-cli.js"
      ln -s "${ci_tools_dir}/npm/bin/npm-cli.js" "${ci_tools_dir}/npm-bin/npm"
      ln -s "${ci_tools_dir}/npm/bin/npx-cli.js" "${ci_tools_dir}/npm-bin/npx"
      PATH="${ci_tools_dir}/npm-bin:${PATH}"
      ;;
    dart)
      unzip -q "${archive}" -d "${ci_tools_dir}/dart"
      PATH="${ci_tools_dir}/dart/dart-sdk/bin:${PATH}"
      ;;
    gitleaks)
      tar -xzf "${archive}" -C "${ci_tools_dir}/bin" gitleaks
      ;;
    promtool)
      tar -xzf "${archive}" -C "${ci_tools_dir}/bin" --strip-components=1 "prometheus-${version}.linux-amd64/promtool"
      ;;
    *)
      echo "check: the tools table of this pipeline names ${tool}, which this step cannot install" >&2
      exit 1
      ;;
  esac
  rm -f "${archive}"
  echo "check: ${tool} ${version}, ${url}, sha256 ${sha256}"
done < "${ci_tools_dir}/table"
