# OpenSASE appliance -- the whole SASE stack as NixOS module wiring.
#
# Replaces docker-compose.yml + the CentOS 7 Dockerfiles:
#   dnsmasq  -> services.dnsmasq
#   clamav   -> services.clamav (daemon, verdicts via clamd INSTREAM)
#   cicap    -> DROPPED (mitmproxy addon talks to clamd directly)
#   squid    -> replaced by services.opensase (mitmproxy decrypt/re-encrypt)
#   openvpn  -> services.openvpn (certs bootstrapped by `nix run .#vpn-init`)
{ config, lib, pkgs, ... }:

let
  cfg = config.services.opensase;

  addonSrc = pkgs.runCommand "opensase-addon" { } ''
    mkdir -p $out
    install -m 0644 ${./mitmproxy/opensase_addon.py} $out/opensase_addon.py
  '';

  mitmProxy = pkgs.python3Packages.mitmproxy;

  mitmArgs = lib.concatStringsSep " " [
    "--listen-host 0.0.0.0"
    "--set confdir=/var/lib/opensase/mitm"
    "--set block_global=false"
    "--set opensase_passlist=${cfg.policyPass}"
    "--set opensase_bumplist=${cfg.policyBump}"
    "--set opensase_log=${cfg.decisionLog}"
    "-s ${addonSrc}/opensase_addon.py"
  ];

  mitmInvocation =
    if cfg.mitmMode == "regular" then
      "${mitmProxy}/bin/mitmdump --listen-port ${toString cfg.listenPort} --showhost ${mitmArgs}"
    else
      "${mitmProxy}/bin/mitmdump --mode transparent --showhost ${mitmArgs}";
in
{
  options.services.opensase = {
    enable = lib.mkEnableOption "OpenSASE TLS inspection appliance";

    mitmMode = lib.mkOption {
      type = lib.types.enum [ "regular" "transparent" ];
      default = "regular";
      description = ''
        regular = explicit proxy on listenPort (v1 default).
        transparent = TPROXY intercept of 80/443 (requires the appliance
        to be the default gateway for clients).
      '';
    };

    listenPort = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Port mitmproxy listens on (regular mode).";
    };

    tproxyPort = lib.mkOption {
      type = lib.types.port;
      default = 3129;
      description = "Port mitmproxy binds in transparent mode.";
    };

    policyPass = lib.mkOption {
      type = lib.types.path;
      default = ./policy/pass.txt;
      description = "Domains spliced through (no decrypt), one per line.";
    };

    policyBump = lib.mkOption {
      type = lib.types.path;
      default = ./policy/bump.txt;
      description = "Domains always decrypted, one per line.";
    };

    decisionLog = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/opensase/log/decisions.jsonl";
      description = "JSONL log of every bump/splice/scan verdict.";
    };
  };

  config = lib.mkMerge [
    # Always-on basics (must exist whether or not the appliance is enabled).
    {
      system.stateVersion = "25.11";
      services.openssh.enable = true;
      environment.systemPackages = with pkgs; [ tcpdump ];
    }

    (lib.mkIf cfg.enable {
      # --- components -------------------------------------------------------
      services.clamav = {
        daemon.enable = true;
        updater.enable = true; # freshclam
        daemon.settings = {
          TCPSocket = "3310";
          TCPAddr = "127.0.0.1";
          MaxStreamMaxLength = "100M";
          MaxFileSize = "100M";
          MaxScanSize = "100M";
        };
      };

      services.dnsmasq = {
        enable = true;
        settings = {
          server = [ "1.1.1.1" "8.8.8.8" ];
          listen-address = [ "127.0.0.1" ];
        };
      };

      # OpenVPN server; certs live in /var/lib/opensase/openvpn, bootstrapped
      # by `nix run .#vpn-init`. Unit no-ops cleanly until server.conf exists.
      services.openvpn.servers.opensase.config = ''
        config /var/lib/opensase/openvpn/server.conf
      '';
      systemd.services."openvpn-opensase".serviceConfig.ConditionPathExists =
        "/var/lib/opensase/openvpn/server.conf";

      # --- mitmproxy --------------------------------------------------------
      users.users.opensase = {
        isSystemUser = true;
        group = "opensase";
      };
      users.groups.opensase = { };

      systemd.services.opensase-proxy = {
        description = "OpenSASE mitmproxy decrypt/re-encrypt on URL category";
        after = [ "clamav-daemon.service" "network-online.target" ];
        wants = [ "network-online.target" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          User = "opensase";
          StateDirectory = "opensase";
          ExecStart = mitmInvocation;
          Restart = "on-failure";
        };
        # Transparent mode: the mangle/fwmark/table-100 chain from the old
        # run.sh, now on the appliance kernel itself (works because this is
        # NixOS, not a Docker bridge).
        preStart = lib.mkIf (cfg.mitmMode == "transparent") ''
          ${pkgs.iptables}/bin/iptables -t mangle -N DIVERT 2>/dev/null || true
          ${pkgs.iptables}/bin/iptables -t mangle -F DIVERT
          ${pkgs.iptables}/bin/iptables -t mangle -A DIVERT -j MARK --set-mark 1
          ${pkgs.iptables}/bin/iptables -t mangle -A DIVERT -j ACCEPT
          ${pkgs.iptables}/bin/iptables -t mangle -A PREROUTING -p tcp -m socket -j DIVERT
          ${pkgs.iptables}/bin/iptables -t mangle -A PREROUTING -p tcp --dport 80  -j TPROXY --tproxy-mark 0x1/0x1 --on-port ${toString cfg.tproxyPort}
          ${pkgs.iptables}/bin/iptables -t mangle -A PREROUTING -p tcp --dport 443 -j TPROXY --tproxy-mark 0x1/0x1 --on-port ${toString cfg.tproxyPort}
          ${pkgs.iproute2}/bin/ip rule add fwmark 1 lookup 100 2>/dev/null || true
          ${pkgs.iproute2}/bin/ip route add local 0.0.0.0/0 dev lo table 100 2>/dev/null || true
        '';
      };

      networking.firewall = {
        allowedTCPPorts = lib.optionals (cfg.mitmMode == "regular") [ cfg.listenPort ];
        allowedUDPPorts = [ 5443 ]; # openvpn
      };

      boot.kernel.sysctl = lib.mkIf (cfg.mitmMode == "transparent") {
        "net.ipv4.ip_forward" = 1;
      };

      environment.systemPackages = with pkgs; [ mitmProxy clamav ];
    })
  ];
}
