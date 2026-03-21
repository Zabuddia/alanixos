{ lib, config, ... }:

let
  cfg = config.alanix.ddns;
  supportedProviders = [ "cloudflare" ];
in
{
  options.alanix.ddns = {
    enable = lib.mkEnableOption "dynamic DNS";

    domains = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "Domains to update.";
    };

    provider = lib.mkOption {
      type = lib.types.str;
      description = "DDNS provider. Supported: ${lib.concatStringsSep ", " supportedProviders}.";
    };

    credentialsFile = lib.mkOption {
      type = lib.types.path;
      description = "Path to provider credentials file.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.elem cfg.provider supportedProviders;
        message = "alanix.ddns: unsupported provider '${cfg.provider}'. Supported: ${lib.concatStringsSep ", " supportedProviders}.";
      }
      {
        assertion = cfg.domains != [];
        message = "alanix.ddns: domains must not be empty.";
      }
    ];

    services.cloudflare-ddns = lib.mkIf (cfg.provider == "cloudflare") {
      enable = true;
      domains = cfg.domains;
      credentialsFile = cfg.credentialsFile;
      provider.ipv6 = "none";
    };
  };
}
