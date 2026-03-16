{
  system = "x86_64-linux";
  features = {
    home-manager = true;
    sops = true;
    nix-bitcoin = false;
    nix-openclaw = false;
    disko = false;
  };
}
