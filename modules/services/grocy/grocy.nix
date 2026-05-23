{ config, lib, pkgs, ... }:
let
  cfg = config.alanix.grocy;
  clusterCfg = cfg.cluster;
  serviceExposure = import ../../../lib/mkServiceExposure.nix { inherit lib pkgs; };

  exposeCfg = cfg.expose;
  hasValue = value: value != null && value != "";

  endpoint = {
    address = cfg.listenAddress;
    port = cfg.port;
    protocol = "http";
  };

  baseConfigReady =
    hasValue cfg.hostName
    && hasValue cfg.listenAddress
    && cfg.port != null
    && hasValue cfg.dataDir;
in
{
  options.alanix.grocy = {
    enable = lib.mkEnableOption "Grocy household management (Alanix)";

    hostName = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Browser-facing host name for this Grocy instance.";
    };

    listenAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "127.0.0.1";
      description = "Internal nginx address used by Grocy.";
    };

    port = lib.mkOption {
      type = lib.types.nullOr lib.types.port;
      default = null;
      description = "Internal nginx port used by Grocy.";
    };

    package = lib.mkPackageOption pkgs "grocy" { };

    dataDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "/var/lib/grocy";
      description = "Grocy state directory.";
    };

    backupDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional Grocy cluster backup staging directory.";
    };

    settings = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = "services.grocy.settings merged into the Grocy NixOS module.";
    };

    extraConfig = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Extra PHP config appended to Grocy config.php.";
    };

    phpfpmSettings = lib.mkOption {
      type = lib.types.nullOr (lib.types.attrsOf (lib.types.oneOf [
        lib.types.int
        lib.types.str
        lib.types.bool
      ]));
      default = null;
      description = "Optional services.grocy.phpfpm.settings override.";
    };

    cluster = {
      enable = lib.mkEnableOption "cluster-manage Grocy through alanix.cluster";

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
      serviceName = "grocy";
      serviceDescription = "Grocy";
      defaultPublicPort = 80;
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions =
        [
          {
            assertion = hasValue cfg.hostName;
            message = "alanix.grocy.hostName must be set when alanix.grocy.enable = true.";
          }
          {
            assertion = hasValue cfg.listenAddress;
            message = "alanix.grocy.listenAddress must be set when alanix.grocy.enable = true.";
          }
          {
            assertion = cfg.port != null;
            message = "alanix.grocy.port must be set when alanix.grocy.enable = true.";
          }
          {
            assertion = cfg.dataDir == null || lib.hasPrefix "/" cfg.dataDir;
            message = "alanix.grocy.dataDir must be an absolute path.";
          }
          {
            assertion = cfg.backupDir == null || lib.hasPrefix "/" cfg.backupDir;
            message = "alanix.grocy.backupDir must be an absolute path when set.";
          }
          {
            assertion = !clusterCfg.enable || cfg.backupDir != null;
            message = "alanix.grocy.cluster.enable requires alanix.grocy.backupDir to be set.";
          }
        ]
        ++ serviceExposure.mkAssertions {
          inherit config endpoint exposeCfg;
          optionPrefix = "alanix.grocy.expose";
        };

      services.grocy = lib.mkIf baseConfigReady (
        {
          enable = true;
          package = cfg.package;
          hostName = cfg.hostName;
          dataDir = cfg.dataDir;
          settings = cfg.settings;
          extraConfig = cfg.extraConfig;
          nginx.enableSSL = false;
        }
        // lib.optionalAttrs (cfg.phpfpmSettings != null) {
          phpfpm.settings = cfg.phpfpmSettings;
        }
      );

      services.nginx.virtualHosts = lib.mkIf baseConfigReady {
        ${cfg.hostName} = {
          listen = [
            {
              addr = cfg.listenAddress;
              port = cfg.port;
              ssl = false;
            }
          ];
          forceSSL = lib.mkForce false;
          enableACME = lib.mkForce false;
          addSSL = lib.mkForce false;
        };
      };
    }

    (lib.mkIf (baseConfigReady && !clusterCfg.enable) (
      serviceExposure.mkConfig {
        inherit config endpoint exposeCfg;
        serviceName = "grocy";
        serviceDescription = "Grocy";
      }
    ))
  ]);
}
