{ config, lib, pkgs, pkgs-unstable, ... }:

let
  cfg = config.alanix.openclaw;
  types = lib.types;
  jsonFormat = pkgs.formats.json { };
  serviceExposure = import ../../../lib/mkServiceExposure.nix { inherit lib pkgs; };

  openclawEnabled = cfg.gateway.enable;
  openclawUser =
    if cfg.user != null then
      lib.attrByPath [ "alanix" "users" "accounts" cfg.user ] null config
    else
      null;
  openclawUserHomeReady = openclawUser != null && openclawUser.enable && openclawUser.home.enable;
  openclawHomeDir = if openclawUserHomeReady then openclawUser.home.directory else null;

  openclawPackage = pkgs-unstable.openclaw;
  openclawBin = lib.getExe openclawPackage;
  fullExecApprovalsFile = jsonFormat.generate "openclaw-full-exec-approvals.json" {
    version = 1;
    defaults = {
      security = "full";
      ask = "off";
      askFallback = "full";
      autoAllowSkills = false;
    };
    agents.jarvis = {
      security = "full";
      ask = "off";
      askFallback = "full";
      autoAllowSkills = false;
    };
  };
  servicePath = lib.makeBinPath (
    [
      pkgs.bash
      pkgs.coreutils
      openclawPackage
    ]
    ++ lib.optionals config.services.tailscale.enable [ config.services.tailscale.package ]
    ++ cfg.packages
  );

  resolveHomePath = path:
    if openclawHomeDir == null then
      null
    else if lib.hasPrefix "/" path then
      path
    else
      "${openclawHomeDir}/${path}";

  gatewayStateDir = resolveHomePath cfg.gateway.stateDir;
  gatewayWorkspaceDir = resolveHomePath cfg.gateway.workspaceDir;
  gatewayConfigPath = "${gatewayStateDir}/openclaw.json";
  homeAssistantMcpConfig = lib.optionalAttrs cfg.homeAssistant.enable {
    mcp.servers.home-assistant = {
      url = cfg.homeAssistant.url;
      transport = "streamable-http";
      timeout = cfg.homeAssistant.timeout;
      connectTimeout = cfg.homeAssistant.connectTimeout;
      supportsParallelToolCalls = false;
      headers.Authorization = "Bearer \${OPENCLAW_HOME_ASSISTANT_TOKEN}";
    };
    tools.alsoAllow = lib.unique (
      lib.attrByPath [ "tools" "alsoAllow" ] [ ] cfg.gateway.config
      ++ [ "bundle-mcp" ]
    );
  };
  gatewayConfig = lib.recursiveUpdate (lib.recursiveUpdate cfg.gateway.config homeAssistantMcpConfig) {
    gateway = {
      mode = "local";
      port = cfg.gateway.port;
      bind = "loopback";
      auth.mode = "token";
      tailscale = {
        mode = "off";
        resetOnExit = false;
      };
      controlUi.dangerouslyDisableDeviceAuth = false;
    };
  };
  gatewayConfigFile = jsonFormat.generate "openclaw.json" gatewayConfig;
  gatewayWorkspaceInstallCommands = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (
      name: source:
      let
        destination = "${gatewayWorkspaceDir}/${name}";
      in
      if name == "MEMORY.md" then
        ''
          if [ -L ${lib.escapeShellArg destination} ]; then
            ${pkgs.coreutils}/bin/rm -f ${lib.escapeShellArg destination}
          fi
          if [ ! -e ${lib.escapeShellArg destination} ]; then
            ${pkgs.coreutils}/bin/install -m 0644 ${lib.escapeShellArg source} ${lib.escapeShellArg destination}
          fi
        ''
      else
        ''
          ${pkgs.coreutils}/bin/rm -f ${lib.escapeShellArg destination}
          ${pkgs.coreutils}/bin/install -m 0444 ${lib.escapeShellArg source} ${lib.escapeShellArg destination}
        ''
    ) cfg.gateway.workspaceFiles
  );

  gatewayLauncher = pkgs.writeShellScript "alanix-openclaw-gateway" ''
    set -euo pipefail

    export PATH=${lib.escapeShellArg servicePath}:$PATH
    export OPENCLAW_GATEWAY_TOKEN="$(${pkgs.coreutils}/bin/tr -d '\r\n' < ${lib.escapeShellArg cfg.gateway.gatewayTokenFile})"
    ${lib.optionalString cfg.homeAssistant.enable ''
      export OPENCLAW_HOME_ASSISTANT_TOKEN="$(${pkgs.coreutils}/bin/tr -d '\r\n' < ${lib.escapeShellArg cfg.homeAssistant.accessTokenFile})"
    ''}
    ${pkgs.coreutils}/bin/mkdir -p ${lib.escapeShellArg gatewayStateDir} ${lib.escapeShellArg gatewayWorkspaceDir}
    ${lib.optionalString cfg.gateway.enableFullExec ''
      ${pkgs.coreutils}/bin/install -m 0600 ${fullExecApprovalsFile} ${lib.escapeShellArg "${gatewayStateDir}/exec-approvals.json"}
    ''}
    ${gatewayWorkspaceInstallCommands}

    exec ${openclawBin} gateway run \
      --port ${toString cfg.gateway.port} \
      --bind loopback \
      --auth token \
      --tailscale off
  '';

  gatewayEndpoint = {
    address = "127.0.0.1";
    port = cfg.gateway.port;
    protocol = "tcp";
  };
