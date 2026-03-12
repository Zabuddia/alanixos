{ hostname, ... }:
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/cluster/default.nix
    ../../modules/tailscale.nix
  ];

  networking.hostName = hostname;
}
