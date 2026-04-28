{ config, lib, pkgs, ... }:
let
  cfg = config.alanix.owntracks;
  clusterCfg = cfg.cluster;
  mqttCfg = cfg.mqtt;
  recorderCfg = cfg.recorder;
  exposeCfg = recorderCfg.expose;

  serviceExposure = import ../../lib/mkServiceExposure.nix { inherit lib pkgs; };
  passwordUsers = import ../../lib/mkPlaintextPasswordUsers.nix { inherit lib; };

  inherit (passwordUsers) hasValue;

  endpoint = {
    address = recorderCfg.listenAddress;
    port = recorderCfg.port;
    protocol = "http";
  };

  recorderPackage = pkgs.owntracks-recorder;
  mosquittoDataDir = "/var/lib/mosquitto";
  recorderInternalPasswordSecret = "owntracks-passwords/recorder-internal";
  recorderEnvironmentTemplateName = "alanix-owntracks-recorder-environment";
  recorderStoreDir = "${recorderCfg.stateDir}/store";
  recorderTopic = "${cfg.topicRoot}/#";
  declaredUsernames = builtins.attrNames cfg.users;
  viewerUsernames = builtins.filter (username: cfg.users.${username}.recorderViewer) declaredUsernames;
  secretPathOrNull =
    secretName:
    if lib.hasAttrByPath [ "sops" "secrets" secretName "path" ] config then
      config.sops.secrets.${secretName}.path
    else
      null;
  placeholderOrEmpty =
    secretName:
    if lib.hasAttrByPath [ "sops" "placeholder" secretName ] config then
      config.sops.placeholder.${secretName}
    else
      "";

  mqttAcmeDirectory =
    if hasValue mqttCfg.domain then
      config.security.acme.certs.${mqttCfg.domain}.directory
    else
      null;

  clusterRecorderExposureEnabled =
    clusterCfg.enable
    && (
      exposeCfg.wan.enable
      || exposeCfg.tailscale.enable
      || exposeCfg.wireguard.enable
      || exposeCfg.tor.enable
    );

  baseConfigReady =
    hasValue recorderCfg.listenAddress
    && recorderCfg.port != null
    && lib.hasPrefix "/" recorderCfg.stateDir
    && hasValue mqttCfg.domain
    && mqttCfg.publicPort != null
    && hasValue mqttCfg.internalAddress
    && mqttCfg.internalPort != null
    && hasValue mqttCfg.acme.dnsProvider;

  mqttPasswordSourceForUser =
    userCfg:
    lib.optionalAttrs (userCfg.password != null) {
      password = userCfg.password;
    }
    // lib.optionalAttrs (userCfg.passwordFile != null) {
      passwordFile = userCfg.passwordFile;
    }
    // lib.optionalAttrs (userCfg.passwordSecret != null) {
      passwordFile = secretPathOrNull userCfg.passwordSecret;
    };

  publicMqttUsers =
    lib.mapAttrs
      (username: userCfg:
        (mqttPasswordSourceForUser userCfg)
        // {
          acl = [
            "read ${cfg.topicRoot}/#"
            "write ${cfg.topicRoot}/${username}/#"
          ];
        })
      cfg.users;

  recorderMqttUser = {
    recorder-internal = {
      passwordFile = secretPathOrNull recorderInternalPasswordSecret;
      acl = [ "read ${cfg.topicRoot}/#" ];
    };
  };

  recorderStartScript = pkgs.writeShellScript "alanix-owntracks-recorder-start" ''
    exec ${recorderPackage}/bin/ot-recorder \
      --storage ${lib.escapeShellArg recorderStoreDir} \
      --http-host ${lib.escapeShellArg recorderCfg.listenAddress} \
      --http-port ${lib.escapeShellArg (toString recorderCfg.port)} \
      --doc-root ${lib.escapeShellArg "${recorderPackage}/htdocs"} \
      --viewsdir ${lib.escapeShellArg "${recorderPackage}/htdocs/views"} \
      ${lib.escapeShellArg recorderTopic}
  '';

  recorderInitializeScript = pkgs.writeShellScript "alanix-owntracks-recorder-initialize" ''
    exec ${recorderPackage}/bin/ot-recorder \
      --initialize \
      --storage ${lib.escapeShellArg recorderStoreDir} \
      ${lib.escapeShellArg recorderTopic}
  '';
