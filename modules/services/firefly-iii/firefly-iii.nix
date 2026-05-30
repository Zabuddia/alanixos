{ config, lib, pkgs, ... }:
let
  cfg = config.alanix.firefly-iii;
  clusterCfg = cfg.cluster;
  serviceExposure = import ../../../lib/mkServiceExposure.nix { inherit lib pkgs; };
  serviceIdentity = import ../../../lib/mkServiceIdentity.nix { inherit lib; };

  exposeCfg = cfg.expose;
  inherit (serviceIdentity) hasValue;

  endpoint = {
    address = cfg.listenAddress;
    port = cfg.port;
    protocol = "http";
  };

  baseConfigReady = hasValue cfg.listenAddress && cfg.port != null && hasValue cfg.virtualHost;
in
{
  options.alanix.firefly-iii = {
    enable = lib.mkEnableOption "Firefly III (Alanix)";

    package = lib.mkPackageOption pkgs "firefly-iii" { };

    virtualHost = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Nginx server_name and base for APP_URL (e.g. firefly.fifefin.com).";
    };

    listenAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Bind address for the internal nginx listener.";
    };

    port = lib.mkOption {
      type = lib.types.nullOr lib.types.port;
      default = null;
      description = "HTTP port for the internal nginx listener.";
    };

    backupDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Cluster backup staging directory. Required when cluster.enable = true.";
    };

    appKeySecret = lib.mkOption {
      type = lib.types.str;
      description = ''
        Name of a sops secret whose contents are the Laravel APP_KEY
        (format: base64:<32-random-bytes-in-base64>).
      '';
    };

    settings = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = "Extra settings merged into services.firefly-iii.settings.";
    };

    cluster = {
      enable = lib.mkEnableOption "cluster-manage Firefly III through alanix.cluster";

      backupInterval = lib.mkOption {
        type = lib.types.str;
        default = "1h";
      };

      maxBackupAge = lib.mkOption {
        type = lib.types.str;
        default = "6h";
      };
    };

    expose = serviceExposure.mkOptions {
      serviceName = "firefly-iii";
      serviceDescription = "Firefly III";
      defaultPublicPort = 80;
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions =
        [
          {
            assertion = hasValue cfg.virtualHost;
            message = "alanix.firefly-iii.virtualHost must be set when alanix.firefly-iii.enable = true.";
          }
          {
            assertion = hasValue cfg.listenAddress;
            message = "alanix.firefly-iii.listenAddress must be set when alanix.firefly-iii.enable = true.";
          }
          {
            assertion = cfg.port != null;
            message = "alanix.firefly-iii.port must be set when alanix.firefly-iii.enable = true.";
          }
          {
            assertion = cfg.backupDir == null || lib.hasPrefix "/" cfg.backupDir;
            message = "alanix.firefly-iii.backupDir must be an absolute path when set.";
          }
          {
            assertion = !clusterCfg.enable || cfg.backupDir != null;
            message = "alanix.firefly-iii.cluster.enable requires alanix.firefly-iii.backupDir to be set.";
          }
          {
            assertion = lib.hasAttrByPath [ "sops" "secrets" cfg.appKeySecret ] config;
            message = "alanix.firefly-iii.appKeySecret must reference a declared sops secret.";
          }
        ]
        ++ serviceExposure.mkAssertions {
          inherit config endpoint exposeCfg;
          optionPrefix = "alanix.firefly-iii.expose";
        };

      services.firefly-iii = lib.mkIf baseConfigReady {
        enable = true;
        package = cfg.package;
        enableNginx = true;
        virtualHost = cfg.virtualHost;
        settings = {
          APP_KEY_FILE = config.sops.secrets.${cfg.appKeySecret}.path;
          APP_URL = "http://${cfg.virtualHost}";
          DB_CONNECTION = "sqlite";
          APP_ENV = "local";
        } // cfg.settings;
      };

      # Restrict nginx to the internal listen address and port instead of
      # the module default of all interfaces on port 80.
      services.nginx.virtualHosts.${cfg.virtualHost} = lib.mkIf baseConfigReady {
        listen = [{ addr = cfg.listenAddress; port = cfg.port; }];
      };
    }

    (lib.mkIf (baseConfigReady && !clusterCfg.enable) (
      serviceExposure.mkConfig {
        inherit config endpoint exposeCfg;
        serviceName = "firefly-iii";
        serviceDescription = "Firefly III";
      }
    ))
  ]);
}
