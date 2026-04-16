{ config, lib, ... }:

{

  sops = {
    defaultSopsFile = (import ../../secrets/files.nix).users;
    age.keyFile = "/var/lib/sops-nix/key.txt";
  };

  sops.secrets = lib.mkMerge [
    {
      # Add matching encrypted values under secrets/*.yaml before deploying this host.
      "password-hashes/buddia" = {
        sopsFile = (import ../../secrets/files.nix).users;
        neededForUsers = true;
        owner = "root";
        group = "root";
        mode = "0400";
      };

      "cloudflare/api-token" = {
        sopsFile = (import ../../secrets/files.nix).network;
        owner = "root";
        group = "root";
        mode = "0400";
      };

      "sunshine-web-ui-passwords/alan-framework-laptop" = {
        sopsFile = (import ../../secrets/files.nix).servicePasswords;
        owner = "buddia";
        group = "users";
        mode = "0400";
      };

      "wireguard-private-keys/alan-framework-laptop" = {
        sopsFile = (import ../../secrets/files.nix).network;
        owner = "root";
        group = "root";
        mode = "0400";
      };

      "ssh-private-keys/alan-framework-laptop" = {
        sopsFile = (import ../../secrets/files.nix).users;
        owner = "buddia";
        group = "users";
        mode = "0600";
      };

      "ssh-private-keys/alan-laptop-nixos-work" = {
        sopsFile = (import ../../secrets/files.nix).users;
        owner = "buddia";
        group = "users";
        mode = "0600";
      };

      "ssh-host-keys/alan-framework-laptop" = {
        sopsFile = (import ../../secrets/files.nix).network;
        owner = "root";
        group = "root";
        mode = "0600";
        path = "/etc/ssh/ssh_host_ed25519_key";
      };

      "syncthing-certs/alan-framework-laptop" = {
        sopsFile = (import ../../secrets/files.nix).syncthing;
        owner = "root";
        group = "root";
        mode = "0400";
      };

      "syncthing-keys/alan-framework-laptop" = {
        sopsFile = (import ../../secrets/files.nix).syncthing;
        owner = "root";
        group = "root";
        mode = "0400";
      };

      "wifi-passwords/cinnamon-tree" = {
        sopsFile = (import ../../secrets/files.nix).network;
        owner = "root";
        mode = "0400";
      };
    }
  ];

  sops.templates = lib.mkMerge [
    {
      "cloudflare-env" = {
        content = "CLOUDFLARE_API_TOKEN=${config.sops.placeholder."cloudflare/api-token"}";
        owner = "cloudflare-ddns";
      };
    }
  ];
}
