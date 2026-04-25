{ config, ... }:

{

  sops = {
    defaultSopsFile = (import ../../secrets/files.nix).users;
    age.keyFile = "/var/lib/sops-nix/key.txt";
    age.sshKeyPaths = [ ];
  };

  sops.secrets."password-hashes/buddia" = {
    sopsFile = (import ../../secrets/files.nix).users;
    neededForUsers = true;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  sops.secrets."wireguard-private-keys/alan-big-nixos" = {
    sopsFile = (import ../../secrets/files.nix).network;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  sops.secrets."ssh-private-keys/alan-big-nixos" = {
    sopsFile = (import ../../secrets/files.nix).users;
    owner = "buddia";
    group = "users";
    mode = "0600";
    path = "/home/buddia/.ssh/id_ed25519";
  };

  sops.secrets."ssh-host-keys/alan-big-nixos" = {
    sopsFile = (import ../../secrets/files.nix).network;
    owner = "root";
    group = "root";
    mode = "0600";
    path = "/etc/ssh/ssh_host_ed25519_key";
  };

  sops.secrets."syncthing-certs/alan-big-nixos" = {
    sopsFile = (import ../../secrets/files.nix).syncthing;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  sops.secrets."syncthing-keys/alan-big-nixos" = {
    sopsFile = (import ../../secrets/files.nix).syncthing;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  sops.secrets."cloudflare/api-token" = {
    sopsFile = (import ../../secrets/files.nix).network;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  sops.secrets."cluster/restic-password" = {
    sopsFile = (import ../../secrets/files.nix).cluster;
    owner = "buddia";
    group = "users";
    mode = "0400";
  };

  sops.secrets."cluster/dashboard-password" = {
    sopsFile = (import ../../secrets/files.nix).cluster;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  sops.secrets."sunshine-web-ui-passwords/alan-big-nixos" = {
    sopsFile = (import ../../secrets/files.nix).servicePasswords;
    owner = "buddia";
    group = "users";
    mode = "0400";
  };

  sops.templates."cloudflare-env" = {
    content = "CLOUDFLARE_API_TOKEN=${config.sops.placeholder."cloudflare/api-token"}";
    owner = "cloudflare-ddns";
  };

  sops.secrets."filebrowser-passwords/admin" = {
    sopsFile = (import ../../secrets/files.nix).servicePasswords;
    owner = "filebrowser";
    group = "filebrowser";
    mode = "0400";
  };

  sops.secrets."filebrowser-passwords/buddia" = {
    sopsFile = (import ../../secrets/files.nix).servicePasswords;
    owner = "filebrowser";
    group = "filebrowser";
    mode = "0400";
  };

  sops.secrets."forgejo-passwords/buddia" = {
    sopsFile = (import ../../secrets/files.nix).servicePasswords;
    owner = "forgejo";
    group = "forgejo";
    mode = "0400";
  };

  sops.secrets."invidious/hmac-key" = {
    sopsFile = (import ../../secrets/files.nix).servicePasswords;
    owner = "invidious";
    group = "invidious";
    mode = "0400";
  };

  sops.secrets."invidious/companion-secret-key" = {
    sopsFile = (import ../../secrets/files.nix).servicePasswords;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  sops.secrets."invidious-passwords/buddia" = {
    sopsFile = (import ../../secrets/files.nix).servicePasswords;
    owner = "invidious";
    group = "invidious";
    mode = "0400";
  };

  sops.secrets."immich-passwords/buddia" = {
    sopsFile = (import ../../secrets/files.nix).servicePasswords;
    owner = "immich";
    group = "immich";
    mode = "0400";
  };

  sops.secrets."jellyfin-passwords/buddia" = {
    sopsFile = (import ../../secrets/files.nix).servicePasswords;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  sops.secrets."nextcloud-passwords/fifefam" = {
    sopsFile = (import ../../secrets/files.nix).servicePasswords;
    owner = "nextcloud";
    group = "nextcloud";
    mode = "0400";
  };

  sops.secrets."nextcloud-passwords/waffleiron" = {
    sopsFile = (import ../../secrets/files.nix).servicePasswords;
    owner = "nextcloud";
    group = "nextcloud";
    mode = "0400";
  };

  sops.secrets."nextcloud-passwords/buddia" = {
    sopsFile = (import ../../secrets/files.nix).servicePasswords;
    owner = "nextcloud";
    group = "nextcloud";
    mode = "0400";
  };

  sops.secrets."radicale-passwords/buddia" = {
    sopsFile = (import ../../secrets/files.nix).servicePasswords;
    owner = "radicale";
    group = "radicale";
    mode = "0400";
  };

  sops.secrets."openwebui-passwords/buddia" = {
    sopsFile = (import ../../secrets/files.nix).servicePasswords;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  sops.secrets."searxng-app/secret-key" = {
    sopsFile = (import ../../secrets/files.nix).servicePasswords;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  sops.secrets."tor/filebrowser/secret-key-base64" = {
    sopsFile = (import ../../secrets/files.nix).tor;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  sops.secrets."tor/forgejo/secret-key-base64" = {
    sopsFile = (import ../../secrets/files.nix).tor;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  sops.secrets."tor/jellyfin/secret-key-base64" = {
    sopsFile = (import ../../secrets/files.nix).tor;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  sops.secrets."tor/invidious/secret-key-base64" = {
    sopsFile = (import ../../secrets/files.nix).tor;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  sops.secrets."tor/immich/secret-key-base64" = {
    sopsFile = (import ../../secrets/files.nix).tor;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  sops.secrets."tor/nextcloud/secret-key-base64" = {
    sopsFile = (import ../../secrets/files.nix).tor;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  sops.secrets."tor/nextcloud-collabora/secret-key-base64" = {
    sopsFile = (import ../../secrets/files.nix).tor;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  sops.secrets."tor/radicale/secret-key-base64" = {
    sopsFile = (import ../../secrets/files.nix).tor;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  sops.secrets."tor/openwebui/secret-key-base64" = {
    sopsFile = (import ../../secrets/files.nix).tor;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  sops.secrets."tor/searxng/secret-key-base64" = {
    sopsFile = (import ../../secrets/files.nix).tor;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  sops.secrets."tor/tvheadend/secret-key-base64" = {
    sopsFile = (import ../../secrets/files.nix).tor;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  sops.secrets."tor/vaultwarden/secret-key-base64" = {
    sopsFile = (import ../../secrets/files.nix).tor;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  sops.secrets."tor/cluster-dashboard/alan-big-nixos/secret-key-base64" = {
    sopsFile = (import ../../secrets/files.nix).tor;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  sops.secrets."wifi-passwords/cinnamon-tree" = {
    sopsFile = (import ../../secrets/files.nix).network;
    owner = "root";
    mode = "0400";
  };
}
