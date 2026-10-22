# ===========================================================================
# require-rclone.sh — puts the pinned rclone on the machine, for master-backup, master-restore and plane-restore, ON THE MACHINE.
#
# The two launchers send this file whole through their one ssh session, behind the metadata that read-rclone-pin.sh made
# (AW_RCLONE_PIN and AW_RCLONE_ROWS) and ahead of the driver, because a driver arrives over standard input and can read
# no sibling. It defines require_rclone and rclone_cleanup and does nothing else. The caller defines say, good and root,
# the elevation wrapper that hands sudo its password on standard input, and calls rclone_cleanup on every way out.
#
# WHY THE PIN. The rclone that Ubuntu 26.04 packages (1.60.1) leaves the last file of a multi-thread copy from the
# storage box open after its last byte: the copy never ends. lifecycle/rclone.test.sh shows it against the pinned release.
#
# WHAT IT DOES. An rclone that answers the pinned version both as the operator and as root is left alone and nothing is
# downloaded. Otherwise it takes the package of the one row for this machine's architecture: from the owned address of
# the row (the owner's mirror, never an upstream address), or from the package the launcher carried as data, which
# a restore onto a bare machine needs when the mirror is the lost master. Either way the bytes are copied to a folder of
# root's, held to the row's sha256 THERE, and installed from that copy with dpkg, so the bytes that are checked are the
# bytes that root installs. The executable that results must answer the pin as the operator and as root. A refusal sets
# RCLONE_REFUSAL and ends 1; no fallback to another source, version or package manager follows.
# ===========================================================================
AW_RCLONE_CONNECT_SECONDS=20
AW_RCLONE_TOTAL_SECONDS=900
RCLONE_WORK='' RCLONE_ROOT_WORK='' RCLONE_REFUSAL=''

rclone_cleanup() {
  [ -z "$RCLONE_WORK" ] || rm -rf "$RCLONE_WORK" 2>/dev/null || true
  [ -z "$RCLONE_ROOT_WORK" ] || root rm -rf "$RCLONE_ROOT_WORK" >/dev/null 2>&1 || true
  RCLONE_WORK='' RCLONE_ROOT_WORK=''
}

# rclone_answers: what rclone says to --version, first line, as the operator and as root.
rclone_answers() {
  RCLONE_OPERATOR_ANSWER=$(rclone --version 2>/dev/null </dev/null | head -n 1) || true
  RCLONE_ROOT_ANSWER=$(root rclone --version 2>/dev/null | head -n 1) || true
}
rclone_is_pinned() {
  rclone_answers
  [ "$RCLONE_OPERATOR_ANSWER" = "rclone $AW_RCLONE_PIN" ] && [ "$RCLONE_ROOT_ANSWER" = "rclone $AW_RCLONE_PIN" ]
}

# rclone_refuse WHAT: the reason, kept for the caller, and status 1.
rclone_refuse() { RCLONE_REFUSAL="$1"; rclone_cleanup; return 1; }

