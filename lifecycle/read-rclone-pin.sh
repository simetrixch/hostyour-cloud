# ===========================================================================
# read-rclone-pin.sh — what a launcher tells a machine about the rclone it must run, from the tree it was released in.
#
# Sourced by master-backup.sh, master-restore.sh and plane-restore.sh, which send this metadata through their one ssh session, with
# require-rclone.sh, ahead of the driver. The pin is cliTools.rclone.version of clusters/platform/versions.yaml; the
# digest of the package and its owned address are those of the two rows of clusters/platform/mirror-sources.table
# (amd64 and arm64), made with mirror_source_line and global.buildRegistry. A launcher runs on any operator machine
# and needs no YAML tool, so every scalar is read by its exact line shape and each shape is held to yq by lifecycle/test.sh.
#
#   read_rclone_pin <tree>
#       ends 0 and sets RCLONE_METADATA to the assignments the machine reads (AW_RCLONE_PIN and AW_RCLONE_ROWS, one
#       row "<arch> <sha256> <address>" a line); ends 1 and sets RCLONE_METADATA_ERROR to what is wrong.
#   carry_rclone_package <tree> <file>
#       ends 0 when the file is exactly one of the packages of the rows, setting RCLONE_CARRIED_ARCH to its
#       architecture; ends 1 and sets RCLONE_METADATA_ERROR otherwise.
# ===========================================================================
RCLONE_ARCHITECTURES='amd64 arm64'

read_rclone_pin() {
  local tree="$1" versions table values registry arch url digest line address found row
  versions="$tree/clusters/platform/versions.yaml" table="$tree/clusters/platform/mirror-sources.table" values="$tree/clusters/platform/values-common.yaml"
  RCLONE_METADATA='' RCLONE_METADATA_ERROR='' RCLONE_PIN='' RCLONE_ROWS=''
  [ -r "$versions" ] && [ -r "$table" ] && [ -r "$values" ] && [ -r "$tree/clusters/inventories/consumer-build/files/mirror-sources.sh" ] \
    || { RCLONE_METADATA_ERROR="the released tree at $tree does not carry versions.yaml, mirror-sources.table, values-common.yaml and mirror-sources.sh of the platform"; return 1; }
  RCLONE_PIN=$(LC_ALL=C awk '
    /^cliTools:[ \t]*$/ { block = 1; next }
    block && /^[^ \t#]/ { block = 0 }
    block && /^  [A-Za-z0-9_-]+:[ \t]*$/ { entry = ($1 == "rclone:"); next }
    block && entry && /^    version:[ \t]*"v[0-9]+\.[0-9]+\.[0-9]+"[ \t]*$/ { pin = $2; gsub(/"/, "", pin); n++ }
    END { if (n == 1) print pin; else exit 1 }' "$versions") \
    || { RCLONE_METADATA_ERROR="$versions states no single cliTools.rclone.version of the form \"vX.Y.Z\""; return 1; }
  registry=$(LC_ALL=C awk '
    /^global:[ \t]*$/ { block = 1; next }
    block && /^[^ \t#]/ { block = 0 }
    block && /^  buildRegistry:[ \t]*"[a-z0-9.-]+\/[a-z0-9._-]+"[ \t]*$/ { registry = $2; gsub(/"/, "", registry); n++ }
    END { if (n == 1) print registry; else exit 1 }' "$values") \
    || { RCLONE_METADATA_ERROR="$values states no single global.buildRegistry of the form <host>/<owner>"; return 1; }
  # mirror_source_line names the registry and owner it derives from in these two variables.
  # shellcheck source=../clusters/inventories/consumer-build/files/mirror-sources.sh
  . "$tree/clusters/inventories/consumer-build/files/mirror-sources.sh"
  REGISTRY="${registry%%/*}" OWNER="${registry#*/}"
  for arch in $RCLONE_ARCHITECTURES; do
    # The row is found by the parts of its upstream address, which only the table spells.
    row=$(LC_ALL=C awk -v pin="$RCLONE_PIN" -v name="rclone-$RCLONE_PIN-linux-$arch.deb" '
      $1 == "tool" { n = split($2, part, "/"); if (n == 9 && part[3] == "github.com" && part[4] == "rclone" && part[5] == "rclone" && part[6] == "releases" && part[7] == "download" && part[8] == pin && part[9] == name) { c++; url = $2; digest = $3 } }
      END { if (c == 1) print url " " digest; else exit 1 }' <(sed 's/#.*//' "$table")) \
      || { RCLONE_METADATA_ERROR="$table has not exactly one row of the rclone $RCLONE_PIN package for $arch"; return 1; }
    url="${row% *}" digest="${row#* }"
    line=$(mirror_source_line tool "$url" "$digest") || { RCLONE_METADATA_ERROR="the rclone $RCLONE_PIN row for $arch is refused: $line"; return 1; }
    read -r -a found <<< "$line"
    address="${found[${#found[@]} - 1]}"
    RCLONE_ROWS+="$arch $digest $address"$'\n'
  done
  RCLONE_ROWS="${RCLONE_ROWS%$'\n'}"
  RCLONE_METADATA="AW_RCLONE_PIN='$RCLONE_PIN'"$'\n'"AW_RCLONE_ROWS='$RCLONE_ROWS'"
}

carry_rclone_package() {
  local tree="$1" file="$2" digest arch row
  RCLONE_CARRIED_ARCH=''
  [ -f "$file" ] && [ -r "$file" ] && [ -s "$file" ] || { RCLONE_METADATA_ERROR="$file is not a readable, non-empty file"; return 1; }
  read_rclone_pin "$tree" || return 1
  # openssl and not sha256sum: macOS, an operator machine, carries the first and not the second.
  digest=$(openssl dgst -sha256 < "$file" 2>/dev/null) && digest="${digest##* }" && [[ "$digest" =~ ^[0-9a-f]{64}$ ]] \
    || { RCLONE_METADATA_ERROR="the sha256 of $file could not be computed on this machine with openssl dgst -sha256, so the file cannot be held to the digests of the platform table"; return 1; }
  while read -r arch row _; do
    [ "$row" = "$digest" ] && RCLONE_CARRIED_ARCH="$arch"
  done <<< "$RCLONE_ROWS"
  [ -n "$RCLONE_CARRIED_ARCH" ] \
    || { RCLONE_METADATA_ERROR="$file is not the rclone $RCLONE_PIN package of this release: its sha256 $digest is neither of the digests the platform table holds for it, so it is not sent"; return 1; }
}
