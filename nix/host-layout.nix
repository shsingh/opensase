# Bootable layout for the deployable appliance targets
# (nixosConfigurations.opensase{,-x86_64}): real-disk bootloader + root FS.
# The QEMU VM targets satisfy the same assertions via autoFormat disk.
{ config, lib, ... }:

{
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };
  boot.loader.grub = {
    enable = true;
    device = lib.mkDefault "/dev/vda";
  };
  boot.loader.systemd-boot.enable = lib.mkForce false;

  swapDevices = lib.mkDefault [ ];
}