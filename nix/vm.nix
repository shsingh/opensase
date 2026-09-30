# QEMU VM variant of the appliance (local dev only: root gets a throwaway
# initial password). Real deployments use nixosConfigurations.opensase{,-x86_64}
# with nix/host-layout.nix (locked root, same assertions satisfied there).
{ lib, ... }:

{
  imports = [ ./appliance.nix ];

  services.opensase.enable = true; # regular mode by default

  users.mutableUsers = false;
  users.users.root.initialPassword = "opensase"; # local dev VM only

  # qemu-vm.nix supplies most of these; set the bootability assertions
  # explicitly (required when the module is imported manually).
  boot.loader.grub.enable = false;
  boot.loader.systemd-boot.enable = lib.mkForce false;
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
    autoFormat = true;
  };

  virtualisation = {
    memorySize = 2048;
    diskSize = 8 * 1024;
    forwardPorts = [
      { from = "host"; host.port = 2222; guest.port = 22; }
      { from = "host"; host.port = 8080; guest.port = 8080; }
      { from = "host"; host.port = 15443; guest.port = 5443; }
    ];
  };
}