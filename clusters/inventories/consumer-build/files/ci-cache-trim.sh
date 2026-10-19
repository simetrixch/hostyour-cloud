# ci_cache_trim: keeps the claim ci-cache of the unit under its bound. The check step of the ci pipeline inlines this file and runs
# the function when it ends, whatever the outcome. It prints what the cache holds and what it evicted: the entries with the oldest
# last access go first, until the cache is within CI_CACHE_LIMIT_KIB. The caches of the Go modules make their directories
# read-only, so a cache over the bound is made writable first. scripts/build-contract.test.mjs runs it on planted caches.
#
# An entry is a file, or a directory that a tool takes as complete as soon as it exists and never checks again: a file removed
# from inside such a directory is never fetched again, and every later run fails on it. Those directories go whole or stay:
#   go/<version>/mod/<module>@<version>      go takes the extracted module as complete when the directory and its .ziphash exist
#   go/<version>/mod/cache/vcs/<repository>  go's clone of a repository
#   corepack/v1/<manager>/<version>          corepack takes an unpacked package manager as complete when its .corepack file reads
#   pub/<version>/hosted/<host>/<package>    pub takes a package folder as complete when it exists
#   pub/<version>/git/<name>                 pub's clone of a repository, and its checkout
# Every other file stands alone: the build cache of go, the download cache of go (a missing .zip, .mod or .ziphash is fetched
# again), the content store of pnpm, the cache of npm, the repository cache of helm, the hashes and version lists of pub and the
# archives of the tools each come back by themselves when one is missing.
# The volume is mounted relatime, so a last access is exact to a day at best: the order is that of a cache that was
# read within the day, not of one that was read a minute before. The local storage class does not enforce the size of the
# claim, so the bound holds when the check step ends and not while it runs.
ci_cache_entries() (
  cd "${CI_CACHE_DIR}"
  find . -printf '%y\t%A@\t%k\t%p\n' | awk -F '\t' '
    # The length of the first components of a path that name the directory entry it lies in, or 0 for a path that stands alone.
    function entry(p, n,   i) {
      if (p[2] == "go" && p[4] == "mod" && n >= 5) {
        if (p[5] == "cache") return (p[6] == "vcs" && n >= 7) ? 7 : 0
        for (i = 5; i <= n; i++) if (p[i] ~ /@/) return i
        return 0
      }
      if (p[2] == "corepack" && p[3] == "v1" && n >= 5) return 5
      if (p[2] == "pub" && p[4] == "hosted" && n >= 6 && p[6] !~ /^[.]/) return 6
      if (p[2] == "pub" && p[4] == "git" && n >= 5) return 5
      return 0
    }
    {
      n = split($4, p, "/")
      depth = entry(p, n)
      if (depth == 0) {
        if ($1 != "d") printf "%s\t%s\t%s\n", $2, $3, $4
        next
      }
      root = p[1]
      for (i = 2; i <= depth; i++) root = root "/" p[i]
      kib[root] += $3
      if ($1 != "d" && (!(root in newest) || $2 + 0 > newest[root] + 0)) newest[root] = $2
    }
    END { for (root in kib) printf "%s\t%s\t%s\n", (root in newest ? newest[root] : 0), kib[root], root }'
)

ci_cache_trim() {
  [ -d "${CI_CACHE_DIR}" ] || return 0
  local total evicted=0 evicted_kib=0 kib path
  total="$(du -sk "${CI_CACHE_DIR}" | cut -f1)"
  if [ "${total}" -gt "${CI_CACHE_LIMIT_KIB}" ]; then
    chmod -R u+w "${CI_CACHE_DIR}"
    while IFS=$'\t' read -r _ kib path; do
      [ "${total}" -gt "${CI_CACHE_LIMIT_KIB}" ] || break
      rm -rf -- "${CI_CACHE_DIR}/${path}"
      total=$((total - kib))
      evicted_kib=$((evicted_kib + kib))
      evicted=$((evicted + 1))
    done < <(ci_cache_entries | LC_ALL=C sort -n)
    find "${CI_CACHE_DIR}" -mindepth 1 -type d -empty -delete
    total="$(du -sk "${CI_CACHE_DIR}" | cut -f1)"
  fi
  echo "ci-cache: ${total} KiB of ${CI_CACHE_LIMIT_KIB} KiB, evicted ${evicted} entries (${evicted_kib} KiB), the oldest last access first"
}
