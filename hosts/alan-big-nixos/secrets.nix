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

  sops.secrets."forgejo-passwords/buddia" = {
    sopsFile = ../../secrets/secrets.yaml;
    owner = "forgejo";
    group = "forgejo";
    mode = "0400";
  };

  sops.secrets."invidious/hmac-key" = {
    sopsFile = ../../secrets/secrets.yaml;
    owner = "invidious";
    group = "invidious";
    mode = "0400";
  };

  sops.secrets."invidious/companion-secret-key" = {
    sopsFile = ../../secrets/secrets.yaml;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  sops.secrets."invidious-passwords/buddia" = {
    sopsFile = ../../secrets/secrets.yaml;
    owner = "invidious";
    group = "invidious";
    mode = "0400";
  };

  sops.secrets."immich-passwords/buddia" = {
    sopsFile = ../../secrets/secrets.yaml;
    owner = "immich";
    group = "immich";
    mode = "0400";
  };

  sops.secrets."tor/filebrowser/secret-key-base64" = {
    sopsFile = ../../secrets/secrets.yaml;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  sops.secrets."tor/forgejo/secret-key-base64" = {
    sopsFile = ../../secrets/secrets.yaml;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  sops.secrets."tor/invidious/secret-key-base64" = {
    sopsFile = ../../secrets/secrets.yaml;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  sops.secrets."tor/immich/secret-key-base64" = {
    sopsFile = ../../secrets/secrets.yaml;
    owner = "root";
    group = "root";
    mode = "0400";
  };
}
