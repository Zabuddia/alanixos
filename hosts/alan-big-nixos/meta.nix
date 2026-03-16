{
  system = "x86_64-linux";
  features = {
    home-manager = true;
    sops = true;
    nix-bitcoin = true;
    nix-openclaw = false;
    disko = false;
  };
}