require_rclone() {
  local arch row digest address file
  RCLONE_REFUSAL=''
  [[ "${AW_RCLONE_PIN:-}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { rclone_refuse 'the launcher sent no pin of the form vX.Y.Z'; return 1; }
  if rclone_is_pinned; then
    good "rclone $AW_RCLONE_PIN answers as ${USER:-the operator} and as root; nothing is installed"
    return 0
  fi
  if [ -z "$RCLONE_OPERATOR_ANSWER" ]; then
    say "rclone is not on this machine; it is what carries the archives to the storage box and back, so $AW_RCLONE_PIN is installed now"
  else
    say "rclone answers \"${RCLONE_OPERATOR_ANSWER:0:40}\" to the operator and \"${RCLONE_ROOT_ANSWER:0:40}\" to root, and the pin is $AW_RCLONE_PIN, so it is installed now"
  fi
  arch=$(dpkg --print-architecture 2>/dev/null </dev/null) || arch=''
  case "$arch" in amd64|arm64) ;; *) rclone_refuse "this machine's package architecture \"${arch:0:20}\" has no rclone package among the rows of the platform (amd64, arm64)"; return 1 ;; esac
  row=$(printf '%s\n' "${AW_RCLONE_ROWS:-}" | awk -v arch="$arch" '$1 == arch { n++; row = $2 " " $3 } END { if (n == 1) print row; else exit 1 }') \
    || { rclone_refuse "the launcher sent not exactly one row for $arch"; return 1; }
  digest="${row%% *}" address="${row#* }"
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || { rclone_refuse "the sha256 of the row for $arch is not 64 lower-case hex digits"; return 1; }
  [[ "$address" =~ ^https://[a-z0-9.-]+/v2/[a-z0-9._/-]+/blobs/sha256:([0-9a-f]{64})$ ]] && [ "${BASH_REMATCH[1]}" = "$digest" ] \
    && [[ "$address" == *"/rclone-$AW_RCLONE_PIN-linux-$arch.deb/blobs/"* ]] \
    || { rclone_refuse "the address of the row for $arch is not the owned address of the $AW_RCLONE_PIN package at its digest"; return 1; }
  RCLONE_WORK=$(mktemp -d) || { rclone_refuse 'a private folder for the package could not be made'; return 1; }
  file="$RCLONE_WORK/rclone.deb"
  if [ -n "${AW_RCLONE_CARRIED_ARCH:-}" ]; then
    [ "$AW_RCLONE_CARRIED_ARCH" = "$arch" ] \
      || { rclone_refuse "the package carried with this restore is for $AW_RCLONE_CARRIED_ARCH and this machine is $arch"; return 1; }
    say "the package carried with this restore is used; nothing is fetched from the mirror or anywhere else"
    aw_rclone_carried_package > "$file" 2>/dev/null </dev/null || { rclone_refuse 'the package carried with this restore could not be read from the session'; return 1; }
  else
    command -v curl >/dev/null 2>&1 || { rclone_refuse 'curl is not on this machine, and the package is fetched from the owner'"'"'s mirror with it'; return 1; }
    say "fetching the rclone $AW_RCLONE_PIN package for $arch from the owner's mirror"
    curl --fail --silent --show-error --connect-timeout "$AW_RCLONE_CONNECT_SECONDS" --max-time "$AW_RCLONE_TOTAL_SECONDS" \
      --output "$file" "$address" </dev/null 2>"$RCLONE_WORK/curl.err" \
      || { rclone_refuse "the package could not be fetched from the mirror (curl ended $?): $(tr -d '\r' < "$RCLONE_WORK/curl.err" | head -c 200 | tr '\n' ' ')"; return 1; }
  fi
  RCLONE_ROOT_WORK=$(root mktemp -d </dev/null) || { rclone_refuse 'a folder of root for the package could not be made'; return 1; }
  root install -m 600 -o root -g root "$file" "$RCLONE_ROOT_WORK/rclone.deb" >/dev/null 2>&1 \
    || { rclone_refuse 'the package could not be copied into the folder of root'; return 1; }
  # The copy root installs is the copy that is checked; a file that is not the row's is never handed to dpkg.
  root sh -c 'printf "%s  %s\n" "$1" "$2" | sha256sum -c --quiet' _ "$digest" "$RCLONE_ROOT_WORK/rclone.deb" >/dev/null 2>&1 \
    || { rclone_refuse "the package is not the rclone $AW_RCLONE_PIN package for $arch: its sha256 is not $digest, the digest of the row, and it is not installed"; return 1; }
  good "the package is the rclone $AW_RCLONE_PIN package for $arch: its sha256 is the row's"
  root dpkg -i "$RCLONE_ROOT_WORK/rclone.deb" >"$RCLONE_WORK/dpkg.log" 2>&1 \
    || { rclone_refuse "the package could not be installed (dpkg ended $?): $(tail -n 3 "$RCLONE_WORK/dpkg.log" | tr -d '\r' | head -c 300 | tr '\n' ' ')"; return 1; }
  hash -r
  rclone_is_pinned \
    || { rclone_refuse "after the installation rclone answers \"${RCLONE_OPERATOR_ANSWER:0:40}\" to the operator and \"${RCLONE_ROOT_ANSWER:0:40}\" to root, and the pin is $AW_RCLONE_PIN"; return 1; }
  rclone_cleanup
  good "rclone $AW_RCLONE_PIN stands on this machine, as the operator and as root"
}
