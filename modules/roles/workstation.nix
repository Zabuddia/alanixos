{ config, ... }:

{
  imports = [
    ../base.nix
    ../network/ssh.nix
    ../network/tailscale.nix
    ../network/ddns.nix
  ];

  alanix.desktop.enable = true;

  users.mutableUsers = false;

  users.users.buddia = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" ];
    hashedPasswordFile = config.sops.secrets."password-hashes/buddia".path;
  };

  home-manager.useGlobalPkgs = true;
  home-manager.useUserPackages = true;
  home-manager.users.buddia = import ../../home/buddia/workstation.nix;
}
