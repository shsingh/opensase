# OpenSASE

Open, self-hosted **S**ecure **A**ccess **S**ervice **E**dge components built from OSS tools for testing — declared end-to-end with [Nix](https://nixos.org/).

OpenSASE is a TLS-inspection edge: clients connect over **OpenVPN**, traffic is decrypted and re-encrypted by **mitmproxy** based on a URL-category policy, every payload is scanned by **ClamAV**, and every verdict is written to a JSONL decision log. It runs two ways from one repo:

1. **Containers (no Nix needed)** — pull pre-built, Nix-built OCI images from GHCR and `docker compose up` on Linux, macOS, or Windows.
2. **Nix / NixOS (the appliance)** — the same stack as stock NixOS modules: boot it in QEMU, rebuild it on a real machine, or deploy with `nixos-rebuild --target-host`.

## Architecture

```mermaid
flowchart LR
    client["VPN client<br/>(any)"]
    subgraph edge["OpenSASE edge"]
        vpn["openvpn<br/>udp/5443"]
        mitm["mitmproxy<br/>tcp/8080 explicit · TPROXY 80/443 transparent<br/>splice or bump per URL category"]
        clam["clamav (clamd)<br/>tcp/3310 INSTREAM"]
        dns["dnsmasq<br/>udp+tcp/53"]
        log[("decision log<br/>decisions.jsonl")]
    end
    net((Internet))

    client -- "OpenVPN (TLS 1.2, tls-crypt)" --> vpn
    vpn --> dns
    vpn -- "HTTP/HTTPS" --> mitm
    mitm -- "clamd INSTREAM scan" --> clam
    mitm -- "Every verdict" --> log
    mitm -- "clean traffic" --> net
    mitm -- "INFECTED: blocked + logged" -.-> client
```

Verdict order: **passlist** (splice — no decrypt) → **bumplist** (decrypt + scan) → default bump. Every verdict — `splice`, `bump`, `clean`, `INFECTED` — lands in `/data/log/decisions.jsonl`. The cICAP layer of the original design was dropped: the mitmproxy addon talks to clamd directly over the INSTREAM protocol.

## Release artifacts

Everything is built with Nix — there are no Dockerfile builds in this repo. CI ([`.github/workflows/release-images.yml`](.github/workflows/release-images.yml)) builds each image with `dockerTools.buildLayeredImage` from the flake and pushes it to GHCR on every `v*` tag, with an SPDX SBOM per image:

- `ghcr.io/shsingh/opensase-dnsmasq` — DNS for VPN clients
- `ghcr.io/shsingh/opensase-clamav` — clamd scanner (DB bootstraps on first run, `SKIP_FRESHCLAM=1` to skip)
- `ghcr.io/shsingh/opensase-mitmproxy` — decrypt/re-encrypt core; addon + policy lists baked into the image
- `ghcr.io/shsingh/opensase-openvpn` — VPN server (config + certs supplied by you)

Byte-identical images build from the flake: `nix run .#load-images`.

## Quick start — Docker (no Nix required)

Any OCI runtime: Docker Desktop / Engine on **Linux, macOS, Windows**, or Podman.

```bash
git clone https://github.com/shsingh/opensase && cd opensase
docker compose -p opensase up -d
```

The OpenVPN server needs a PKI before it will start. Two options:

```bash
# Option A: with Nix on the machine (one-time CA bootstrap into ./state/openvpn)
nix run .#vpn-init

# Option B: container-only bootstrap
# use the openvpn container with EasyRSA mounted, or drop your own
# server.conf + PKI into the `openvpn_priv` volume
```

then copy `./state/openvpn/*` into the `openvpn_priv` volume and restart the `openvpn` service. Point a client at `udp/5443` and an explicit proxy at `<host>:8080`.

## Quick start — Nix / NixOS

Install [Nix](https://nixos.org/download) (any Linux distro, or NixOS), then:

```bash
git clone https://github.com/shsingh/opensase && cd opensase

# 1. Bootstrap the OpenVPN CA + certs (gitignored ./state)
nix run .#vpn-init

# 2a. Try it in a QEMU VM (Linux host):
nix build .#vm-x86_64 && ./result/bin/run-opensase-vm      # aarch64: .#vm-aarch64

# 2b. Or deploy the appliance to a real machine (from it, or with --target-host):
nixos-rebuild switch --flake .#opensase
nixos-rebuild switch --flake .#opensase --target-host root@<ip>

# 2c. Or run the container stack, images built locally:
nix run .#load-images && docker compose -p opensase up -d
```

NixOS users can also import `nix/appliance.nix` into an existing host config — the appliance composes from stock modules (`services.clamav`, `services.dnsmasq`, `services.openvpn`) plus the `services.opensase` module.

## Module options

```nix
services.opensase.enable = true;
services.opensase.mitmMode = "regular";   # or "transparent" (TPROXY 80/443)
services.opensase.listenPort = 8080;
services.opensase.policyPass = ./my/pass.txt;
services.opensase.policyBump  = ./my/bump.txt;
services.opensase.decisionLog = "/var/lib/opensase/log/decisions.jsonl";
```

## Policy

`nix/policy/pass.txt` — domains spliced through (never decrypted)
`nix/policy/bump.txt` — domains always decrypted and scanned

Both are `types.path` options, overridable at rebuild time; in the container images they are baked in per tag (rebuild the image or point compose at your own image to change policy).

## Client setup

### Windows
- Copy the generated `.ovpn` profile into OpenVPN's config directory and connect as Administrator (the tunnel needs it).
- Trust the mitmproxy CA: double-click the `.crt`, install for the **local user**, pick **Trusted Root Certification Authorities** (Chrome and Edge use this store; Firefox has its own under Settings → Certificates).

### macOS
- Import the profile into OpenVPN Connect (or tunnelblick), trust the mitmproxy CA into the System keychain.

### iOS
- OpenVPN Connect → import the `.ovpn`; CA: open the `.crt` from Files and trust it in the profile.

### Verify
After the tunnel is up:

```bash
ping <appliance>          # tunnel up
curl -x http://<appliance>:8080 https://example.com   # explicit-proxy path
```

Download a harmless [EICAR test file](https://www.eicar.org/download-anti-malware-testfile/) over HTTPS — you should see an `INFECTED` verdict in the decision log, not a local scanner alert.

## Security notes

- One process per container/image; the appliance runs services under dedicated non-root users.
- The VPN CA lives in its own volume — keep it safe.
- TLS 1.2, elliptic-curve certificates, DHE, tls-crypt.
- **Do not run this in production as-is** — it is a lab/testing appliance. Decide your own bump/splice policy carefully: TLS interception is a high-value target.

## Docs

Full documentation site (architecture, deployment paths, policy, CI): **https://shsingh.github.io/opensase/** — built with Quarto from `docs/`.

## Legacy Docker files

The original CentOS 7 Dockerfiles (`dnsmasq/`, `clamav/`, `cicap/`, `squid/`, `openvpn/`) are kept for archaeology only — nothing builds from them (the CentOS 7 mirrors are gone). The compose file now consumes the GHCR images above.

## Status

- [x] NixOS flake: appliance + QEMU VMs, `nix flake check --all-systems` clean
- [x] Nix-built OCI images for all four services + GHCR release workflow
- [x] Compose deployment for non-Nix users (Linux/macOS/Windows)
- [ ] Quarto docs site → GitHub Pages
- [ ] VM closure build + boot smoke test (CI, linux runner)
- [ ] Live verdict verification (EICAR over HTTPS)
- [ ] Tofu provider shapes (hcloud/aws)

## Credits

The initial build was inspired by [@sweitzel](https://github.com/sweitzel)'s [docker-vpnbox](https://github.com/sweitzel/docker-vpnbox) project.

## License

[GPL-3.0](LICENSE) (inherited from the original project).