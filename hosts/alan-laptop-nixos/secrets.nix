{ config, lib, ... }:

let
  openclawCfg = config.alanix.openclaw;
  openclawEnabled = openclawCfg.gateway.enable || openclawCfg.desktopNode.enable;
in
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
        path = "/home/buddia/.ssh/id_ed25519";
      };

      "ssh-private-keys/alan-laptop-nixos-work" = {
        owner = "buddia";
        group = "users";
        mode = "0600";
        path = "/home/buddia/.ssh/id_ed25519_work";
      };
    }
    (lib.mkIf (openclawEnabled && openclawCfg.tokenSecret != null) {
      ${openclawCfg.tokenSecret} = {
        owner = openclawCfg.user;
        group = "users";
        mode = "0400";
      };
    })
  ];

  sops.templates = lib.mkMerge [
    {
      "cloudflare-env" = {
        content = "CLOUDFLARE_API_TOKEN=${config.sops.placeholder."cloudflare/api-token"}";
        owner = "cloudflare-ddns";
      };
    }
    (lib.mkIf (openclawEnabled && openclawCfg.tokenSecret != null) {
      "openclaw-env" = {
        content = "OPENCLAW_GATEWAY_TOKEN=${config.sops.placeholder.${openclawCfg.tokenSecret}}";
        owner = openclawCfg.user;
        group = "users";
        mode = "0400";
      };
    })
  ];
}
