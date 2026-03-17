{ config, pkgs-unstable, ... }:

{
  imports = [
    ../base.nix
    ../network/ssh.nix
  ];

  users.mutableUsers = false;

  users.users.buddia = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" ];
    hashedPasswordFile = config.sops.secrets."password-hashes/buddia".path;
  };

  home-manager.useGlobalPkgs = true;
  home-manager.useUserPackages = true;
  home-manager.extraSpecialArgs = { inherit pkgs-unstable; };
  home-manager.users.buddia = import ../../home/buddia/workstation.nix;
}
