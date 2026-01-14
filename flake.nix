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
  };

  outputs = inputs:
  let
    mkHost = import ./lib/mkHost.nix { inherit inputs; };
  in
  {
    nixosConfigurations = {
      alan-big-nixos = mkHost {
        hostname = "alan-big-nixos";
        system = "x86_64-linux";

        features = {
          home-manager = true;
          sops = true;
          nix-bitcoin = false;
          disko = false;
        };
      };
    };
  };
}