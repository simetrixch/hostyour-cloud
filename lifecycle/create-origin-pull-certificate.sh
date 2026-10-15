#!/usr/bin/env bash
# =============================================================================
# create-origin-pull-certificate.sh — make the client certificate Cloudflare
# presents to the installation's origins, and the CA the origins verify it by,
# and write the three answers into the config.
# =============================================================================
#
# USAGE (run from anywhere)
#   bash lifecycle/create-origin-pull-certificate.sh <config>
#
# THE ONE INPUT
#   config — the installation's own key=value file, the one install-machine.sh
#            is given and in the same grammar. Read and never run. Three answers
#            are written into it in place:
#              CLOUDFLARE_ORIGIN_PULL_CA           the CA certificate, public
#              CLOUDFLARE_ORIGIN_PULL_CERTIFICATE  the client certificate
#              CLOUDFLARE_ORIGIN_PULL_PRIVATE_KEY  its private key
#            each PEM on one line with \n for each line break, as
#            GITHUB_APP_PRIVATE_KEY stands there.
#
# WHERE EACH ONE GOES. The CA reaches every cluster through the secret store
# (regenerate-install-branch.sh and the redeploy of the master seed it into
# <stage>/app/cloudflare-origin-pull), where TLSOption cloudflare-origin-pull
# verifies against it. The client certificate and its key go to Cloudflare alone,
# through apply-cloudflare-zone-security.sh, and stay in this config.
#
# THE CA KEY IS NEVER WRITTEN. It signs the one client certificate in a
# temporary directory nobody but the owner can reach, removed on every path this
# can end on, so nobody can sign a second client certificate the origins accept.
#
# A ROTATION IS THIS RUN AGAIN. It makes a new CA and a new client certificate,
# and CLOUDFLARE_ORIGIN_PULL_CA then holds the newest CA it held before and the
# new one, so the origins accept both client certificates while Cloudflare moves
# from one to the other; the run after that drops the older CA, and with it the
# old client certificate. The order a rotation takes is printed at the end.
# =============================================================================

set -uo pipefail

die() { printf 'create-origin-pull-certificate: %s\n' "$1" >&2; exit "${2:-65}"; }
say() { printf '%s\n' "$1"; }

