# BOOTSTRAP PLACEHOLDER
#
# This file deliberately uses partition labels so the flake can be evaluated
# before alan-home has been installed. Replace the entire file on alan-home
# before the first rebuild:
#
#   cp /etc/nixos/hardware-configuration.nix \
#     ~/.nixos/hosts/alan-home/hardware-configuration.nix
#
# The generated file contains this MacBook's real filesystem UUIDs and detected
# initrd modules. Do not deploy this placeholder unless the installed root and
# EFI partitions are actually labelled `nixos` and `boot`.
{ config, lib, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  boot.initrd.availableKernelModules = [
    "ahci"
    "ehci_pci"
    "sd_mod"
    "sdhci_pci"
    "usb_storage"
    "xhci_pci"
  ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];

  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-label/boot";
    fsType = "vfat";
    options = [ "fmask=0077" "dmask=0077" ];
  };

  swapDevices = [ ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
