#!/usr/bin/env bash
# OpenSASE -- export an OpenVPN client profile (.ovpn) for a device CN.
# Declarative replacement for the legacy openvpn/bin/ovpn_getclient.sh:
# no chown/sudo games, no hardcoded service user; works against any
# vpn-init-generated PKI (./state/openvpn by default).
#
# Usage: nix run .#vpn-getclient -- <cn> [pki-dir] [remote-host[:port]]
set -euo pipefail

CN="${1:?usage: vpn-getclient <cn> [state-dir] [remote]}"
STATE="${2:-./state/openvpn}"
REMOTE="${3:-}"
[ -n "$REMOTE" ] || REMOTE="${OVPN_REMOTE:- udp://127.0.0.1:5443}"

PKI="$STATE/pki"
EASYRSA="$STATE/easyrsa"

for f in "$PKI/issued/$CN.crt" "$PKI/private/$CN.key"; do
  if [ -e "$f" ]; then
    echo "ERROR: CN=$CN already exists ($f). Use a new CN (one profile per"
    echo "device) or remove the old material and CRL entry first."
    exit 1
  fi
done

cd "$EASYRSA"
./easyrsa --batch build-client-full "$CN" nopass

CA=$(cat "$PKI/ca.crt")
CERT=$(openssl x509 -in "$PKI/issued/$CN.crt")
KEY=$(cat "$PKI/private/$CN.key")
TAC=$(cat "$PKI/tc.key")

dt=$(date +"%F %H:%M:%S")
cat <<EOT
###############################################
# OpenSASE client profile - generated $dt
# device CN: $CN
client
nobind
dev tun
remote-cert-tls server
persist-key
persist-tun
tls-version-min 1.2
auth SHA256
<ca>
$CA
</ca>
<cert>
$CERT
</cert>
<key>
$KEY
</key>
<tls-auth>
$TAC
</tls-auth>
key-direction 1
remote ${REMOTE#*://}
EOT
