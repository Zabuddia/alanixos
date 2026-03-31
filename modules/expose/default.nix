{ lib, pkgs }:
{
  tailscale = import ./tailscale.nix { inherit lib pkgs; };
  tor = import ./tor.nix { inherit lib pkgs; };
  wireguard = import ./wireguard.nix { inherit lib pkgs; };
  wan = import ./wan.nix { inherit lib pkgs; };
}
