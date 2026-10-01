# Troubleshooting

Debug systematically in stage order: most edge problems reduce to one of five
broken links — **tunnel, DNS, HTTP flow, inspection verdicts, or malware
scanning.** Execute the stages in order; later stages assume the earlier
ones. Every check is runnable against the compose deployment or the NixOS
appliance (differences noted).

## 0. Read the state of the world first

```bash
# compose deployment
docker compose -p opensase ps
docker compose -p opensase logs --tail=50 openvpn dnsmasq mitmproxy clamav

# NixOS appliance
systemctl status openvpn-opensase dnsmasq mitmproxy clamav
journalctl -u openvpn-opensase -n 100 --no-pager
```

Healthy baseline: all containers `Up` (compose) / units `active (running)`
(appliance); the decision log is appended on every request:

```bash
docker compose -p opensase exec mitmproxy tail -5 /data/log/decisions.jsonl
# appliance:
tail -5 /var/lib/opensase/log/decisions.jsonl
```

If the log is quiet while a client browses, you are debugging the traffic
path — start at stage 3.

## 1. Tunnel — is the VPN session up?

**Symptom ladder:** client connects but nothing loads → check the server
side first.

```bash
# server: connected clients + per-client bytes
docker compose -p opensase logs --tail=100 openvpn | grep -E "PEER|VERIFY|Initialization"
# appliance:
journalctl -u openvpn-opensase | grep -E "PEER|VERIFY OK"

# is the port even reachable? (from OUTSIDE the appliance host)
sudo tcpdump -ni any udp port 5443 -c 20
# Wireshark equivalent, with a display filter:
#   tshark -i any -f "udp port 5443" -Y "openvpn"
```

- **No packets at all** → routing/firewall before the edge (port-forward on
  the home router, host firewall, NAT hairpin). On the appliance check
  `firewall` rules allow udp/5443.
- **Packets arrive, no reply** → server-side init problem; read the full
  openvpn log block below (stage "control channel").
- **Client authenticates, then dies** → usually cert/key mismatch — see the
  HMAC errors section below.

### The HMAC / tls-auth error family (issue #3)

```
TLS Error: cannot locate HMAC in incoming packet
Authenticate/Decrypt packet error: packet HMAC authentication failed
```