CONFIG="${1:-}"
[ $# -le 1 ] || die "lifecycle/create-origin-pull-certificate.sh was given more than it takes: $2" 64
[ -n "$CONFIG" ] || die 'usage: lifecycle/create-origin-pull-certificate.sh <config>' 64

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v openssl >/dev/null 2>&1 \
  || die 'openssl is not on this path, and this act is openssl making a CA and the certificate it signs'
# shellcheck disable=SC1091
. "$HERE/require-owner-only.sh" \
  || die 'require-owner-only.sh is not beside this file. It is the guard every launcher puts on a config' 66
[ -r "$CONFIG" ] \
  || die "there is no config at $CONFIG. It is the installation's own, the one install-machine is given: name it as the first argument" 66
# Asked before anything is made, because the private key lands in that file.
require_owner_only "$CONFIG" \
  || die "$CONFIG $REACH, and the private key of the origin pull certificate would land in it. Make it owner-only with: $OWNER_ONLY_COMMAND. Nothing has been changed" 65

# THE VALUE OF ONE KEY of the config, READ AND NEVER EXECUTED.
config_value() { # KEY -> the value of the KEY='value' line, or nothing
  local key="$1" line
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in
      "$key="\'*) line="${line#"$key="\'}"; printf '%s\n' "${line%%\'*}"; return 0 ;;
    esac
  done < "$CONFIG"
  return 1
}
# THE LINE IS REPLACED WHERE IT STANDS AND APPENDED ONLY WHERE THE FILE HAS NONE,
# and the file is truncated where it stands rather than replaced by a copy, which
# would carry the copy's access list.
write_config_value() { # KEY, value -> KEY='value' rewritten in place, appended when absent
  local key="$1" value="$2" line i found=0
  local -a lines=()
  while IFS= read -r line || [ -n "$line" ]; do lines+=("$line"); done < "$CONFIG"
  for ((i = 0; i < ${#lines[@]}; i++)); do
    case "${lines[$i]}" in
      "$key="*) lines[$i]="$key='$value'"; found=1; break ;;
    esac
  done
  [ "$found" = '1' ] || lines+=("$key='$value'")
  : > "$CONFIG"
  for line in "${lines[@]}"; do printf '%s\n' "$line" >> "$CONFIG"; done
}
one_line() { # a PEM file -> its text on one line, \n for each line break
  local line text=''
  while IFS= read -r line || [ -n "$line" ]; do text="$text$line\\n"; done < "$1"
  printf '%s' "$text"
}

# The newest CA the config holds is kept beside the new one: the last block of
# the standing value, because each run appends its CA at the end.
STANDING="$(config_value CLOUDFLARE_ORIGIN_PULL_CA)"
KEPT=''
case "$STANDING" in
  *'-----BEGIN CERTIFICATE-----'*) KEPT="-----BEGIN CERTIFICATE-----${STANDING##*-----BEGIN CERTIFICATE-----}" ;;
esac
NAME="$(config_value FQDN)"
NAME="${NAME:-this installation}"

WORK="$(mktemp -d)" || die 'no temporary directory could be made for the CA key'
chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT TERM

# Two years for both: the CA key is gone after this run, so the CA signs nothing
# after its one certificate, and Cloudflare warns before the certificate expires.
DAYS=730
STAMP="$(date -u +%Y%m%d%H%M%S)"
printf '%s\n' '[req]' 'distinguished_name = dn' '[dn]' '[ca]' 'basicConstraints = critical, CA:TRUE, pathlen:0' 'keyUsage = critical, keyCertSign, cRLSign' \
  'subjectKeyIdentifier = hash' \
  '[client]' 'basicConstraints = critical, CA:FALSE' 'keyUsage = critical, digitalSignature, keyEncipherment' \
  'extendedKeyUsage = clientAuth' 'subjectKeyIdentifier = hash' 'authorityKeyIdentifier = keyid' > "$WORK/openssl.cnf"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$WORK/ca.key" -out "$WORK/ca.pem" -days "$DAYS" \
    -subj "/CN=$NAME origin pull CA $STAMP" -extensions ca -config "$WORK/openssl.cnf" >/dev/null 2>&1 \
  && openssl req -newkey rsa:2048 -nodes -keyout "$WORK/client.key" -out "$WORK/client.csr" -subj "/CN=$NAME origin pull $STAMP" -config "$WORK/openssl.cnf" >/dev/null 2>&1 \
  && openssl x509 -req -in "$WORK/client.csr" -CA "$WORK/ca.pem" -CAkey "$WORK/ca.key" -set_serial "0x$(openssl rand -hex 16)" \
    -days "$DAYS" -extfile "$WORK/openssl.cnf" -extensions client -out "$WORK/client.pem" >/dev/null 2>&1 \
  && openssl verify -CAfile "$WORK/ca.pem" "$WORK/client.pem" >/dev/null 2>&1 \
  || die 'openssl could not make the CA and the client certificate it signs. Nothing has been changed' 70

CA_LINE="$(one_line "$WORK/ca.pem")"
[ -z "$KEPT" ] || CA_LINE="$KEPT$CA_LINE"
write_config_value CLOUDFLARE_ORIGIN_PULL_CA "$CA_LINE"
write_config_value CLOUDFLARE_ORIGIN_PULL_CERTIFICATE "$(one_line "$WORK/client.pem")"
write_config_value CLOUDFLARE_ORIGIN_PULL_PRIVATE_KEY "$(one_line "$WORK/client.key")"

say "create-origin-pull-certificate: $CONFIG now carries CLOUDFLARE_ORIGIN_PULL_CA, CLOUDFLARE_ORIGIN_PULL_CERTIFICATE and CLOUDFLARE_ORIGIN_PULL_PRIVATE_KEY."
say "create-origin-pull-certificate: the client certificate $(openssl x509 -in "$WORK/client.pem" -noout -subject) is valid $(openssl x509 -in "$WORK/client.pem" -noout -enddate)."
if [ -n "$KEPT" ]; then
  say 'create-origin-pull-certificate: CLOUDFLARE_ORIGIN_PULL_CA holds the CA it held before and the new one, so both client certificates pass until the next run.'
else
  say 'create-origin-pull-certificate: CLOUDFLARE_ORIGIN_PULL_CA holds the new CA alone.'
fi
say 'create-origin-pull-certificate: the CA key is not kept. In this order:'
say '  1. regenerate-install-branch.sh and the redeploy of the master seed the CA into the secret store;'
say '  2. every cluster reads ExternalSecret ingress/cloudflare-origin-pull-ca again;'
say '  3. apply-cloudflare-zone-security.sh uploads the client certificate to every zone.'
