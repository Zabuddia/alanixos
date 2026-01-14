{ inputs }:
{ hostname, system, features }:

let
  nixpkgs = inputs.nixpkgs;
  nixpkgs-unstable = inputs.nixpkgs-unstable;
  lib = nixpkgs.lib;
  
  pkgs-unstable = import nixpkgs-unstable {
    inherit system;
    config.allowUnfree = true;
  };

in
lib.nixosSystem {
  inherit system;

  specialArgs = { 
    inherit inputs hostname pkgs-unstable;
  };

  modules =
    (lib.optionals features.sops [ inputs.sops-nix.nixosModules.sops ])
    ++ (lib.optionals features.home-manager [ inputs.home-manager.nixosModules.home-manager ])
    ++ (lib.optionals features.nix-bitcoin [ inputs.nix-bitcoin.nixosModules.default ])
    ++ (lib.optionals features.disko [ inputs.disko.nixosModules.disko ])

    ++ [ ../hosts/${hostname}/default.nix ];
}