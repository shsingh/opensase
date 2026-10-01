#!/usr/bin/env bash
# OpenSASE -- bootstrap the OpenVPN CA + server/client certificates.
# Uses the repo's EasyRSA 3 copy (nix/easyrsa3); generated material lands in
# ./state/openvpn (gitignored). Idempotent: skips when PKI exists.
set -euo pipefail

: "${EASYRSA_SRC:?not set by wrapper}"

DEST="${1:-./state/openvpn}"

if [ -e "$DEST/pki/issued/server.crt" ]; then
  echo "opensase-vpn-init: $DEST/pki already bootstrapped -- nothing to do"
  exit 0
fi

mkdir -p "$DEST"
export EASYRSA="$DEST/easyrsa"
export EASYRSA_PKI="$DEST/pki"

rm -rf "$EASYRSA"
cp -r "$EASYRSA_SRC" "$EASYRSA"
chmod -R u+w "$EASYRSA"

cd "$EASYRSA"
./easyrsa --batch init-pki
./easyrsa --batch --req-cn "OpenSASE CA" build-ca nopass
./easyrsa --batch gen-dh
./easyrsa --batch build-server-full server nopass
./easyrsa --batch build-client-full client01 nopass
./easyrsa --batch gen-crl

# tls-auth static key: embedded in client profiles; referenced by the
# appliance server config. (tls-crypt is tracked in issue #12.)
openssl rand 256 > "$EASYRSA_PKI/tc.key"

# Server config consumed by the appliance unit and by compose
# (openvpn_priv volume).
cat > "$DEST/server.conf" <<EOF
port 5443
proto udp
dev tun
ca pki/ca.crt
cert pki/issued/server.crt
key pki/private/server.key
dh pki/dh.pem
crl-verify pki/crl.pem
tls-auth pki/tc.key 0
key-direction 0
server 10.128.81.0 255.255.255.0
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 192.168.50.2"
keepalive 10 60
persist-key
persist-tun
user nobody
group nobody
status /var/lib/opensase/openvpn/status.log
verb 4
EOF

echo "opensase-vpn-init: OK"
echo "  server config: $DEST/server.conf"
echo "  client cert:   $DEST/pki/issued/client01.crt"
echo "  next: export a device profile with \`nix run .#vpn-getclient -- <cn>\`"
