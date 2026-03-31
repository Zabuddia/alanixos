{ config, lib, pkgs, ... }:
let
  cfg = config.alanix.vaultwarden;
  serviceExposure = import ../../lib/mkServiceExposure.nix { inherit lib pkgs; };
  serviceIdentity = import ../../lib/mkServiceIdentity.nix { inherit lib; };

  exposeCfg = cfg.expose;
  inherit (serviceIdentity) hasValue;

  endpoint = {
    address = cfg.listenAddress;
    port = cfg.port;
    protocol = "http";
  };

  baseConfigReady = hasValue cfg.listenAddress && cfg.port != null;

  effectiveRootUrl =
    let
      derived = serviceIdentity.rootUrl {
        inherit config exposeCfg;
        listenAddress = cfg.listenAddress;
        port = cfg.port;
        rootUrlOverride = cfg.rootUrl;
        allowWireguard = false;
        allowListenAddressFallback = false;
      };
    in
    if derived == null then null else lib.removeSuffix "/" derived;

  defaultConfig =
    {
      ROCKET_ADDRESS = cfg.listenAddress;
      ROCKET_PORT = cfg.port;
      SIGNUPS_ALLOWED = !cfg.disableRegistration;
    }
    // lib.optionalAttrs (effectiveRootUrl != null) {
      DOMAIN = effectiveRootUrl;
    };
in
{
  options.alanix.vaultwarden = {
    enable = lib.mkEnableOption "Vaultwarden (Alanix)";

    listenAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };

    port = lib.mkOption {
      type = lib.types.nullOr lib.types.port;
      default = null;
    };

    rootUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional public Vaultwarden URL, including http:// or https:// and any base path.";
    };

    disableRegistration = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether Vaultwarden should disallow open signups.";
    };

    backupDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional Vaultwarden sqlite backup directory passed through to services.vaultwarden.backupDir.";
    };

    adminTokenSecret = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Optional sops secret containing the plaintext Vaultwarden ADMIN_TOKEN.
        Set this only if you want the Vaultwarden admin page enabled.
      '';
    };

    settings = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = "Extra services.vaultwarden.config merged on top of the Alanix defaults.";
    };

    expose = serviceExposure.mkOptions {
      serviceName = "vaultwarden";
      serviceDescription = "Vaultwarden";
      defaultPublicPort = 80;
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions =
        [
          {
            assertion = hasValue cfg.listenAddress;
            message = "alanix.vaultwarden.listenAddress must be set when alanix.vaultwarden.enable = true.";
          }
          {
            assertion = cfg.port != null;
            message = "alanix.vaultwarden.port must be set when alanix.vaultwarden.enable = true.";
          }
          {
            assertion = cfg.rootUrl == null || builtins.match "^https?://.+" cfg.rootUrl != null;
            message = "alanix.vaultwarden.rootUrl must include http:// or https:// when set.";
          }
          {
            assertion = cfg.backupDir == null || lib.hasPrefix "/" cfg.backupDir;
            message = "alanix.vaultwarden.backupDir must be an absolute path when set.";
          }
          {
            assertion = cfg.adminTokenSecret == null || lib.hasAttrByPath [ "sops" "secrets" cfg.adminTokenSecret ] config;
            message = "alanix.vaultwarden.adminTokenSecret must reference a declared sops secret.";
          }
        ]
        ++ serviceExposure.mkAssertions {
          inherit config endpoint exposeCfg;
          optionPrefix = "alanix.vaultwarden.expose";
        };

      sops.templates."alanix-vaultwarden-env" = lib.mkIf (cfg.adminTokenSecret != null) {
        content = ''
          ADMIN_TOKEN=${config.sops.placeholder.${cfg.adminTokenSecret}}
        '';
        owner = "root";
        group = "root";
        mode = "0400";
      };

      services.vaultwarden = lib.mkIf baseConfigReady {
        enable = true;
        backupDir = cfg.backupDir;
        environmentFile = lib.optional (cfg.adminTokenSecret != null) config.sops.templates."alanix-vaultwarden-env".path;
        config = lib.recursiveUpdate defaultConfig cfg.settings;
      };
    }

    (lib.mkIf baseConfigReady (
      serviceExposure.mkConfig {
        inherit config endpoint exposeCfg;
        serviceName = "vaultwarden";
        serviceDescription = "Vaultwarden";
      }
    ))
  ]);
}
