{ inputs }:
{ host, hostname }:

let
  nixpkgs = inputs.nixpkgs;
  lib = nixpkgs.lib;
in
if !(host ? system) then
  throw "hosts/${hostname}/default.nix must define a top-level `system` attribute."
else if !(host ? module) then
  throw "hosts/${hostname}/default.nix must define a top-level `module` attribute."
else
let
  system = host.system;
in
lib.nixosSystem {
  inherit system;

  specialArgs = {
    inherit hostname inputs;
    allHosts = inputs.self.nixosConfigurations;
  };

  modules = [
    inputs.sops-nix.nixosModules.sops
    inputs.home-manager.nixosModules.home-manager
    inputs.nix-bitcoin.nixosModules.default
    inputs.disko.nixosModules.disko
    ../modules
    host.module
  ];
}
