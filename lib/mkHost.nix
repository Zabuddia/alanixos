{ inputs, clusterConfig }:
{ hostname, system, enableBitcoin ? false }:

let
  nixpkgs = inputs.nixpkgs;
  lib = nixpkgs.lib;

  pkgs-unstable = import inputs.nixpkgs-unstable {
    inherit system;
    config.allowUnfree = true;
  };
in
lib.nixosSystem {
  inherit system;

  specialArgs = {
    inherit inputs clusterConfig hostname pkgs-unstable;
  };

  modules =
    [
      inputs.sops-nix.nixosModules.sops
      inputs.home-manager.nixosModules.home-manager
      ../hosts/${hostname}/default.nix
    ]
    ++ lib.optionals enableBitcoin [
      inputs.nix-bitcoin.nixosModules.default
    ];
}
