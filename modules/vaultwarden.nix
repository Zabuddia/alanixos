{ config, lib, pkgs, ... }:
let
  cfg = config.alanix.vaultwarden;
  serviceAccess = import ./_service-access.nix { inherit lib; };
  hasSopsSecrets = lib.hasAttrByPath [ "sops" "secrets" ] config;
  torSecretKeyPath =
    if cfg.torAccess.secretKeySecret == null then
      null
    else
      config.sops.secrets.${cfg.torAccess.secretKeySecret}.path;
  vaultwardenSettingsType =
    with lib.types;
    attrsOf (
      nullOr (
        oneOf [
          bool
          int
          str
        ]
      )
    );
in
{
  options.alanix.vaultwarden = {
    enable = lib.mkEnableOption "Vaultwarden (Alanix)";

    active = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether this node actively runs the Vaultwarden service.";
    };

    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8222;
    };

    inherit (serviceAccess.mkBackendFirewallOptions {
      serviceTitle = "Vaultwarden";
      defaultOpenFirewall = false;
    })
      openFirewall
      firewallInterfaces;

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/vaultwarden";
      description = "Vaultwarden data directory (must be under /var/lib).";
    };

    uid = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.positive;
      default = null;
      description = "Pinned UID for the vaultwarden system user. Set with gid for multi-node consistency.";
    };

    gid = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.positive;
      default = null;
      description = "Pinned GID for the vaultwarden system group. Set with uid for multi-node consistency.";
    };

    dbBackend = lib.mkOption {
      type = lib.types.enum [
        "sqlite"
        "mysql"
        "postgresql"
      ];
      default = "sqlite";
      description = "Vaultwarden database backend.";
    };

    settings = lib.mkOption {
      type = vaultwardenSettingsType;
      default = {};
      description = "Additional Vaultwarden environment-style settings.";
    };

    adminTokenSecret = lib.mkOption {
      type = lib.types.str;
      default = "vaultwarden/admin-token";
      description = ''
        Required sops secret path containing raw ADMIN_TOKEN value for Vaultwarden admin access.
      '';
    };

    wanAccess = serviceAccess.mkWanAccessOptions { serviceTitle = "Vaultwarden"; };

    wireguardAccess = serviceAccess.mkWireguardAccessOptions {
      serviceTitle = "Vaultwarden";
      defaultPort = 8091;
      defaultInterface = "wg0";
    };

    torAccess = serviceAccess.mkTorAccessOptions {
      serviceTitle = "Vaultwarden";
      defaultServiceName = "vaultwarden";
      defaultHttpLocalPort = 18222;
      defaultHttpsLocalPort = 18643;
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = hasSopsSecrets;
        message = "alanix.vaultwarden.adminTokenSecret requires sops-nix configuration.";
      }
      {
        assertion = builtins.hasAttr cfg.adminTokenSecret config.sops.secrets;
        message = "alanix.vaultwarden.adminTokenSecret is set but no matching sops.secrets entry exists.";
      }
      {
        assertion = (cfg.uid == null) == (cfg.gid == null);
        message = "alanix.vaultwarden.uid and alanix.vaultwarden.gid must either both be set or both be null.";
      }
      {
        assertion = lib.hasPrefix "/var/lib/" cfg.stateDir;
        message = "alanix.vaultwarden.stateDir must be under /var/lib/ so systemd StateDirectory protections keep working.";
      }
    ] ++ serviceAccess.mkAccessAssertions {
      inherit cfg hasSopsSecrets;
      modulePathPrefix = "alanix.vaultwarden";
    };

    networking.firewall = serviceAccess.mkAccessFirewallConfig { inherit cfg; };

    services.vaultwarden = {
      enable = true;
      dbBackend = cfg.dbBackend;
      backupDir = null;
      configureNginx = false;
      configurePostgres = false;
      environmentFile = [ "/run/alanix-vaultwarden/admin-token.env" ];
      config = {
        ROCKET_ADDRESS = cfg.listenAddress;
        ROCKET_PORT = cfg.port;
        DATA_FOLDER = cfg.stateDir;
        WEBSOCKET_ENABLED = true;
      } // cfg.settings;
    };

    systemd.services.vaultwarden = {
      wantedBy = lib.mkIf (!cfg.active) (lib.mkForce []);
      serviceConfig.StateDirectory = lib.mkForce (lib.removePrefix "/var/lib/" cfg.stateDir);
    };

    systemd.services.vaultwarden-admin-token-env = {
      description = "Prepare Vaultwarden ADMIN_TOKEN environment file";
      before = [ "vaultwarden.service" ];
      requiredBy = [ "vaultwarden.service" ];
      after = [ "sops-install-secrets.service" ];
      wants = [ "sops-install-secrets.service" ];
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        Group = "root";
        RuntimeDirectory = "alanix-vaultwarden";
        RuntimeDirectoryMode = "0700";
        RuntimeDirectoryPreserve = "yes";
      };
      path = [ pkgs.coreutils ];
      script = ''
        set -euo pipefail

        TOKEN_PATH=${lib.escapeShellArg config.sops.secrets.${cfg.adminTokenSecret}.path}
        ENV_PATH=/run/alanix-vaultwarden/admin-token.env
        TOKEN="$(tr -d '\r\n' < "$TOKEN_PATH")"

        if [ -z "$TOKEN" ]; then
          echo "Vaultwarden admin token is empty in $TOKEN_PATH" >&2
          exit 1
        fi

        umask 077
        printf 'ADMIN_TOKEN=%s\n' "$TOKEN" > "$ENV_PATH"
      '';
    };

    users.groups.vaultwarden = lib.mkMerge [
      {}
      (lib.mkIf (cfg.gid != null) { gid = cfg.gid; })
    ];
    users.users.vaultwarden = lib.mkMerge [
      {}
      (lib.mkIf (cfg.uid != null) { uid = cfg.uid; })
    ];

    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0700 vaultwarden vaultwarden - -"
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
