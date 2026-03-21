{ inputs }:
{ hostname }:

let
  host = import ../hosts/${hostname}/default.nix { inherit inputs hostname; };
  system = host.system;
  nixpkgs = inputs.nixpkgs;
  lib = nixpkgs.lib;
in
lib.nixosSystem {
  inherit system;

  specialArgs = {
    inherit inputs hostname;
    allHosts = inputs.self.nixosConfigurations;
  };

  modules = [
    inputs.sops-nix.nixosModules.sops
    inputs.home-manager.nixosModules.home-manager
    inputs.nix-bitcoin.nixosModules.default
    inputs.nix-openclaw.nixosModules.openclaw-gateway
    inputs.disko.nixosModules.disko
    ../modules
    host.module
  ];
}
