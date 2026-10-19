# ci_cache_trim: keeps the claim ci-cache of the unit under its bound. The check step of the ci pipeline inlines this file and runs
# the function when it ends, whatever the outcome. It prints what the cache holds and what it evicted: the files with the oldest last
# access go first, until the cache is within CI_CACHE_LIMIT_KIB. The caches of the Go modules make their directories read-only, so
# a cache over the bound is made writable first. scripts/build-contract.test.mjs runs it on a planted cache.
ci_cache_trim() {
  [ -d "${CI_CACHE_DIR}" ] || return 0
  local total evicted=0 evicted_kib=0 size path kib
  total="$(du -sk "${CI_CACHE_DIR}" | cut -f1)"
  if [ "${total}" -gt "${CI_CACHE_LIMIT_KIB}" ]; then
    chmod -R u+w "${CI_CACHE_DIR}"
    while IFS=$'\t' read -r _ size path; do
      [ "${total}" -gt "${CI_CACHE_LIMIT_KIB}" ] || break
      rm -f -- "${path}"
      kib=$(((size + 1023) / 1024))
      total=$((total - kib))
      evicted_kib=$((evicted_kib + kib))
      evicted=$((evicted + 1))
    done < <(find "${CI_CACHE_DIR}" -type f -printf '%A@\t%s\t%p\n' | sort -n)
    find "${CI_CACHE_DIR}" -mindepth 1 -type d -empty -delete
  fi
  echo "ci-cache: ${total} KiB of ${CI_CACHE_LIMIT_KIB} KiB, evicted ${evicted} files (${evicted_kib} KiB), the oldest last access first"
}
