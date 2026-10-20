# Puts the tools a repository's ci-tools.json names first on PATH. The publish pipeline inlines this file
# in pack and in build-binaries, before the repository's own install and release build; scripts/build-contract.test.mjs runs it against a stand-in table and
# stand-in archives.
#
# CI_TOOLS is what the scan step of the publish pipeline read, one "<tool> <version>" per line, and empty
# for a repository without ci-tools.json. CI_TOOLS_TABLE is files/ci-tools.table, one
# "<tool> <version> <sha256> <url>" per line, where a "<sha256>" in the url stands for the row's sha256 and is filled
# in before the download, so the hex stands once per row (the owner's mirror serves a file by the blob of its sha256).
# A tool or version the table lacks ends the run before anything is downloaded, and an archive whose sha256 differs
# ends it before anything is unpacked: a
# check that ran with the image's own tool instead of the one it named reads exactly like a check that
# ran with the right one. Tools are installed in the order of the table, so npm stands before node on
# PATH, and everything installed stands before the image's own.
ci_download() {
  curl -fsSL -o "$3" "$1"
  echo "$2  $3" | sha256sum -c -
}
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
sha256_slot='<sha256>'
while read -r tool version sha256 url; do
  grep -qxF "${tool} ${version}" "${ci_tools_dir}/wanted" || continue
  archive="${ci_tools_dir}/${tool}.download"
  started="${SECONDS}"
  url="${url//${sha256_slot}/${sha256}}"
  ci_download "${url}" "${sha256}" "${archive}"
  downloaded="${SECONDS}"
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
    gitleaks | traefik)
      tar -xzf "${archive}" -C "${ci_tools_dir}/bin" "${tool}"
      ;;
    kubectl)
      # The download is the program itself, not an archive.
      install -m 0755 "${archive}" "${ci_tools_dir}/bin/kubectl"
      ;;
    emcc)
      # The SDK release emsdk installs for this version: LLVM in bin, Binaryen's programs beside it, emcc in
      # emscripten. What emsdk install and activate write, this writes: the version the release stands for, which
      # the archive itself spells <x.y.z>-git, and the roots emcc reads from the .emscripten beside it; emcc finds
      # node on PATH. emsdk itself never runs, so nothing is fetched that the table does not vouch for.
      mkdir -p "${ci_tools_dir}/emcc"
      tar -xJf "${archive}" -C "${ci_tools_dir}/emcc" --strip-components=1
      printf '"%s"\n' "${version}" > "${ci_tools_dir}/emcc/emscripten/emscripten-version.txt"
      printf "LLVM_ROOT = '%s'\nBINARYEN_ROOT = '%s'\n" "${ci_tools_dir}/emcc/bin" "${ci_tools_dir}/emcc" > "${ci_tools_dir}/emcc/emscripten/.emscripten"
      PATH="${ci_tools_dir}/emcc/emscripten:${PATH}"
      emcc_version="$(emcc --version)"
      echo "check: ${emcc_version%%$'\n'*}, downloaded in $((downloaded - started)) s and unpacked in $((SECONDS - downloaded)) s"
      ;;
    *)
      echo "check: the tools table of this pipeline names ${tool}, which this step cannot install" >&2
      exit 1
      ;;
  esac
  rm -f "${archive}"
  echo "check: ${tool} ${version}, ${url}, sha256 ${sha256}"
done < "${ci_tools_dir}/table"
