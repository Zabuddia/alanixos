{
  description = "alanixos self-hosting config";

  inputs = {
    # Base system
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    # User environment
    home-manager = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Secrets management
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Disk layout
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Bitcoin stack
    nix-bitcoin = {
      url = "github:fort-nix/nix-bitcoin";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # OpenClaw gateway
    nix-openclaw = {
      url = "github:openclaw/nix-openclaw";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
      inputs.home-manager.follows = "home-manager";
    };
  };

  outputs = inputs:
  let
    lib = inputs.nixpkgs.lib;
    mkHost = import ./lib/mkHost.nix { inherit inputs; };
    hostNames = builtins.attrNames (builtins.readDir ./hosts);
  in
  {
    nixosConfigurations = lib.listToAttrs (map (hostname:
      let meta = import ./hosts/${hostname}/meta.nix; in
      lib.nameValuePair hostname (mkHost {
        inherit hostname;
        inherit (meta) system features;
      })
    ) hostNames);
  };
}
