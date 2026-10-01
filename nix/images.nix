# OpenSASE container images, built by Nix -- no Dockerfiles, no floating FROM.
#
# Every image is a hash-pinned derivation from the same nixpkgs the appliance
# uses, so `nix build .#image-mitmproxy` on CI and on your machine produce
# byte-identical layers. These are the release artifacts pushed to GHCR by
# .github/workflows/release.yml for non-Nix users on Linux/macOS/Windows
# (Docker, Podman, containerd -- anything that runs OCI images).
{ pkgs }:
    let
      mitmEnv = pkgs.python3.withPackages (ps: [ ps.mitmproxy ]);

      # Shared image constructor: hash-pinned layers, explicit config.
      mkImage =
        { name, contents, config }:
        pkgs.dockerTools.buildLayeredImage {
          inherit name contents config;
          tag = "latest";
          maxLayers = 60;
        };
    in
    {
      packages = {
        # dnsmasq: DNS for VPN clients
        image-dnsmasq = mkImage {
          name = "opensase-dnsmasq";
          contents = [
            pkgs.dnsmasq
            # minimal /etc/passwd + /etc/group: dnsmasq drops privileges to
            # "nobody" when started as root; a bare buildLayeredImage ships
            # neither file
            (pkgs.writeTextDir "etc/passwd" ''
              root:x:0:0:root:/root:/bin/sh
              nobody:x:65534:65534:nobody:/var/empty:/bin/sh
            '')
            (pkgs.writeTextDir "etc/group" ''
              root:x:0:
              nobody:x:65534:
            '')
            # pidfile dir + empty resolv fallback (runtime dirs vanish with
            # tmpfs; dnsmasq exits 3 without a writable /var/run)
            (pkgs.runCommand "opensase-dnsmasq-dirs" { } ''
              mkdir -p $out/var/run $out/var/lib/misc $out/etc
              printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' \
                > $out/etc/resolv.conf
            '')
          ];
          config = {
            Entrypoint = [ "${pkgs.dnsmasq}/bin/dnsmasq" "--keep-in-foreground" ];
            ExposedPorts = { "53/tcp" = { }; "53/udp" = { }; };
          };
        };

        # clamav: clamd scanner (verdicts on 3310)
        image-clamav = mkImage {
          name = "opensase-clamav";
          contents = [
            pkgs.clamav
            pkgs.coreutils # entry script uses `install`
            pkgs.dockerTools.caCertificates
            # bare buildLayeredImage has no /etc/passwd and no /tmp; clamd
            # needs both (User root lookup, LogFile /tmp/clamd.log, pid dir)
            (pkgs.writeTextDir "etc/passwd" ''
              root:x:0:0:root:/root:/bin/sh
              clamav:x:900:900:clamav:/var/empty:/bin/sh
              clamupdate:x:901:901:clamupdate:/var/empty:/bin/sh
            '')
            (pkgs.writeTextDir "etc/group" ''
              root:x:0:
              clamav:x:900:
              clamupdate:x:901:
            '')
          ];
          config = {
            # bootstrap DB on first run, then serve 3310
            Entrypoint = [
              "${pkgs.writeShellScript "clamav-entry" ''
                install -d -m 0755 /var/lib/clamav /tmp /var/run/clamav
                if [ ! -e /var/lib/clamav/daily.cvd ] && [ -z "''${SKIP_FRESHCLAM:-}" ]; then
                  ${pkgs.clamav}/bin/freshclam --datadir=/var/lib/clamav \
                    --config-file=${./freshclam.conf} || \
                    echo "WARN: freshclam failed; starting clamd anyway"
                fi
                exec ${pkgs.clamav}/bin/clamd --config-file=${./clamd.conf}
              ''}"
            ];
            ExposedPorts = { "3310/tcp" = { }; };
            Volumes = { "/var/lib/clamav" = { }; };
          };
        };

        # mitmproxy: decrypt/re-encrypt on URL category + clamd INSTREAM scan.
        # Addon + policy lists are store paths baked into the image.
        image-mitmproxy = mkImage {
          name = "opensase-mitmproxy";
          contents = [
            mitmEnv
            pkgs.dockerTools.caCertificates
          ];
          config = {
            Entrypoint = [
              "${pkgs.writeShellScript "mitm-entry" ''
                exec ${mitmEnv}/bin/mitmdump \
                  --listen-host 0.0.0.0 --listen-port 8080 --showhost \
                  --set confdir=/data/mitm \
                  --set block_global=false \
                  --set opensase_passlist=${./policy/pass.txt} \
                  --set opensase_bumplist=${./policy/bump.txt} \
                  --set opensase_log=/data/log/decisions.jsonl \
                  -s ${./mitmproxy/opensase_addon.py}
              ''}"
            ];
            ExposedPorts = { "8080/tcp" = { }; };
            Volumes = { "/data" = { }; };
          };
        };

        # openvpn: VPN server; config + certs from the openvpn-priv volume.
        # Bootstrap: `nix run .#vpn-init` writes ./state/openvpn, compose
        # mounts that directory here as /data-priv.
        image-openvpn = mkImage {
          name = "opensase-openvpn";
          contents = [
            pkgs.openvpn
            pkgs.iptables
            pkgs.coreutils
            pkgs.bash
            pkgs.dockerTools.caCertificates
          ];
          config = {
            Entrypoint = [
              "${pkgs.writeShellScript "openvpn-entry" ''
                exec ${pkgs.openvpn}/bin/openvpn --config /data-priv/server.conf
              ''}"
            ];
            CapAdd = [ "NET_ADMIN" ];
            ExposedPorts = { "5443/udp" = { }; };
            Volumes = {
              "/data-priv" = { };
              "/data" = { };
            };
          };
        };
      };

      # `nix run .#load-images` -- build all four images and load them into
      # the local docker daemon (Linux host with docker, or CI).
      apps.load-images =
        let
          loader = pkgs.writeShellApplication {
            name = "opensase-load-images";
            runtimeInputs = with pkgs; [ coreutils ];
            text = ''
              set -euo pipefail
              for img in dnsmasq clamav mitmproxy openvpn; do
                echo ">> building opensase-''${img}"
                nix build ".#image-''${img}" --out-link "result-''${img}"
                if command -v docker >/dev/null 2>&1; then
                  docker load < "result-''${img}"
                  docker tag "opensase-''${img}:latest" "ghcr.io/shsingh/opensase-''${img}:latest"
                else
                  echo "   (no docker on PATH; OCI image tarball left at result-''${img})"
                fi
              done
            '';
          };
        in
        {
          type = "app";
          program = "${loader}/bin/opensase-load-images";
        };
}
