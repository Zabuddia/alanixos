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

      "sunshine-web-ui-passwords/alan-framework" = {
        owner = "buddia";
        group = "users";
        mode = "0400";
      };

      "wireguard-private-keys/alan-framework" = {
        sopsFile = ../../secrets/secrets.yaml;
        owner = "root";
        group = "root";
        mode = "0400";
      };

      "ssh-private-keys/alan-framework" = {
        owner = "buddia";
        group = "users";
        mode = "0600";
        path = "/home/buddia/.ssh/id_ed25519";
      };

      "ssh-host-keys/alan-framework" = {
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
