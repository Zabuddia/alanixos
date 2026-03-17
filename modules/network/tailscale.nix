{ pkgs-unstable, ... }:
{
  services.tailscale = {
    enable = true;
    package = pkgs-unstable.tailscale;
    extraUpFlags = [ "--accept-routes" ];
  };
}