Cause: the client profile's static key (`<tls-auth>` block) or certs don't
match the server's current PKI — the client kept a profile generated before
a server-side renewal/re-init. Fix: re-export the client profile
(`nix run .#vpn-getclient -- <new-cn>` — see [Troubleshooting](https://shsingh.github.io/opensase/docs/troubleshooting.html))
and re-import on
the device. The CN-reuse guard means you may need a fresh CN; see issue #11
for the renewal-workflow work that automates this.

### Clock skew

TLS handshakes fail with `certificate is not yet valid` / `notAfter`-style
verify errors when device clocks drift. Check both ends (`date`) — IoT and
freshly-installed devices are the usual suspects.

## 2. DNS — do names resolve inside the tunnel?

From a **connected client**:

```bash
# dnsmasq lives at the edge's DNS IP; via the tunnel:
dig @192.168.50.2 example.com +short      # compose network subnet
drill example.com @192.168.50.2           # alternative resolver tool
nslookup example.com 192.168.50.2         # Windows/macOS fallback
```

Then confirm the appliance itself resolves upstream:

```bash
docker compose -p opensase exec dnsmasq getent hosts example.com
# appliance:
resolvectl query example.com
```

- Client `dig` times out but appliance resolves → dnsmasq exposure/IP config
  on the VPN subnet (compose network `192.168.50.0/24`, dnsmasq `.2`).
- Both fail → upstream DNS path from the appliance (host egress, or dnsmasq
  upstream config).
- **HTTP fails but only by hostname** → this stage; everything below assumes
  names resolve.

## 3. HTTP flow — does traffic reach the proxy?

The addon runs as explicit proxy `:8080` and transparent for intercepted
80/443. Test both paths explicitly from a client:

```bash
# explicit proxy path (bypasses iptables entirely):
curl -x http://<edge-ip>:8080 https://example.com -v

# direct (transparent/TPROXY path):
curl https://example.com -v
```

- **Explicit works, transparent doesn't** → interception plumbing: the
  mangle/fwmark rules in `ovpn_run.sh` (container) or the NixOS module's
  traffic-shaping config. Verify the rules exist:

```bash
docker compose -p opensase exec openvpn iptables -t mangle -S | grep -i mark
```

- **Both fail** → mitmproxy process or upstream egress; watch it live:

```bash
docker compose -p opensase logs -f mitmproxy
# packet-level truth:
docker compose -p opensase exec openvpn tcpdump -ni any tcp port 443 -c 20
```

## 4. Verdicts — is the policy engine doing what the lists say?

The decision order is **passlist → bumplist → default bump**, and every
request writes a line. Test a host in each bucket:

```bash
# watch while you browse:
docker compose -p opensase exec mitmproxy tail -f /data/log/decisions.jsonl
#   or jq-filtered, live:
docker compose -p opensase exec mitmproxy sh -c 'tail -f /data/log/decisions.jsonl | jq -c .'
```

| Log shows | Meaning | Next step |
|---|---|---|
| `action: splice` for a listed-pass host | intended | — |
| `action: bump` + `verdict: clean` | decrypted + forwarded | — |
| `action: bump` + `verdict: INFECTED` | blocked by ClamAV | confirm expected |
| nothing for the host | traffic didn't reach the addon | back to stage 3 |
| `bump` when you expected `splice` | category lists changed | check `nix/policy/*.txt` |

Certificate trust errors **in the browser only** (`NET::ERR_CERT_AUTHORITY_INVALID`
and friends) are usually the appliance CA not installed on that device —
that's the bump path working as designed. Install the CA (see Clients page)
or add the host to the passlist to splice instead. On iOS note the
"trust profile in two places" step (install + enable).

## 5. Scanning — is clamd healthy?

```bash
docker compose -p opensase logs --tail=50 clamav
# first-run DB bootstrap takes a while; SKIP_FRESHCLAM=1 skips it

# end-to-end scanner test with the EICAR test string (harmless, industry-standard):
printf 'X5O!P%%@AP[4\\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*' > /tmp/eicar.txt
docker compose -p opensase cp /tmp/eicar.txt clamav:/tmp/eicar.txt
docker compose -p opensase exec clamav clamdscan --fdpass /tmp/eicar.txt
```

Then the bump-path end to end: fetch the EICAR test URL **from a client
through the edge**; expect the connection blocked and the log to show
`verdict: INFECTED`.

- clamd restarts / OOM → DB size vs RAM; check `docker stats`.
- `INSTREAM size limit exceeded` → payload larger than clamd's configured
  `StreamMaxLength`; adjust clamd.conf (or let it block — that's policy).

## 6. Known current limitations (read before filing)

- **GHCR `pull` fails with `not found`** → expected until #7 (v0.1.0) ships
  the first published images; build locally with `nix run .#load-images` or
  track #7.
- OpenVPN Connect (iOS) forces `tls-auth` (not `tls-crypt`) — tracked as #12.
- IPv6 and QUIC/UDP-443 are not intercepted yet (#13, #22): dual-stack
  clients can bypass inspection on these paths until those land. QUIC fail-
  closed mitigation: block udp/443 at the edge.
- Certificate renewal has no automation yet (#11) — manual easy-rsa steps,
  client-profile re-export required (see the HMAC section above).

## Toolbox summary

| Tool | Use for |
|---|---|
| `docker compose logs` / `journalctl` | first look, always |
| `tail -f decisions.jsonl` (`jq` optional) | what the policy engine actually decided |
| `tcpdump -ni any udp port 5443` | tunnel reachability, outside the appliance |
| `tshark -Y "openvpn || tls"` | handshake-level analysis (SNI visibility in ClientHello) |
| `dig/drill @192.168.50.2` | DNS path inside the tunnel |
| `curl -x http://<edge>:8080` vs bare `curl` | explicit-vs-transparent path isolation |
| `openssl s_client -connect host:443 -servername host` | which cert the edge serves (appliance CA = bump happened) |
| `clamdscan` + EICAR | scanner health end-to-end |
| `docker stats` | RAM/CPU per container (clamd DB growth) |
