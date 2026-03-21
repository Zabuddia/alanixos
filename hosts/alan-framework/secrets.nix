{ config, lib, ... }:

let
  openclawCfg = config.alanix.openclaw;
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
    }
    (lib.mkIf (openclawCfg.enable && openclawCfg.tokenSecret != null) {
      ${openclawCfg.tokenSecret} = {
        owner = "openclaw";
        group = "openclaw";
        mode = "0400";
      };
    })
    (lib.mkIf (openclawCfg.enable && openclawCfg.telegram.enable && openclawCfg.telegram.tokenSecret != null) {
      ${openclawCfg.telegram.tokenSecret} = {
        owner = "openclaw";
        group = "openclaw";
        mode = "0400";
      };
    })
    (lib.mkIf (openclawCfg.enable && openclawCfg.webSearch.enable && openclawCfg.webSearch.apiKeySecret != null) {
      ${openclawCfg.webSearch.apiKeySecret} = {
        owner = "openclaw";
        group = "openclaw";
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
    (lib.mkIf (openclawCfg.enable && openclawCfg.tokenSecret != null) {
      "openclaw-gateway-env" = {
        content = "OPENCLAW_GATEWAY_TOKEN=${config.sops.placeholder.${openclawCfg.tokenSecret}}";
        owner = "openclaw";
        group = "openclaw";
        mode = "0400";
      };

      "openclaw-node-env" = {
        content = "OPENCLAW_GATEWAY_TOKEN=${config.sops.placeholder.${openclawCfg.tokenSecret}}";
        owner = "buddia";
        group = "users";
        mode = "0400";
      };
    })
    (lib.mkIf (openclawCfg.enable && openclawCfg.telegram.enable && openclawCfg.telegram.tokenSecret != null) {
      "openclaw-telegram-bot-token" = {
        content = config.sops.placeholder.${openclawCfg.telegram.tokenSecret};
        owner = "openclaw";
        group = "openclaw";
        mode = "0400";
      };
    })
    (lib.mkIf (openclawCfg.enable && openclawCfg.webSearch.enable && openclawCfg.webSearch.apiKeySecret != null) {
      "openclaw-brave-env" = {
        content = "BRAVE_API_KEY=${config.sops.placeholder.${openclawCfg.webSearch.apiKeySecret}}";
        owner = "openclaw";
        group = "openclaw";
        mode = "0400";
      };
    })
  ];
}