in
{
  options.alanix.owntracks = {
    enable = lib.mkEnableOption "OwnTracks MQTT + Recorder (Alanix)";

    topicRoot = lib.mkOption {
      type = lib.types.str;
      default = "owntracks";
      description = "MQTT topic root used by OwnTracks clients and Recorder subscriptions.";
    };

    backupDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "/var/backup/owntracks";
      description = "Cluster backup staging directory for OwnTracks state.";
    };

    mqtt = {
      domain = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Public MQTT hostname used for the TLS listener.";
      };

      publicPort = lib.mkOption {
        type = lib.types.port;
        default = 8883;
      };

      internalAddress = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
      };

      internalPort = lib.mkOption {
        type = lib.types.port;
        default = 1883;
      };

      acme = {
        dnsProvider = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "DNS provider for the ACME DNS-01 challenge (e.g. \"cloudflare\").";
        };

        credentialsFile = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          description = "Path to an environment file with credentials for the ACME DNS provider.";
        };
      };
    };

    recorder = {
      listenAddress = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = "127.0.0.1";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 8083;
      };

      stateDir = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/owntracks-recorder";
      };

      expose = serviceExposure.mkOptions {
        serviceName = "owntracks";
        serviceDescription = "OwnTracks Recorder";
        defaultPublicPort = 80;
      };
    };

    cluster = {
      enable = lib.mkEnableOption "cluster-manage OwnTracks through alanix.cluster";

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
      type = lib.types.attrsOf (lib.types.submodule ({ ... }: {
        options = passwordUsers.mkOptions {
          passwordFileDescription = "Path to a file containing the plaintext MQTT password.";
          passwordSecretDescription = "Name of a sops secret containing the plaintext MQTT password.";
          extraOptions = {
            recorderViewer = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Whether this user should be allowed into the Recorder web UI.";
            };
          };
        };
      }));
      default = { };
      description = "Declarative OwnTracks MQTT users.";
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions =
        [
          {
            assertion = cfg.users != { };
            message = "alanix.owntracks: users must not be empty when enable = true.";
          }
          {
            assertion = cfg.backupDir == null || lib.hasPrefix "/" cfg.backupDir;
            message = "alanix.owntracks.backupDir must be an absolute path when set.";
          }
          {
            assertion = lib.hasPrefix "/" recorderCfg.stateDir;
            message = "alanix.owntracks.recorder.stateDir must be an absolute path.";
          }
          {
            assertion = hasValue recorderCfg.listenAddress;
            message = "alanix.owntracks.recorder.listenAddress must be set when alanix.owntracks.enable = true.";
          }
          {
            assertion = recorderCfg.port != null;
            message = "alanix.owntracks.recorder.port must be set when alanix.owntracks.enable = true.";
          }
          {
            assertion = hasValue mqttCfg.domain;
            message = "alanix.owntracks.mqtt.domain must be set when alanix.owntracks.enable = true.";
          }
          {
            assertion = !clusterCfg.enable || cfg.backupDir != null;
            message = "alanix.owntracks.cluster.enable requires alanix.owntracks.backupDir to be set.";
          }
          {
            assertion = lib.hasAttrByPath [ "sops" "secrets" recorderInternalPasswordSecret ] config;
            message = "alanix.owntracks requires the `${recorderInternalPasswordSecret}` sops secret to be declared.";
          }
          {
            assertion = hasValue mqttCfg.acme.dnsProvider;
            message = "alanix.owntracks.mqtt.acme.dnsProvider must be set when alanix.owntracks.enable = true.";
          }
          {
            assertion = mqttCfg.acme.credentialsFile != null;
            message = "alanix.owntracks.mqtt.acme.credentialsFile must be set when alanix.owntracks.enable = true.";
          }
          {
            assertion = !clusterRecorderExposureEnabled || viewerUsernames != [ ];
            message = "alanix.owntracks requires at least one users.*.recorderViewer = true when Recorder exposure is enabled in cluster mode.";
          }
        ]
        ++ serviceExposure.mkAssertions {
          inherit config endpoint exposeCfg;
          optionPrefix = "alanix.owntracks.recorder.expose";
        }
        ++ passwordUsers.mkAssertions {
          inherit config;
          users = cfg.users;
          usernamePattern = "^[A-Za-z0-9._-]+$";
          usernameMessage = username: "alanix.owntracks.users.${username}: usernames may contain only letters, digits, dot, underscore, and hyphen.";
          passwordSourceMessage = username: "alanix.owntracks.users.${username}: set exactly one of password, passwordFile, or passwordSecret.";
          passwordSecretMessage = username: "alanix.owntracks.users.${username}.passwordSecret must reference a declared sops secret.";
          extraAssertions =
            username: userCfg:
            [
              {
                assertion = !userCfg.recorderViewer || userCfg.password == null;
                message = "alanix.owntracks.users.${username}: recorderViewer users must use passwordFile or passwordSecret, not inline password.";
              }
            ];
        };

      security.acme.acceptTerms = lib.mkDefault true;
      security.acme.certs = lib.mkIf baseConfigReady {
        ${mqttCfg.domain} = {
          domain = mqttCfg.domain;
          dnsProvider = mqttCfg.acme.dnsProvider;
          environmentFile = mqttCfg.acme.credentialsFile;
          group = "mosquitto";
          reloadServices = [ "mosquitto.service" ];
        };
      };

      sops.templates.${recorderEnvironmentTemplateName} = lib.mkIf baseConfigReady {
        content = ''
          OTR_STORAGEDIR=${recorderStoreDir}
          OTR_HOST=${mqttCfg.internalAddress}
          OTR_PORT=${toString mqttCfg.internalPort}
          OTR_USER=recorder-internal
          OTR_PASS=${placeholderOrEmpty recorderInternalPasswordSecret}
          OTR_HTTPHOST=${recorderCfg.listenAddress}
          OTR_HTTPPORT=${toString recorderCfg.port}
          OTR_DOCROOT=${recorderPackage}/htdocs
          OTR_VIEWSDIR=${recorderPackage}/htdocs/views
        '';
        owner = "owntracks";
        group = "owntracks";
        mode = "0400";
      };

      services.mosquitto = lib.mkIf baseConfigReady {
        enable = true;
        persistence = true;
        dataDir = mosquittoDataDir;
        settings = {
          autosave_interval = 60;
          autosave_on_changes = true;
        };
        listeners = [
          {
            port = mqttCfg.publicPort;
            address = "0.0.0.0";
            users = publicMqttUsers;
            settings = {
              allow_anonymous = false;
              certfile = "${mqttAcmeDirectory}/fullchain.pem";
              keyfile = "${mqttAcmeDirectory}/key.pem";
              tls_version = "tlsv1.2";
            };
          }
          {
            port = mqttCfg.internalPort;
            address = mqttCfg.internalAddress;
            users = recorderMqttUser;
            settings = {
              allow_anonymous = false;
            };
          }
        ];
      };

      users.groups.owntracks = { };
      users.users.owntracks = {
        isSystemUser = true;
        group = "owntracks";
        home = recorderCfg.stateDir;
        createHome = true;
      };

      systemd.tmpfiles.rules = lib.mkIf baseConfigReady [
        "d ${recorderCfg.stateDir} 0750 owntracks owntracks - -"
        "d ${recorderStoreDir} 0750 owntracks owntracks - -"
      ];

      systemd.services.ot-recorder = lib.mkIf baseConfigReady {
        description = "OwnTracks Recorder";
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" "mosquitto.service" "sops-nix.service" ];
        wants = [ "network-online.target" "mosquitto.service" "sops-nix.service" ];
        requires = [ "mosquitto.service" ];
        path = [ pkgs.coreutils recorderPackage ];
        restartTriggers = [
          (builtins.toJSON {
            inherit (cfg) topicRoot backupDir;
            mqtt = {
              inherit (mqttCfg) domain publicPort internalAddress internalPort;
            };
            recorder = {
              inherit (recorderCfg) listenAddress port stateDir;
            };
            users =
              lib.mapAttrs
                (_: userCfg: {
                  recorderViewer = userCfg.recorderViewer;
                  passwordFile =
                    if userCfg.passwordFile == null then
                      null
                    else
                      toString userCfg.passwordFile;
                  passwordSecret = userCfg.passwordSecret;
                })
                cfg.users;
          })
        ];
        serviceConfig = {
          Type = "simple";
          User = "owntracks";
          Group = "owntracks";
          WorkingDirectory = recorderCfg.stateDir;
          UMask = "0027";
          EnvironmentFile = config.sops.templates.${recorderEnvironmentTemplateName}.path;
          ExecStartPre = recorderInitializeScript;
          ExecStart = recorderStartScript;
          Restart = "on-failure";
          RestartSec = "5s";
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          ReadWritePaths = [ recorderCfg.stateDir ];
        };
      };

      environment.systemPackages = [ recorderPackage ];
    }

    (lib.mkIf (!clusterCfg.enable) {
      networking.firewall.allowedTCPPorts = [ mqttCfg.publicPort ];
    })

    (lib.mkIf (baseConfigReady && !clusterCfg.enable) (
      serviceExposure.mkConfig {
        inherit config endpoint exposeCfg;
        serviceName = "owntracks";
        serviceDescription = "OwnTracks Recorder";
      }
    ))
  ]);
}