in
{
  options.alanix.openclaw = {
    user = lib.mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "alanix.users account that owns the OpenClaw services and state.";
    };

    packages = lib.mkOption {
      type = types.listOf types.package;
      default = [ ];
      description = "Extra packages made available to OpenClaw services.";
    };

    gateway = {
      enable = lib.mkEnableOption "a declarative OpenClaw gateway user service";

      enableFullExec = lib.mkEnableOption "unrestricted command execution on the gateway host";

      port = lib.mkOption {
        type = types.port;
        default = 18789;
        description = "Loopback port used by the OpenClaw gateway.";
      };

      gatewayTokenFile = lib.mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Runtime path containing only the OpenClaw gateway token.";
      };

      stateDir = lib.mkOption {
        type = types.str;
        default = ".openclaw";
        description = "Gateway state directory. Relative paths are resolved inside the OpenClaw user's home.";
      };

      workspaceDir = lib.mkOption {
        type = types.str;
        default = ".openclaw/workspaces/jarvis";
        description = "Default agent workspace directory. Relative paths are resolved inside the OpenClaw user's home.";
      };

      config = lib.mkOption {
        type = jsonFormat.type;
        default = { };
        description = "Declarative OpenClaw configuration. Secure gateway settings are enforced by this module.";
      };

      workspaceFiles = lib.mkOption {
        type = types.attrsOf types.path;
        default = { };
        description = "Declarative files installed in the OpenClaw default agent workspace.";
      };

      linger = lib.mkOption {
        type = types.bool;
        default = true;
        description = "Keep the user manager running so the gateway stays available without an interactive login.";
      };

      expose = serviceExposure.mkOptions {
        serviceName = "openclaw-gateway";
        serviceDescription = "OpenClaw gateway";
        defaultPublicPort = 18790;
      };
    };

    homeAssistant = {
      enable = lib.mkEnableOption "Home Assistant control through its official MCP Server";

      url = lib.mkOption {
        type = types.str;
        default = "http://alan-home:8123/api/mcp/assist";
        description = "Private URL of Home Assistant's MCP endpoint for the Assist API.";
      };

      accessTokenFile = lib.mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Runtime file containing a Home Assistant long-lived access token.";
      };

      timeout = lib.mkOption {
        type = types.ints.positive;
        default = 20;
        description = "Home Assistant MCP request timeout in seconds.";
      };

      connectTimeout = lib.mkOption {
        type = types.ints.positive;
        default = 5;
        description = "Home Assistant MCP connection timeout in seconds.";
      };
    };

  };

  config = lib.mkMerge [
    {
      # Nixpkgs marks OpenClaw insecure because model-driven host execution is
      # unsafe by default. Keep the gateway credential outside the Nix store.
      nixpkgs.config.permittedInsecurePackages =
        lib.optionals openclawEnabled [ "openclaw-2026.6.33" ];

      assertions = [
        {
          assertion = !openclawEnabled || cfg.user != null;
          message = "alanix.openclaw.user must be set when OpenClaw is enabled.";
        }
        {
          assertion = !openclawEnabled || (openclawUser != null && openclawUser.enable);
          message = "alanix.openclaw.user must reference an enabled alanix.users.accounts entry.";
        }
        {
          assertion = !openclawEnabled || openclawUserHomeReady;
          message = "alanix.openclaw.user must reference an account with home.enable = true.";
        }
        {
          assertion = !cfg.gateway.enable || cfg.gateway.gatewayTokenFile != null;
          message = "alanix.openclaw.gateway.gatewayTokenFile must be set when the gateway is enabled.";
        }
        {
          assertion = !cfg.homeAssistant.enable || cfg.gateway.enable;
          message = "alanix.openclaw.homeAssistant requires the OpenClaw gateway.";
        }
        {
          assertion = !cfg.homeAssistant.enable || cfg.homeAssistant.accessTokenFile != null;
          message = "alanix.openclaw.homeAssistant.accessTokenFile must be set when Home Assistant MCP is enabled.";
        }
      ]
      ++ serviceExposure.mkAssertions {
        inherit config;
        optionPrefix = "alanix.openclaw.gateway.expose";
        endpoint = gatewayEndpoint;
        exposeCfg = cfg.gateway.expose;
      };

      users.users = lib.optionalAttrs (
        cfg.user != null
        && cfg.gateway.enable
        && cfg.gateway.linger
      ) {
        ${cfg.user}.linger = true;
      };

      environment.systemPackages = lib.mkIf openclawEnabled ([ openclawPackage ] ++ cfg.packages);

      home-manager.users = lib.optionalAttrs (openclawUserHomeReady && openclawEnabled) {
        ${cfg.user} = lib.mkMerge [
          {
            # Keep the conventional per-user command path from shadowing the
            # reviewed Nix package with a stale npm installation.
            home.file.".local/bin/openclaw" = {
              source = "${openclawPackage}/bin/openclaw";
              force = true;
            };
          }

          (lib.mkIf cfg.gateway.enable {
            # Replace the legacy `openclaw gateway install` unit on the first
            # activation, and keep this path owned by Home Manager afterward.
            xdg.configFile."systemd/user/openclaw-gateway.service".force = true;
            xdg.configFile."systemd/user/default.target.wants/openclaw-gateway.service".force = true;

            home.file =
              {
                "${cfg.gateway.stateDir}/openclaw.json" = {
                  source = gatewayConfigFile;
                  force = true;
                };
              };

            systemd.user.services.openclaw-gateway = {
              Unit = {
                Description = "OpenClaw gateway";
                After = [ "network-online.target" ];
                Wants = [ "network-online.target" ];
                ConditionPathExists = cfg.gateway.gatewayTokenFile;
              };

              Service = {
                ExecStart = "${gatewayLauncher}";
                Environment = [
                  "HOME=${openclawHomeDir}"
                  "OPENCLAW_CONFIG_PATH=${gatewayConfigPath}"
                  "OPENCLAW_STATE_DIR=${gatewayStateDir}"
                ];
                Restart = "always";
                RestartSec = 5;
              };

              Install.WantedBy = [ "default.target" ];
            };
          })

        ];
      };
    }

    (serviceExposure.mkConfig {
      serviceName = "openclaw-gateway";
      serviceDescription = "OpenClaw gateway";
      inherit config;
      endpoint = gatewayEndpoint;
      exposeCfg = cfg.gateway.expose;
    })
  ];
}
