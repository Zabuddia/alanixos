{ config, ... }:
{
  users.mutableUsers = false;

  users.users.buddia = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" ];
    hashedPasswordFile = config.sops.secrets."password-hashes/buddia".path;
  };

  home-manager.useGlobalPkgs = true;
  home-manager.useUserPackages = true;
  
  home-manager.users.buddia = import ../../home/buddia;
}