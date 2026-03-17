{ inputs }:
{ hostname, system, features }:

let
  nixpkgs = inputs.nixpkgs;
  nixpkgs-unstable = inputs.nixpkgs-unstable;
  lib = nixpkgs.lib;

  nixpkgsConfig = { allowUnfree = true; };

  pkgs-unstable = import nixpkgs-unstable {
    inherit system;
    config = nixpkgsConfig;
  };

in
lib.nixosSystem {
  inherit system;

  specialArgs = {
    inherit inputs hostname pkgs-unstable;
    allHosts = inputs.self.nixosConfigurations;
  };

  modules =
    (lib.optionals features.sops [ inputs.sops-nix.nixosModules.sops ])
    ++ (lib.optionals features.home-manager [ inputs.home-manager.nixosModules.home-manager ])
    ++ (lib.optionals features.nix-bitcoin [ inputs.nix-bitcoin.nixosModules.default ])
    ++ (lib.optionals features.nix-openclaw [ inputs.nix-openclaw.nixosModules.openclaw-gateway ])
    ++ (lib.optionals features.disko [ inputs.disko.nixosModules.disko ])

    ++ [ ../hosts/${hostname}/default.nix ];
}
