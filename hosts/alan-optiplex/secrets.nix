{ config, ... }:

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

  sops.secrets."cloudflare/api-token" = {
    owner = "root";
    group = "root";
    mode = "0400";
  };

  sops.secrets."cluster/restic-password" = {
    sopsFile = ../../secrets/secrets.yaml;
    owner = "buddia";
    group = "users";
    mode = "0400";
  };

  sops.secrets."sunshine-web-ui-passwords/alan-optiplex" = {
    owner = "buddia";
    group = "users";
    mode = "0400";
  };

  sops.templates."cloudflare-env" = {
    content = "CLOUDFLARE_API_TOKEN=${config.sops.placeholder."cloudflare/api-token"}";
    owner = "cloudflare-ddns";
  };

  sops.secrets."wireguard-private-keys/alan-optiplex" = {
    sopsFile = ../../secrets/secrets.yaml;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  sops.secrets."ssh-private-keys/alan-optiplex" = {
    owner = "buddia";
    group = "users";
    mode = "0600";
    path = "/home/buddia/.ssh/id_ed25519";
  };

  sops.secrets."ssh-host-keys/alan-optiplex" = {
    owner = "root";
    group = "root";
    mode = "0600";
    path = "/etc/ssh/ssh_host_ed25519_key";
  };

  sops.secrets."tor/vaultwarden/secret-key-base64" = {
    sopsFile = ../../secrets/secrets.yaml;
    owner = "root";
    group = "root";
    mode = "0400";
  };
}
