{ config, lib, pkgs, ... }:
let
  cfg = config.alanix.radicale;
  clusterCfg = cfg.cluster;
  serviceExposure = import ../../lib/mkServiceExposure.nix { inherit lib pkgs; };

  exposeCfg = cfg.expose;

  hasValue = value: value != null && value != "";

  endpoint = {
    address = cfg.listenAddress;
    port = cfg.port;
    protocol = "http";
  };

  baseConfigReady =
    hasValue cfg.listenAddress
    && cfg.port != null
    && hasValue cfg.storageDir;

  htpasswdContent =
    lib.concatStringsSep "\n" (
      lib.mapAttrsToList
        (username: userCfg: "${username}:${config.sops.placeholder.${userCfg.passwordSecret}}")
        cfg.users
    )
    + "\n";

  defaultRights = {
    root = {
      user = ".+";
      collection = "";
      permissions = "R";
    };

    principal = {
      user = ".+";
      collection = "{user}";
      permissions = "RW";
    };

    calendars = {
      user = ".+";
      collection = "{user}/[^/]+";
      permissions = "rw";
    };
  };

  defaultSettings = {
    server.hosts = [ "${cfg.listenAddress}:${toString cfg.port}" ];

    auth = {
      type = "htpasswd";
      htpasswd_filename = config.sops.templates."alanix-radicale-users".path;
      htpasswd_encryption = "plain";
    };

    storage.filesystem_folder = cfg.storageDir;
  };
in
{
  options.alanix.radicale = {
    enable = lib.mkEnableOption "Radicale (Alanix)";

    listenAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };

    port = lib.mkOption {
      type = lib.types.nullOr lib.types.port;
      default = null;
    };

    storageDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "/var/lib/radicale/collections";
      description = "Directory where Radicale stores calendars and address books.";
    };

    backupDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional Radicale cluster backup staging directory.";
    };

    cluster = {
      enable = lib.mkEnableOption "cluster-manage Radicale through alanix.cluster";

      backupInterval = lib.mkOption {
        type = lib.types.str;
        default = "15m";
      };

      maxBackupAge = lib.mkOption {
        type = lib.types.str;
        default = "1h";
      };
    };

    users = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
        options.passwordSecret = lib.mkOption {
          type = lib.types.str;
          description = "SOPS secret containing the plaintext password for Radicale user ${name}.";
        };
      }));
      default = { };
      description = "Declarative Radicale users written to the htpasswd authentication file.";
    };

    rights = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = "Extra services.radicale.rights merged over the Alanix owner-only defaults.";
    };

    settings = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = "Extra services.radicale.settings merged over the Alanix defaults.";
    };

    expose = serviceExposure.mkOptions {
      serviceName = "radicale";
      serviceDescription = "Radicale";
      defaultPublicPort = 80;
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions =
        [
          {
            assertion = cfg.users != { };
            message = "alanix.radicale: users must not be empty when enable = true.";
          }
          {
            assertion = hasValue cfg.listenAddress;
            message = "alanix.radicale.listenAddress must be set when alanix.radicale.enable = true.";
          }
          {
            assertion = cfg.port != null;
            message = "alanix.radicale.port must be set when alanix.radicale.enable = true.";
          }
          {
            assertion = cfg.storageDir == null || lib.hasPrefix "/" cfg.storageDir;
            message = "alanix.radicale.storageDir must be an absolute path.";
          }
          {
            assertion = cfg.backupDir == null || lib.hasPrefix "/" cfg.backupDir;
            message = "alanix.radicale.backupDir must be an absolute path when set.";
          }
          {
            assertion = !clusterCfg.enable || cfg.backupDir != null;
            message = "alanix.radicale.cluster.enable requires alanix.radicale.backupDir to be set.";
          }
        ]
        ++ (lib.mapAttrsToList (username: userCfg: {
          assertion = builtins.match "^[A-Za-z0-9._-]+$" username != null;
          message = "alanix.radicale.users.${username}: usernames may contain only letters, digits, dot, underscore, and hyphen.";
        }) cfg.users)
        ++ (lib.mapAttrsToList (username: userCfg: {
          assertion = lib.hasAttrByPath [ "sops" "secrets" userCfg.passwordSecret ] config;
          message = "alanix.radicale.users.${username}.passwordSecret must reference a declared sops secret.";
        }) cfg.users)
        ++ serviceExposure.mkAssertions {
          inherit config endpoint exposeCfg;
          optionPrefix = "alanix.radicale.expose";
        };

      sops.templates."alanix-radicale-users" = {
        content = htpasswdContent;
        owner = "radicale";
        group = "radicale";
        mode = "0400";
      };

      services.radicale = lib.mkIf baseConfigReady {
        enable = true;
        settings = lib.recursiveUpdate defaultSettings cfg.settings;
        rights = lib.recursiveUpdate defaultRights cfg.rights;
      };

      systemd.services.radicale = {
        after = [ "sops-nix.service" ];
        wants = [ "sops-nix.service" ];
      };

      systemd.tmpfiles.rules = lib.mkIf baseConfigReady [
        "d ${cfg.storageDir} 0750 radicale radicale - -"
      ];
    }

    (lib.mkIf (baseConfigReady && !clusterCfg.enable) (
      serviceExposure.mkConfig {
        inherit config endpoint exposeCfg;
        serviceName = "radicale";
        serviceDescription = "Radicale";
      }
    ))
  ]);
}
