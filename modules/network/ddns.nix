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
      default = [ ];
      description = "Domains to update.";
    };

    provider = lib.mkOption {
      type = lib.types.enum supportedProviders;
      default = "cloudflare";
      description = "DDNS provider. Supported: ${lib.concatStringsSep ", " supportedProviders}.";
    };

    credentialsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
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
      {
        assertion = lib.length cfg.domains == lib.length (lib.unique cfg.domains);
        message = "alanix.ddns.domains must not contain duplicates.";
      }
      {
        assertion = cfg.credentialsFile != null;
        message = "alanix.ddns.credentialsFile must be set when alanix.ddns.enable = true.";
      }
    ];

    services.cloudflare-ddns = lib.mkIf (cfg.provider == "cloudflare" && cfg.credentialsFile != null) {
      enable = true;
      domains = cfg.domains;
      credentialsFile = cfg.credentialsFile;
      provider.ipv6 = "none";
    };
  };
}
