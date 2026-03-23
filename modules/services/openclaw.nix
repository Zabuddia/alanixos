{ config, lib, pkgs, ... }:

let
  cfg = config.alanix.openclaw;
  types = lib.types;

  openclawEnabled = cfg.gateway.enable || cfg.desktopNode.enable;

  openclawUser =
    if cfg.user != null then
      lib.attrByPath [ "alanix" "users" "accounts" cfg.user ] null config
    else
      null;

  openclawUserHomeReady = openclawUser != null && openclawUser.enable && openclawUser.home.enable;
  openclawHomeDir = if openclawUserHomeReady then openclawUser.home.directory else null;

  npmPrefixDir =
    if openclawHomeDir == null then
      null
    else if lib.hasPrefix "/" cfg.npmPrefix then
      cfg.npmPrefix
    else
      "${openclawHomeDir}/${cfg.npmPrefix}";

  npmBinDir = if npmPrefixDir != null then "${npmPrefixDir}/bin" else null;
  openclawBin = if npmBinDir != null then "${npmBinDir}/openclaw" else null;

  desktopNodeGatewayHost =
    if cfg.desktopNode.gatewayHost != null then
      cfg.desktopNode.gatewayHost
    else
      "127.0.0.1";

  servicePath = lib.makeBinPath (
    [
      pkgs.bash
      pkgs.coreutils
      pkgs.nodejs
    ]
    ++ lib.optionals config.services.tailscale.enable [ config.services.tailscale.package ]
    ++ cfg.packages
  );

  desktopNodeExtraArgs = lib.concatMapStringsSep " " lib.escapeShellArg cfg.desktopNode.extraArgs;

  desktopNodeLauncher = pkgs.writeShellScript "alanix-openclaw-node" ''
    export PATH=${lib.escapeShellArg servicePath}:$PATH
    ${pkgs.coreutils}/bin/mkdir -p "$HOME/.openclaw"
    exec ${openclawBin} node run \
      --host ${lib.escapeShellArg desktopNodeGatewayHost} \
      --port ${toString cfg.desktopNode.gatewayPort}${lib.optionalString cfg.desktopNode.gatewayTls " --tls"}${lib.optionalString (cfg.desktopNode.displayName != null) " --display-name ${lib.escapeShellArg cfg.desktopNode.displayName}"}${lib.optionalString (desktopNodeExtraArgs != "") " ${desktopNodeExtraArgs}"}
  '';
in
{
  options.alanix.openclaw = {
    user = lib.mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "alanix.users account that owns the OpenClaw install and state.";
    };

    npmPrefix = lib.mkOption {
      type = types.str;
      default = ".local";
      description = "Writable npm global prefix for the OpenClaw user. Relative paths are resolved inside the user's home.";
    };

    packages = lib.mkOption {
      type = types.listOf types.package;
      default = [ ];
      description = "Extra packages made available to the user-installed OpenClaw runtime, for example Chromium.";
    };

    gateway = {
      enable = lib.mkEnableOption "prepare this host for a user-managed OpenClaw gateway install";

      linger = lib.mkOption {
        type = types.bool;
        default = true;
        description = "Keep the user manager running so an upstream-installed gateway user service can stay up without an interactive login.";
      };
    };

    desktopNode = {
      enable = lib.mkEnableOption "run an OpenClaw node as a user service using the npm-installed openclaw CLI";

      displayName = lib.mkOption {
        type = types.nullOr types.str;
        default = null;
      };

      gatewayHost = lib.mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Gateway host for the desktop node. Defaults to 127.0.0.1 when omitted.";
      };

      gatewayPort = lib.mkOption {
        type = types.port;
        default = 18789;
      };

      gatewayTls = lib.mkOption {
        type = types.bool;
        default = false;
      };

      extraArgs = lib.mkOption {
        type = types.listOf types.str;
        default = [ ];
      };
    };
  };

  config = {
    assertions = [
      {
        assertion = !openclawEnabled || cfg.user != null;
        message = "alanix.openclaw.user must be set when any OpenClaw integration is enabled.";
      }
      {
        assertion = !openclawEnabled || (openclawUser != null && openclawUser.enable);
        message = "alanix.openclaw.user must reference an enabled alanix.users.accounts entry.";
      }
      {
        assertion = !openclawEnabled || openclawUserHomeReady;
        message = "alanix.openclaw.user must reference an alanix.users.accounts entry with home.enable = true.";
      }
      {
        assertion = !cfg.desktopNode.enable || config.alanix.desktop.enable;
        message = "alanix.openclaw.desktopNode.enable requires alanix.desktop.enable = true.";
      }
      {
        assertion = !cfg.desktopNode.enable || cfg.gateway.enable || cfg.desktopNode.gatewayHost != null;
        message = "alanix.openclaw.desktopNode.gatewayHost must be set when the desktop node is enabled without a local gateway host.";
      }
    ];

    users.users = lib.optionalAttrs (cfg.gateway.enable && cfg.gateway.linger && cfg.user != null) {
      ${cfg.user} = {
        linger = true;
      };
    };

    environment.systemPackages = lib.mkIf openclawEnabled ([ pkgs.nodejs ] ++ cfg.packages);

    home-manager.users = lib.optionalAttrs (openclawUserHomeReady && openclawEnabled) {
      ${cfg.user} = lib.mkMerge [
        {
          home.sessionPath = [ npmBinDir ];
          home.sessionVariables.NPM_CONFIG_PREFIX = npmPrefixDir;

          home.file = lib.optionalAttrs cfg.gateway.enable {
            ".config/systemd/user/openclaw-gateway.service.d/10-alanix-path.conf".text = ''
              [Service]
              Environment=PATH=${npmBinDir}:${servicePath}
            '';
          };
        }

        (lib.mkIf cfg.desktopNode.enable {
          systemd.user.services.openclaw-node = {
            Unit = {
              Description = "OpenClaw desktop node";
              After = [
                "graphical-session.target"
                "network-online.target"
              ];
              Wants = [ "network-online.target" ];
              PartOf = [ "graphical-session.target" ];
              ConditionPathExists = openclawBin;
            };

            Service = {
              ExecStart = "${desktopNodeLauncher}";
              Environment = [
                "HOME=${openclawHomeDir}"
                "OPENCLAW_CONFIG_PATH=${openclawHomeDir}/.openclaw/openclaw.json"
                "OPENCLAW_STATE_DIR=${openclawHomeDir}/.openclaw"
              ];
              Restart = "always";
              RestartSec = 5;
            };

            Install.WantedBy = [ "graphical-session.target" ];
          };
        })
      ];
    };
  };
}
