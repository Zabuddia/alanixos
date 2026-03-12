{
  description = "alanixos Phase A active/passive homelab cluster";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-bitcoin = {
      url = "github:fort-nix/nix-bitcoin";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    invidious-companion-src = {
      url = "github:iv-org/invidious-companion";
      flake = false;
    };
  };

  outputs = inputs:
    let
      lib = inputs.nixpkgs.lib;
      clusterConfig = import ./cluster/default.nix;
      mkHost = import ./lib/mkHost.nix {
        inherit inputs clusterConfig;
      };
    in
    {
      nixosConfigurations = lib.mapAttrs
        (hostname: node:
          mkHost {
            inherit hostname;
            system = node.system;
            enableBitcoin = hostname == "alan-big-nixos";
          })
        clusterConfig.nodes;
    };
}
