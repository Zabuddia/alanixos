{ config, lib, ... }:

{
  sops = {
    defaultSopsFile = ../../secrets/secrets.yaml;
    age.keyFile = "/var/lib/sops-nix/key.txt";
  };

  sops.secrets = lib.mkMerge [
    {
      "password-hashes/buddia" = {
        neededForUsers = true;
        owner = "root";
        group = "root";
        mode = "0400";
      };

      "cloudflare/api-token" = {
        owner = "root";
        group = "root";
        mode = "0400";
      };

      "sunshine-web-ui-passwords/alan-laptop-nixos" = {
        owner = "buddia";
        group = "users";
        mode = "0400";
      };

      "wireguard-private-keys/alan-laptop-nixos" = {
        sopsFile = ../../secrets/secrets.yaml;
        owner = "root";
        group = "root";
        mode = "0400";
      };

      "ssh-private-keys/alan-laptop-nixos" = {
        owner = "buddia";
        group = "users";
        mode = "0600";
      };

      "ssh-private-keys/alan-laptop-nixos-work" = {
        owner = "buddia";
        group = "users";
        mode = "0600";
      };

      "ssh-host-keys/alan-laptop-nixos" = {
        owner = "root";
        group = "root";
        mode = "0600";
        path = "/etc/ssh/ssh_host_ed25519_key";
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
