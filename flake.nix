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
        in
        {
          packages = {
            default = armVm; # host arch for linux users; darwin users use vm-arm on linux
            vm-x86_64 = x86Vm;
            vm-aarch64 = armVm;
          };

          apps = {
            # `nix run .#tofu -- plan` -- pinned OpenTofu for tofu/ provisioning.
            tofu = {
              type = "app";
              program = "${pkgs.opentofu}/bin/tofu";
            };

            # `nix run .#vm` -- boot the appliance in QEMU (needs KVM; on
            # macOS host, run `nix run .#vm-arm` on an ARM Linux host, or use
            # the OrbStack machine recipe in README).
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
                  export EASYRSA_SRC=${./openvpn/easyrsa3}
                  exec ${./nix/vpn-init.sh} "$@"
                '';
              })}/bin/opensase-vpn-init";
            };
          };

          devShells.default = pkgs.mkShell {
            packages = with pkgs; [ opentofu python3 python3Packages.mitmproxy ];
            shellHook = ''
              echo "OpenSASE dev shell: tofu (infra), mitmdump (addon dev), nixos-rebuild (appliance)"
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