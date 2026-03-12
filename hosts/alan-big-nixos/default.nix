{ hostname, ... }:
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/cluster/default.nix
    ../../modules/tailscale.nix
    ../../modules/bitcoin.nix
  ];

  networking.hostName = hostname;
}
