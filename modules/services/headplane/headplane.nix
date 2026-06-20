{ config, lib, pkgs, ... }:

let
  cfg = config.alanix.headplane;
  clusterCfg = cfg.cluster;
  secretFiles = import ../../../secrets/files.nix;
  serviceExposure = import ../../../lib/mkServiceExposure.nix { inherit lib pkgs; };
  serviceIdentity = import ../../../lib/mkServiceIdentity.nix { inherit lib; };

  patchedPackage = cfg.package.overrideAttrs (oldAttrs: {
    patches = (oldAttrs.patches or [ ]) ++ [ ./ui-compat.patch ];
  });

  exposeCfg = cfg.expose;
  inherit (serviceIdentity) hasValue;

  endpoint = {
    address = cfg.listenAddress;
    port = cfg.port;
    protocol = "http";
  };

  effectiveBaseUrl =
    let
      derived = serviceIdentity.rootUrl {
        inherit config exposeCfg;
        listenAddress = cfg.listenAddress;
        port = cfg.port;
        rootUrlOverride = cfg.baseUrl;
      };
    in
    if derived == null then null else lib.removeSuffix "/" derived;

  defaultSettings = {
    server = {
      host = cfg.listenAddress;
      port = cfg.port;
      base_url = effectiveBaseUrl;
      cookie_secret_path = config.sops.secrets.${cfg.cookieSecretSecret}.path;
      cookie_secure = cfg.cookieSecure;
      data_path = cfg.stateDir;
    };

    headscale = {
      url = cfg.headscaleUrl;
      public_url = cfg.headscalePublicUrl;
      config_path = config.services.headscale.configFile;
      config_strict = false;
    };

    integration.proc.enabled = cfg.procIntegration;
  };
in
{
  options.alanix.headplane = {
    enable = lib.mkEnableOption "Headplane web UI for Headscale";

    package = lib.mkPackageOption pkgs "headplane" { };

    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Local Headplane HTTP listen address.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 3000;
      description = "Local Headplane HTTP listen port.";
    };

    baseUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Public Headplane base URL, without the /admin prefix.";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/headplane";
      description = "Headplane state directory containing its internal database and cache.";
    };

    backupDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Cluster backup staging directory. Required when cluster.enable = true.";
    };

    cookieSecretSecret = lib.mkOption {
      type = lib.types.str;
      default = "headplane/cookie-secret";
      description = "SOPS secret containing Headplane's 32-character cookie secret.";
    };

    cookieSecure = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether Headplane should mark cookies as HTTPS-only.";
    };

    headscaleUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://${config.alanix.headscale.listenAddress}:${toString config.alanix.headscale.port}";
      defaultText = "http://\${config.alanix.headscale.listenAddress}:\${toString config.alanix.headscale.port}";
      description = "Internal HTTP URL Headplane uses to reach Headscale.";
    };

    headscalePublicUrl = lib.mkOption {
      type = lib.types.str;
      default = config.alanix.headscale.serverUrl;
      defaultText = "config.alanix.headscale.serverUrl";
      description = "Public Headscale URL shown by Headplane.";
    };

    procIntegration = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether Headplane may use native process integration with the local Headscale service.";
    };

    settings = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = "Extra services.headplane.settings merged on top of the Alanix defaults.";
    };

    expose = serviceExposure.mkOptions {
      serviceName = "headplane";
      serviceDescription = "Headplane";
      defaultPublicPort = 443;
    };

    cluster = {
      enable = lib.mkEnableOption "cluster-managed Headplane";

      backupInterval = lib.mkOption {
        type = lib.types.str;
        default = "15m";
        description = "How often the cluster leader backs up Headplane state.";
      };

      maxBackupAge = lib.mkOption {
        type = lib.types.str;
        default = "2h";
        description = "Maximum acceptable age of a Headplane backup for normal failover.";
      };
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions = [
        {
          assertion = config.alanix.headscale.enable;
          message = "alanix.headplane.enable requires alanix.headscale.enable = true.";
        }
        {
          assertion = hasValue cfg.listenAddress;
          message = "alanix.headplane.listenAddress must be set when alanix.headplane.enable = true.";
        }
        {
          assertion = lib.hasPrefix "/" cfg.stateDir;
          message = "alanix.headplane.stateDir must be an absolute path.";
        }
        {
          assertion = cfg.backupDir == null || lib.hasPrefix "/" cfg.backupDir;
          message = "alanix.headplane.backupDir must be an absolute path when set.";
        }
        {
          assertion = !clusterCfg.enable || cfg.backupDir != null;
          message = "alanix.headplane.cluster.enable requires alanix.headplane.backupDir to be set.";
        }
        {
          assertion = cfg.baseUrl == null || builtins.match "^https?://.+" cfg.baseUrl != null;
          message = "alanix.headplane.baseUrl must include http:// or https:// when set.";
        }
      ] ++ serviceExposure.mkAssertions {
        inherit config endpoint exposeCfg;
        optionPrefix = "alanix.headplane.expose";
      };

      sops.secrets.${cfg.cookieSecretSecret} = {
        sopsFile = secretFiles.servicePasswords;
        owner = config.services.headscale.user;
        group = config.services.headscale.group;
        mode = "0400";
      };

      services.headplane = {
        enable = true;
        package = patchedPackage;
        settings = lib.recursiveUpdate defaultSettings cfg.settings;
      };
    }

    (lib.mkIf (!clusterCfg.enable) (
      serviceExposure.mkConfig {
        inherit config endpoint exposeCfg;
        serviceName = "headplane";
        serviceDescription = "Headplane";
      }
    ))
  ]);
}
