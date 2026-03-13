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
    }
    (lib.mkIf openclawCfg.enable {
      ${openclawCfg.tokenSecret} = {
        owner = "openclaw";
        group = "openclaw";
        mode = "0400";
      };
    })
    (lib.mkIf (openclawCfg.enable && openclawCfg.telegram.enable) {
      ${openclawCfg.telegram.tokenSecret} = {
        owner = "openclaw";
        group = "openclaw";
        mode = "0400";
      };
    })
    (lib.mkIf (openclawCfg.enable && openclawCfg.nostr.enable) {
      ${openclawCfg.nostr.privateKeySecret} = {
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
    (lib.mkIf openclawCfg.enable {
      "openclaw-gateway-env" = {
        content = "OPENCLAW_GATEWAY_TOKEN=${config.sops.placeholder.${openclawCfg.tokenSecret}}";
        owner = "openclaw";
        group = "openclaw";
        mode = "0400";
      };
    })
    (lib.mkIf (openclawCfg.enable && openclawCfg.telegram.enable) {
      "openclaw-telegram-bot-token" = {
        content = config.sops.placeholder.${openclawCfg.telegram.tokenSecret};
        owner = "openclaw";
        group = "openclaw";
        mode = "0400";
      };
    })
    (lib.mkIf (openclawCfg.enable && openclawCfg.nostr.enable) {
      "openclaw-nostr-env" = {
        content = "NOSTR_PRIVATE_KEY=${config.sops.placeholder.${openclawCfg.nostr.privateKeySecret}}";
        owner = "openclaw";
        group = "openclaw";
        mode = "0400";
      };
    })
  ];
}
