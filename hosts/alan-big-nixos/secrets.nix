{ config, ... }:

{
  sops = {
    defaultSopsFile = ../../secrets/secrets.yaml;
    age.keyFile = "/var/lib/sops-nix/key.txt";
    age.sshKeyPaths = [ ];
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

  sops.secrets."ssh-private-keys/alan-big-nixos" = {
    owner = "buddia";
    group = "users";
    mode = "0600";
    path = "/home/buddia/.ssh/id_ed25519";
  };

  sops.secrets."ssh-host-keys/alan-big-nixos" = {
    owner = "root";
    group = "root";
    mode = "0600";
    path = "/etc/ssh/ssh_host_ed25519_key";
  };

  sops.secrets."cloudflare/api-token" = {
    owner = "root";
    group = "root";
    mode = "0400";
  };

  sops.templates."cloudflare-env" = {
    content = "CLOUDFLARE_API_TOKEN=${config.sops.placeholder."cloudflare/api-token"}";
    owner = "cloudflare-ddns";
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
