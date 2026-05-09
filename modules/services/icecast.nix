{ config, lib, pkgs, ... }:
let
  cfg = config.alanix.icecast;
  serviceExposure = import ../../lib/mkServiceExposure.nix { inherit lib pkgs; };

  endpoint = {
    address = cfg.listenAddress;
    port = cfg.port;
    protocol = "http";
  };

  hasValue = value: value != null && value != "";
  xmlEscape = lib.strings.escapeXML;

  relayPasswordSecret =
    if hasValue cfg.relay.passwordSecret then cfg.relay.passwordSecret else cfg.source.passwordSecret;

  adminPasswordPlaceholder =
    if hasValue cfg.admin.passwordSecret then
      config.sops.placeholder.${cfg.admin.passwordSecret}
    else
      "__MISSING_ADMIN_PASSWORD__";

  sourcePasswordPlaceholder =
    if hasValue cfg.source.passwordSecret then
      config.sops.placeholder.${cfg.source.passwordSecret}
    else
      "__MISSING_SOURCE_PASSWORD__";

  relayPasswordPlaceholder =
    if hasValue relayPasswordSecret then
      config.sops.placeholder.${relayPasswordSecret}
    else
      "__MISSING_RELAY_PASSWORD__";

  configTemplateName = "alanix-icecast-config";
  restartTrigger = builtins.toJSON {
    inherit relayPasswordSecret;
    adminPasswordSecret = cfg.admin.passwordSecret;
    adminUser = cfg.admin.user;
    extraConf = cfg.extraConf;
    hostname = cfg.hostname;
    limits = cfg.limits;
    listenAddress = cfg.listenAddress;
    logDir = cfg.logDir;
    logLevel = cfg.logLevel;
    package = "${cfg.package}";
    port = cfg.port;
    sourcePasswordSecret = cfg.source.passwordSecret;
  };
in
{
  options.alanix.icecast = {
    enable = lib.mkEnableOption "Icecast (Alanix)";

    package = lib.mkPackageOption pkgs "icecast" { };

    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Address Icecast listens on locally.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8000;
      description = "HTTP port Icecast listens on locally.";
    };

    hostname = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      description = ''
        Hostname Icecast advertises in generated playlists when the incoming
        request does not already provide a Host header.
      '';
    };

    logDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/log/icecast";
      description = "Directory used for Icecast access and error logs.";
    };

    logLevel = lib.mkOption {
      type = lib.types.enum [ 1 2 3 4 ];
      default = 3;
      description = "Icecast log level: 4=debug, 3=info, 2=warn, 1=error.";
    };

    limits = {
      clients = lib.mkOption {
        type = lib.types.ints.positive;
        default = 100;
        description = "Maximum number of listener connections.";
      };

      sources = lib.mkOption {
        type = lib.types.ints.positive;
        default = 8;
        description = "Maximum number of simultaneous source connections.";
      };
    };

    admin = {
      user = lib.mkOption {
        type = lib.types.str;
        default = "admin";
        description = "Icecast admin username.";
      };

      passwordSecret = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "SOPS secret containing the Icecast admin password.";
      };
    };

    source.passwordSecret = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "SOPS secret containing the Icecast source password.";
    };

    relay.passwordSecret = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Optional SOPS secret containing the Icecast relay password. When unset,
        Alanix reuses the source password.
      '';
    };

    extraConf = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Extra XML inserted near the end of the Icecast configuration.";
    };

    expose = serviceExposure.mkOptions {
      serviceName = "icecast";
      serviceDescription = "Icecast";
      defaultPublicPort = 80;
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions =
        [
          {
            assertion = hasValue cfg.admin.passwordSecret;
            message = "alanix.icecast.admin.passwordSecret must be set when alanix.icecast.enable = true.";
          }
          {
            assertion = hasValue cfg.source.passwordSecret;
            message = "alanix.icecast.source.passwordSecret must be set when alanix.icecast.enable = true.";
          }
          {
            assertion = lib.hasPrefix "/" cfg.logDir;
            message = "alanix.icecast.logDir must be an absolute path.";
          }
          {
            assertion =
              !hasValue cfg.admin.passwordSecret
              || lib.hasAttrByPath [ "sops" "secrets" cfg.admin.passwordSecret ] config;
            message = "alanix.icecast.admin.passwordSecret must reference a declared sops secret.";
          }
          {
            assertion =
              !hasValue cfg.source.passwordSecret
              || lib.hasAttrByPath [ "sops" "secrets" cfg.source.passwordSecret ] config;
            message = "alanix.icecast.source.passwordSecret must reference a declared sops secret.";
          }
          {
            assertion =
              !hasValue cfg.relay.passwordSecret
              || lib.hasAttrByPath [ "sops" "secrets" cfg.relay.passwordSecret ] config;
            message = "alanix.icecast.relay.passwordSecret must reference a declared sops secret.";
          }
        ]
        ++ serviceExposure.mkAssertions {
          inherit config endpoint;
          exposeCfg = cfg.expose;
          optionPrefix = "alanix.icecast.expose";
        };

      users.groups.icecast = { };

      users.users.icecast = {
        isSystemUser = true;
        description = "Icecast streaming service user";
        group = "icecast";
        home = cfg.logDir;
        createHome = false;
      };

      sops.templates.${configTemplateName} = {
        content = ''
          <icecast>
            <limits>
              <clients>${toString cfg.limits.clients}</clients>
              <sources>${toString cfg.limits.sources}</sources>
            </limits>

            <authentication>
              <source-password><![CDATA[${sourcePasswordPlaceholder}]]></source-password>
              <relay-password><![CDATA[${relayPasswordPlaceholder}]]></relay-password>
              <admin-user>${xmlEscape cfg.admin.user}</admin-user>
              <admin-password><![CDATA[${adminPasswordPlaceholder}]]></admin-password>
            </authentication>

            <hostname>${xmlEscape cfg.hostname}</hostname>

            <listen-socket>
              <port>${toString cfg.port}</port>
              <bind-address>${xmlEscape cfg.listenAddress}</bind-address>
            </listen-socket>

            <fileserve>1</fileserve>

            <paths>
              <logdir>${xmlEscape cfg.logDir}</logdir>
              <adminroot>${cfg.package}/share/icecast/admin</adminroot>
              <webroot>${cfg.package}/share/icecast/web</webroot>
              <alias source="/" destination="/status.xsl"/>
            </paths>

            <logging>
              <accesslog>access.log</accesslog>
              <errorlog>error.log</errorlog>
              <loglevel>${toString cfg.logLevel}</loglevel>
            </logging>

            <http-headers>
              <header name="Access-Control-Allow-Origin" value="*" />
            </http-headers>

          ${cfg.extraConf}
          </icecast>
        '';
        owner = "icecast";
        group = "icecast";
        mode = "0400";
      };

      systemd.tmpfiles.rules = [
        "d ${cfg.logDir} 0750 icecast icecast - -"
      ];

      systemd.services.icecast = {
        description = "Icecast Network Audio Streaming Server";
        after = [
          "network-online.target"
          "sops-nix.service"
        ];
        wants = [
          "network-online.target"
          "sops-nix.service"
        ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          User = "icecast";
          Group = "icecast";
          ExecStart = "${cfg.package}/bin/icecast -c ${config.sops.templates.${configTemplateName}.path}";
          ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
          Restart = "on-failure";
          UMask = "0077";
        };
        restartTriggers = [ restartTrigger ];
      };
    }

    (serviceExposure.mkConfig {
      inherit config endpoint;
      exposeCfg = cfg.expose;
      serviceName = "icecast";
      serviceDescription = "Icecast";
    })
  ]);
}
