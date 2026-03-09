{ config, lib, pkgs, ... }:
let
  cfg = config.alanix.immich;
  serviceAccess = import ./_service-access.nix { inherit lib; };
  hasSopsSecrets = lib.hasAttrByPath [ "sops" "secrets" ] config;
  torSecretKeyPath =
    if cfg.torAccess.secretKeySecret == null then
      null
    else
      config.sops.secrets.${cfg.torAccess.secretKeySecret}.path;
  dbPasswordFile =
    if cfg.database.passwordSecret == null || !hasSopsSecrets then
      null
    else
      config.sops.secrets.${cfg.database.passwordSecret}.path;
  dbPasswordEnvFile = "/run/alanix-immich/database.env";
  effectiveDatabaseHost =
    if cfg.database.host == null then
      "/run/postgresql"
    else
      cfg.database.host;
  isTcpDatabaseHost = !(lib.hasPrefix "/" effectiveDatabaseHost);
in
{
  options.alanix.immich = {
    enable = lib.mkEnableOption "Immich (Alanix)";

    active = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether this node actively runs the Immich service.";
    };

    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 2283;
    };

    inherit (serviceAccess.mkBackendFirewallOptions {
      serviceTitle = "Immich";
      defaultOpenFirewall = false;
    })
      openFirewall
      firewallInterfaces;

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/immich";
      description = "Immich media directory (must be under /var/lib).";
    };

    uid = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.positive;
      default = null;
      description = "Pinned UID for the immich system user. Set with gid for multi-node consistency.";
    };

    gid = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.positive;
      default = null;
      description = "Pinned GID for the immich system group. Set with uid for multi-node consistency.";
    };

    settings = lib.mkOption {
      type = lib.types.nullOr lib.types.attrs;
      default = null;
      description = "Immich settings JSON (null leaves settings editable in web UI).";
    };

    environment = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = "Extra Immich environment variables.";
    };

    accelerationDevices = lib.mkOption {
      type = lib.types.nullOr (lib.types.listOf lib.types.str);
      default = [ ];
      description = "Acceleration devices passed through to Immich (for example /dev/dri/renderD128).";
    };

    database = {
      createLocally = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to run and initialize local PostgreSQL for Immich.";
      };

      host = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Database host. null means local unix socket at /run/postgresql.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 5432;
      };

      name = lib.mkOption {
        type = lib.types.str;
        default = "immich";
      };

      user = lib.mkOption {
        type = lib.types.str;
        default = "immich";
      };

      enableVectorChord = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable VectorChord extension for Immich vectors.";
      };

      enableVectors = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable legacy pgvecto.rs extension.";
      };

      passwordSecret = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional sops secret containing DB_PASSWORD for Immich.";
      };
    };

    redis = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };

      host = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional Redis host override (null uses module default unix socket).";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 0;
      };
    };

    machineLearning = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };

      environment = lib.mkOption {
        type = lib.types.attrs;
        default = { };
      };
    };

    wanAccess = serviceAccess.mkWanAccessOptions { serviceTitle = "Immich"; };

    wireguardAccess = serviceAccess.mkWireguardAccessOptions {
      serviceTitle = "Immich";
      defaultPort = 8093;
      defaultInterface = "wg0";
    };

    torAccess = serviceAccess.mkTorAccessOptions {
      serviceTitle = "Immich";
      defaultServiceName = "immich";
      defaultHttpLocalPort = 18283;
      defaultHttpsLocalPort = 18683;
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = (cfg.uid == null) == (cfg.gid == null);
        message = "alanix.immich.uid and alanix.immich.gid must either both be set or both be null.";
      }
      {
        assertion = lib.hasPrefix "/var/lib/" cfg.stateDir;
        message = "alanix.immich.stateDir must be under /var/lib/.";
      }
      {
        assertion = !(cfg.database.passwordSecret != null && !hasSopsSecrets);
        message = "alanix.immich.database.passwordSecret requires sops-nix configuration.";
      }
      {
        assertion = !(isTcpDatabaseHost && cfg.database.passwordSecret == null);
        message = "alanix.immich.database.passwordSecret must be set when database.host is TCP (non-socket).";
      }
    ] ++ serviceAccess.mkAccessAssertions {
      inherit cfg hasSopsSecrets;
      modulePathPrefix = "alanix.immich";
    };

    networking.firewall = serviceAccess.mkAccessFirewallConfig { inherit cfg; };

    sops.secrets = lib.mkIf (hasSopsSecrets && cfg.database.passwordSecret != null) {
      "${cfg.database.passwordSecret}" = {
        restartUnits = [
          "immich-db-password-env.service"
          "immich-server.service"
        ];
      };
    };

    systemd.services.immich-db-password-env = lib.mkIf (cfg.database.passwordSecret != null) {
      description = "Prepare Immich DB_PASSWORD environment file";
      before = [ "immich-server.service" ];
      requiredBy = [ "immich-server.service" ];
      after = [ "sops-install-secrets.service" ];
      wants = [ "sops-install-secrets.service" ];
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        Group = "root";
        RuntimeDirectory = "alanix-immich";
        RuntimeDirectoryMode = "0700";
        RuntimeDirectoryPreserve = "yes";
      };
      path = [ pkgs.coreutils ];
      script = ''
        set -euo pipefail

        SECRET_PATH=${lib.escapeShellArg dbPasswordFile}
        OUT_PATH=${lib.escapeShellArg dbPasswordEnvFile}
        DB_PASSWORD="$(tr -d '\r\n' < "$SECRET_PATH")"

        if [ -z "$DB_PASSWORD" ]; then
          echo "Immich DB password secret is empty: $SECRET_PATH" >&2
          exit 1
        fi

        umask 077
        printf 'DB_PASSWORD=%s\n' "$DB_PASSWORD" > "$OUT_PATH"
      '';
    };

    services.immich = {
      enable = true;
      host = cfg.listenAddress;
      port = cfg.port;
      openFirewall = false;
      mediaLocation = cfg.stateDir;
      settings = cfg.settings;
      environment = cfg.environment;
      accelerationDevices = cfg.accelerationDevices;
      database = {
        enable = cfg.database.createLocally;
        createDB = cfg.database.createLocally;
        host = effectiveDatabaseHost;
        port = cfg.database.port;
        name = cfg.database.name;
        user = cfg.database.user;
        enableVectorChord = cfg.database.enableVectorChord;
        enableVectors = cfg.database.enableVectors;
      };
      redis = {
        enable = cfg.redis.enable;
        port = cfg.redis.port;
      } // lib.optionalAttrs (cfg.redis.host != null) {
        host = cfg.redis.host;
      };
      machine-learning = {
        enable = cfg.machineLearning.enable;
        environment = cfg.machineLearning.environment;
      };
      secretsFile = if cfg.database.passwordSecret == null then null else dbPasswordEnvFile;
    };

    systemd.services.immich-server = {
      wantedBy = lib.mkIf (!cfg.active) (lib.mkForce []);
      wants = lib.mkIf cfg.machineLearning.enable (lib.mkAfter [ "immich-machine-learning.service" ]);
    };

    systemd.services.immich-machine-learning = lib.mkIf cfg.machineLearning.enable {
      partOf = [ "immich-server.service" ];
      wantedBy = lib.mkIf (!cfg.active) (lib.mkForce []);
    };

    users.groups.immich = lib.mkMerge [
      { }
      (lib.mkIf (cfg.gid != null) { gid = cfg.gid; })
    ];
    users.users.immich = lib.mkMerge [
      { }
      (lib.mkIf (cfg.uid != null) { uid = cfg.uid; })
    ];

    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0700 immich immich - -"
    ];

    services.caddy = serviceAccess.mkAccessCaddyConfig {
      inherit cfg;
      upstreamPort = cfg.port;
    };

    services.tor = serviceAccess.mkTorConfig {
      inherit cfg torSecretKeyPath;
    };
  };
}
