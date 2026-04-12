{ config, lib, pkgs, pkgs-unstable, ... }:
let
  cfg = config.alanix.searxng;
  clusterCfg = cfg.cluster;
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
  environmentFilePath = "${cfg.stateDir}/environment";
  secretKeyFilePath = "${cfg.stateDir}/secret_key";
  secretKeySourcePath = if cfg.secretKeySecret != null then config.sops.secrets.${cfg.secretKeySecret}.path else null;

  effectiveRootUrl =
    let
      derived = serviceIdentity.rootUrl {
        inherit config exposeCfg;
        listenAddress = cfg.listenAddress;
        port = cfg.port;
        rootUrlOverride = cfg.rootUrl;
      };
    in
    if derived == null then null else lib.removeSuffix "/" derived;

  defaultSettings =
    {
      use_default_settings = true;

      general = {
        instance_name = cfg.instanceName;
      };

      server =
        {
          bind_address = cfg.listenAddress;
          port = cfg.port;
          secret_key = "$SEARX_SECRET_KEY";
        }
        // lib.optionalAttrs (effectiveRootUrl != null) {
          base_url = "${effectiveRootUrl}/";
        };
    };
in
{
  options.alanix.searxng = {
    enable = lib.mkEnableOption "SearXNG (Alanix)";

    package = lib.mkPackageOption pkgs-unstable "searxng" { };

    instanceName = lib.mkOption {
      type = lib.types.str;
      default = "Alanix Search";
      description = "Human-friendly instance name shown in the SearXNG UI.";
    };

    listenAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };

    port = lib.mkOption {
      type = lib.types.nullOr lib.types.port;
      default = null;
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/searxng";
      description = "Directory used for Alanix-managed SearXNG runtime state such as the materialized secret key and environment file.";
    };

    backupDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional SearXNG cluster backup staging directory.";
    };

    cluster = {
      enable = lib.mkEnableOption "cluster-manage SearXNG through alanix.cluster";

      backupInterval = lib.mkOption {
        type = lib.types.str;
        default = "15m";
      };

      maxBackupAge = lib.mkOption {
        type = lib.types.str;
        default = "1h";
      };
    };

    secretKeySecret = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional sops secret whose contents become the SearXNG secret key.";
    };

    rootUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional public SearXNG root URL, including http:// or https://.";
    };

    settings = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = "Extra services.searx.settings merged on top of the Alanix defaults.";
    };

    expose = serviceExposure.mkOptions {
      serviceName = "searxng";
      serviceDescription = "SearXNG";
      defaultPublicPort = 80;
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions =
        [
          {
            assertion = hasValue cfg.listenAddress;
            message = "alanix.searxng.listenAddress must be set when alanix.searxng.enable = true.";
          }
          {
            assertion = cfg.port != null;
            message = "alanix.searxng.port must be set when alanix.searxng.enable = true.";
          }
          {
            assertion = lib.hasPrefix "/" cfg.stateDir;
            message = "alanix.searxng.stateDir must be an absolute path.";
          }
          {
            assertion = cfg.backupDir == null || lib.hasPrefix "/" cfg.backupDir;
            message = "alanix.searxng.backupDir must be an absolute path when set.";
          }
          {
            assertion = cfg.rootUrl == null || builtins.match "^https?://.+" cfg.rootUrl != null;
            message = "alanix.searxng.rootUrl must include http:// or https:// when set.";
          }
          {
            assertion = cfg.secretKeySecret == null || lib.hasAttrByPath [ "sops" "secrets" cfg.secretKeySecret ] config;
            message = "alanix.searxng.secretKeySecret must reference a declared sops secret.";
          }
          {
            assertion = !clusterCfg.enable || cfg.secretKeySecret != null;
            message = "alanix.searxng.cluster.enable requires alanix.searxng.secretKeySecret.";
          }
        ]
        ++ serviceExposure.mkAssertions {
          inherit config endpoint exposeCfg;
          optionPrefix = "alanix.searxng.expose";
        };

      services.searx = lib.mkIf baseConfigReady {
        enable = true;
        package = cfg.package;
        environmentFile = environmentFilePath;
        configureUwsgi = false;
        configureNginx = false;
        redisCreateLocally = false;
        settings = lib.recursiveUpdate defaultSettings cfg.settings;
      };

      systemd.tmpfiles.rules = lib.mkIf baseConfigReady [
        "d ${cfg.stateDir} 0750 searx searx - -"
      ];

      systemd.services."alanix-searxng-prepare" = lib.mkIf baseConfigReady {
        description = "Prepare Alanix SearXNG runtime environment";
        after = [ "systemd-tmpfiles-setup.service" ];
        wants = [ "systemd-tmpfiles-setup.service" ];
        before = [ "searx-init.service" "searx.service" ];

        serviceConfig = {
          Type = "oneshot";
          User = "root";
          Group = "root";
          UMask = "0077";
          SuccessExitStatus = [ "SIGTERM" ];
        };

        path = [ pkgs.coreutils pkgs.openssl ];

        script = ''
          set -euo pipefail

          if [ -n ${lib.escapeShellArg (if secretKeySourcePath != null then secretKeySourcePath else "")} ]; then
            install -m 0400 ${lib.escapeShellArg (if secretKeySourcePath != null then secretKeySourcePath else "/dev/null")} ${lib.escapeShellArg secretKeyFilePath}
          elif [ ! -s ${lib.escapeShellArg secretKeyFilePath} ]; then
            tmp_secret="$(mktemp ${lib.escapeShellArg "${cfg.stateDir}/secret_key.XXXXXX"})"
            openssl rand -hex 32 > "$tmp_secret"
            install -m 0400 "$tmp_secret" ${lib.escapeShellArg secretKeyFilePath}
            rm -f "$tmp_secret"
          fi

          secret_key="$(tr -d '\n' < ${lib.escapeShellArg secretKeyFilePath})"

          tmp_environment="$(mktemp ${lib.escapeShellArg "${cfg.stateDir}/environment.XXXXXX"})"
          cat > "$tmp_environment" <<EOF
          SEARX_SECRET_KEY=$secret_key
          EOF
          install -m 0400 "$tmp_environment" ${lib.escapeShellArg environmentFilePath}
          rm -f "$tmp_environment"
        '';
      };

      systemd.services.searx-init = lib.mkIf baseConfigReady {
        after = [ "alanix-searxng-prepare.service" ];
        requires = [ "alanix-searxng-prepare.service" ];
      };
    }

    (lib.mkIf (baseConfigReady && !clusterCfg.enable) (
      serviceExposure.mkConfig {
        inherit config endpoint exposeCfg;
        serviceName = "searxng";
        serviceDescription = "SearXNG";
      }
    ))
  ]);
}
