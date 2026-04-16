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

  sops.secrets."jellyfin-passwords/buddia" = {
    sopsFile = ../../secrets/secrets.yaml;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  sops.secrets."nextcloud-passwords/buddia" = {
    sopsFile = ../../secrets/secrets.yaml;
    owner = "nextcloud";
    group = "nextcloud";
    mode = "0400";
  };

  sops.secrets."radicale-passwords/buddia" = {
    sopsFile = ../../secrets/secrets.yaml;
    owner = "radicale";
    group = "radicale";
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

  sops.secrets."openwebui-passwords/buddia" = {
    sopsFile = ../../secrets/secrets.yaml;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  sops.secrets."searxng-app/secret-key" = {
    sopsFile = ../../secrets/secrets.yaml;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  sops.secrets."sunshine-web-ui-passwords/alan-node" = {
    owner = "buddia";
    group = "users";
    mode = "0400";
  };

  sops.templates."cloudflare-env" = {
    content = "CLOUDFLARE_API_TOKEN=${config.sops.placeholder."cloudflare/api-token"}";
    owner = "cloudflare-ddns";
  };

  sops.secrets."wireguard-private-keys/alan-node" = {
    sopsFile = ../../secrets/secrets.yaml;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  sops.secrets."ssh-private-keys/alan-node" = {
    owner = "buddia";
    group = "users";
    mode = "0600";
    path = "/home/buddia/.ssh/id_ed25519";
  };

  sops.secrets."ssh-host-keys/alan-node" = {
    owner = "root";
    group = "root";
    mode = "0600";
    path = "/etc/ssh/ssh_host_ed25519_key";
  };

  sops.secrets."syncthing-certs/alan-node" = {
    owner = "root";
    group = "root";
    mode = "0400";
  };

  sops.secrets."syncthing-keys/alan-node" = {
    owner = "root";
    group = "root";
    mode = "0400";
  };

  sops.secrets."tor/vaultwarden/secret-key-base64" = {
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

  sops.secrets."tor/jellyfin/secret-key-base64" = {
    sopsFile = ../../secrets/secrets.yaml;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  sops.secrets."tor/filebrowser/secret-key-base64" = {
    sopsFile = ../../secrets/secrets.yaml;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  sops.secrets."tor/nextcloud/secret-key-base64" = {
    sopsFile = ../../secrets/secrets.yaml;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  sops.secrets."tor/nextcloud-collabora/secret-key-base64" = {
    sopsFile = ../../secrets/secrets.yaml;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  sops.secrets."tor/radicale/secret-key-base64" = {
    sopsFile = ../../secrets/secrets.yaml;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  sops.secrets."tor/openwebui/secret-key-base64" = {
    sopsFile = ../../secrets/secrets.yaml;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  sops.secrets."tor/searxng/secret-key-base64" = {
    sopsFile = ../../secrets/secrets.yaml;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  sops.secrets."tor/cluster-dashboard/alan-node/secret-key-base64" = {
    sopsFile = ../../secrets/secrets.yaml;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  sops.secrets."wifi-passwords/cinnamon-tree" = {
    owner = "root";
    mode = "0400";
  };
}
