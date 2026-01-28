{ config, ...}:
{
  sops = {
    defaultSopsFile = ../../secrets/secrets.yaml;
    age.keyFile = "/var/lib/sops-nix/key.txt";
  };

  sops.secrets."password-hashes/buddia" = {
    neededForUsers = true;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  sops.secrets."wireguard-private-keys/alan-big-nixos" = {
    sopsFile = ../../secrets/secrets.yaml;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  sops.secrets."filebrowser-passwords/admin" = {
    sopsFile = ../../secrets/secrets.yaml;
    owner = "filebrowser";
    group = "filebrowser";
    mode = "0400";
  };

  sops.secrets."filebrowser-passwords/buddia" = {
    sopsFile = ../../secrets/secrets.yaml;
    owner = "filebrowser";
    group = "filebrowser";
    mode = "0400";
  };
}