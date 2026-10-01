{
  description = "OpenSASE -- SASE-style TLS inspection appliance (OpenVPN + mitmproxy + ClamAV + dnsmasq), NixOS flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs = inputs@{ flake-parts, nixpkgs, self, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];

      perSystem = { pkgs, system, ... }:
        let
          # VM runners (appliance + QEMU plumbing from nix/vm.nix).
          nixosFor = arch: module: nixpkgs.lib.nixosSystem {
            system = arch;
            modules = [
              module
              # QEMU-VM plumbing comes from the flake's own nixpkgs:
              # <nixpkgs/...> angle-bracket paths don't resolve in flakes.
              { imports = [ "${nixpkgs}/nixos/modules/virtualisation/qemu-vm.nix" ]; }
            ];
            specialArgs = { inherit nixpkgs; };
          };
          x86Vm = (nixosFor "x86_64-linux" ./nix/vm.nix).config.system.build.vm;
          armVm = (nixosFor "aarch64-linux" ./nix/vm.nix).config.system.build.vm;

          # OCI images built by Nix (release artifacts for non-Nix users;
          # pushed to GHCR by CI, loadable locally via `nix run .#load-images`).
          # Image derivations are linux-only (dnsmasq/iptables run on linux
          # inside the images); darwin systems just get no image outputs.
          imagePkgs = import ./nix/images.nix;
          imagesOut =
            if pkgs.stdenv.isLinux
            then (imagePkgs { inherit pkgs; }).packages
            else { };
        in
        {
          packages = {
            default = armVm; # host arch for linux users; darwin users use vm-arm on linux
            vm-x86_64 = x86Vm;
            vm-aarch64 = armVm;
          } // imagesOut;

          apps = {
            # `nix run .#vm` -- boot the appliance VM (needs KVM; on a
            # macOS/Nix-less host use the GHCR + compose path instead).
            vm = {
              type = "app";
              program = "${x86Vm}/bin/run-opensase-vm";
            };
            vm-arm = {
              type = "app";
              program = "${armVm}/bin/run-opensase-vm";
            };

            # `nix run .#vpn-init` -- bootstrap OpenVPN CA + server/client
            # certs into ./state/openvpn (then copy to /var/lib/opensase).
            vpn-init = {
              type = "app";
              program = "${(pkgs.writeShellApplication {
                name = "opensase-vpn-init";
                runtimeInputs = with pkgs; [ coreutils openssl ];
                text = ''
                  export EASYRSA_SRC=${./nix/easyrsa3}
                  exec ${./nix/vpn-init.sh} "$@"
                '';
              })}/bin/opensase-vpn-init";
            };

            # `nix run .#vpn-getclient -- <cn> [state-dir] [remote]` --
            # export a device profile (.ovpn) from the vpn-init PKI.
            vpn-getclient = {
              type = "app";
              program = "${(pkgs.writeShellApplication {
                name = "opensase-vpn-getclient";
                runtimeInputs = with pkgs; [ coreutils openssl ];
                text = ''
                  exec ${./nix/vpn-getclient.sh} "$@"
                '';
              })}/bin/opensase-vpn-getclient";
            };

            # `nix run .#k8s-manifests` -- render the Kubernetes base
            # manifests (k8s/manifests.cue) to k8s/manifests.yaml.
            k8s-manifests = {
              type = "app";
              program = "${(pkgs.writeShellApplication {
                name = "opensase-k8s-manifests";
                runtimeInputs = with pkgs; [ cue coreutils ];
                text = ''
                  cue export ./k8s -e list --out yaml > k8s/manifests.yaml
                  echo "opensase-k8s-manifests: wrote k8s/manifests.yaml"
                '';
              })}/bin/opensase-k8s-manifests";
            };

            # `nix run .#load-images` -- build all Nix-built OCI images and
            # `docker load` them locally (Linux host or CI; on darwin this
            # app exists but errors with a pointer to CI).
            load-images =
              let
                notLinux = "${pkgs.writeShellScript "load-images-linux-only" ''
                  echo "opensase: OCI image builds are linux-only; run on a Linux host or CI." >&2
                  exit 1
                ''}";
              in
              {
                type = "app";
                program =
                  if pkgs.stdenv.isLinux
                  then (imagePkgs { inherit pkgs; }).apps.load-images.program
                  else notLinux;
              };
          };

          devShells.default = pkgs.mkShell {
            packages = with pkgs; [ opentofu python3 python3Packages.mitmproxy cue ];
            shellHook = ''
              echo "OpenSASE dev shell: tofu (infra), mitmdump (addon dev), cue (k8s manifests), nixos-rebuild (appliance)"
            '';
          };
        };

      flake = {
        # Bare-metal / cloud targets (NixOS already installed or
        # nixos-rebuild --target-host). QEMU dev plumbing NOT included:
        # root is locked; real-disk layout assertions satisfied by
        # nix/host-layout.nix so the config is deployable and
        # `nix flake check`-clean.
        nixosConfigurations.opensase = nixpkgs.lib.nixosSystem {
          system = "aarch64-linux";
          modules = [ ./nix/appliance.nix ./nix/host-layout.nix ];
        };
        nixosConfigurations.opensase-x86_64 = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [ ./nix/appliance.nix ./nix/host-layout.nix ];
        };
      };
    };
}
