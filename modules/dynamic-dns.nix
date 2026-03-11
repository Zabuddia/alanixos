{ config, lib, ... }:
let
  cfg = config.alanix.dynamicDns;
  hasSopsSecrets = lib.hasAttrByPath [ "sops" "secrets" ] config;
in
{
  imports = [ ./dns-updaters.nix ];

  options.alanix.dynamicDns = {
    enable = lib.mkEnableOption "Dynamic DNS updates";

    provider = lib.mkOption {
      type = lib.types.enum [ "cloudflare" ];
      default = "cloudflare";
      description = "DNS provider backend.";
    };

    zone = lib.mkOption {
      type = lib.types.str;
      description = "DNS zone for DDNS updates (for example fifefin.com).";
    };

    records = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Fully-qualified DNS records that should point to this host.";
    };

    apiTokenSecret = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "sops secret name containing provider API token.";
    };

    interval = lib.mkOption {
      type = lib.types.str;
      default = "2min";
      description = "How frequently DNS records are reconciled.";
    };

    startupDelay = lib.mkOption {
      type = lib.types.str;
      default = "30s";
      description = "Delay before first update after boot.";
    };

    proxied = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether records should be proxied.";
    };

    ttl = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 60;
      description = "TTL for A records.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.records != [];
        message = "alanix.dynamicDns.records must contain at least one record when enabled.";
      }
      {
        assertion = cfg.apiTokenSecret != null;
        message = "alanix.dynamicDns.apiTokenSecret must be set when DDNS is enabled.";
      }
      {
        assertion = hasSopsSecrets;
        message = "alanix.dynamicDns requires sops-nix (sops.secrets) to be enabled.";
      }
    ];

    alanix.dnsUpdaters.host-endpoint = {
      enable = true;
      provider = cfg.provider;
      zone = cfg.zone;
      records = cfg.records;
      tokenSecret = cfg.apiTokenSecret;
      interval = cfg.interval;
      startupDelay = cfg.startupDelay;
      proxied = cfg.proxied;
      ttl = cfg.ttl;
    };
  };
}
