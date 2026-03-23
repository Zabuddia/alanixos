{ config, lib, pkgs, inputs, ... }:

let
  cfg = config.alanix.openclaw;
  types = lib.types;

  openclawPkgs = inputs.nix-openclaw.packages.${pkgs.stdenv.hostPlatform.system};
  openclawGatewayPackage = openclawPkgs.openclaw-gateway;
  openclawToolsPackage = openclawPkgs.openclaw-tools;

  openclawEnabled = cfg.gateway.enable || cfg.desktopNode.enable;
  openclawEnvFile = lib.attrByPath [ "sops" "templates" "openclaw-env" "path" ] null config;

  openclawCli = pkgs.writeShellScriptBin "openclaw" ''
    export OPENCLAW_NIX_MODE=0
    export OPENCLAW_CONFIG_PATH="''${OPENCLAW_CONFIG_PATH:-$HOME/.openclaw/openclaw.json}"
    export OPENCLAW_STATE_DIR="''${OPENCLAW_STATE_DIR:-$HOME/.openclaw}"
    exec ${openclawGatewayPackage}/bin/openclaw "$@"
  '';

  llmInstances = lib.filterAttrs (_: instance: instance.enable) config.alanix.llm.instances;

  mkProviderName = instanceName: "local-llama-${instanceName}";
  mkModelAlias = instance: if instance.alias != null then instance.alias else instance.model.name;
  mkModelRef = instanceName: instance: "${mkProviderName instanceName}/${mkModelAlias instance}";

  providerAttrs =
    lib.mapAttrs'
      (instanceName: instance:
        lib.nameValuePair (mkProviderName instanceName) {
          api = "openai-completions";
          baseUrl = "http://${instance.host}:${toString instance.port}/v1";
          apiKey = mkProviderName instanceName;
          authHeader = false;
          injectNumCtxForOpenAICompat = true;
          models = [
            ({
              id = mkModelAlias instance;
              name = mkModelAlias instance;
              api = "openai-completions";
              contextWindow = instance.ctxSize;
            } // lib.optionalAttrs (instance.input != [ ]) {
              input = instance.input;
            })
          ];
        })
      llmInstances;

  primaryInstance =
    if cfg.primaryLlmInstance != null then
      lib.attrByPath [ cfg.primaryLlmInstance ] null llmInstances
    else
      null;

  imageInstance =
    if cfg.imageLlmInstance != null then
      lib.attrByPath [ cfg.imageLlmInstance ] null llmInstances
    else
      null;

  embeddingInstance =
    if cfg.embeddingLlmInstance != null then
      lib.attrByPath [ cfg.embeddingLlmInstance ] null llmInstances
    else
      null;

  primaryModelRef =
    if primaryInstance != null then
      mkModelRef cfg.primaryLlmInstance primaryInstance
    else
      null;

  imageModelRef =
    if imageInstance != null then
      mkModelRef cfg.imageLlmInstance imageInstance
    else
      null;

  embeddingModelAlias =
    if embeddingInstance != null then
      mkModelAlias embeddingInstance
    else
      null;

  openclawUser =
    if cfg.user != null then
      lib.attrByPath [ "alanix" "users" "accounts" cfg.user ] null config
    else
      null;

  openclawUserHomeReady = openclawUser != null && openclawUser.enable && openclawUser.home.enable;
  openclawHomeDir = if openclawUserHomeReady then openclawUser.home.directory else null;

  servicePathPackages =
    lib.optionals config.services.tailscale.enable [ config.services.tailscale.package ]
    ++ lib.optionals (cfg.browser.enable && cfg.browser.package != null) [ cfg.browser.package ]
    ++ lib.optionals (cfg.canvas.enable && cfg.canvas.nodePackage != null) [ cfg.canvas.nodePackage ];

  servicePath = lib.makeBinPath ([ pkgs.bash pkgs.coreutils ] ++ servicePathPackages);

  desktopNodeGatewayHost =
    if cfg.desktopNode.gatewayHost != null then
      cfg.desktopNode.gatewayHost
    else if cfg.customBindHost != null then
      cfg.customBindHost
    else
      "127.0.0.1";

  desktopNodeGatewayPort =
    if cfg.desktopNode.gatewayPort != null then
      cfg.desktopNode.gatewayPort
    else
      cfg.port;

  bootstrapConfig = lib.foldl' lib.recursiveUpdate { } [
    (lib.optionalAttrs cfg.gateway.enable {
      gateway =
        {
          mode = "local";
          bind = cfg.bind;
          auth = {
            mode = "token";
            allowTailscale = cfg.enableTailscaleServe;
          };
          http.endpoints = {
            responses.enabled = cfg.enableResponsesApi;
            chatCompletions.enabled = cfg.enableChatCompletionsApi;
          };
          controlUi =
            lib.optionalAttrs (cfg.controlUi.allowedOrigins != [ ]) {
              allowedOrigins = cfg.controlUi.allowedOrigins;
            }
            // lib.optionalAttrs cfg.controlUi.dangerouslyDisableDeviceAuth {
              dangerouslyDisableDeviceAuth = true;
            };
        }
        // lib.optionalAttrs (cfg.customBindHost != null) {
          customBindHost = cfg.customBindHost;
        }
        // lib.optionalAttrs (cfg.trustedProxies != [ ]) {
          trustedProxies = cfg.trustedProxies;
        }
        // lib.optionalAttrs cfg.enableTailscaleServe {
          tailscale.mode = "serve";
        };

      discovery.mdns.mode = "minimal";
    })

    (lib.optionalAttrs (llmInstances != { }) {
      models.providers = providerAttrs;
    })

    (lib.optionalAttrs (primaryModelRef != null || imageModelRef != null) {
      agents.defaults =
        (lib.optionalAttrs (primaryModelRef != null) {
          model.primary = primaryModelRef;
        })
        // (lib.optionalAttrs (imageModelRef != null) {
          imageModel.primary = imageModelRef;
        })
        // lib.optionalAttrs (primaryModelRef != null || imageModelRef != null) {
          models =
            (lib.optionalAttrs (primaryModelRef != null) {
              ${primaryModelRef} = {
                alias = mkModelAlias primaryInstance;
                streaming = true;
              };
            })
            // (lib.optionalAttrs (imageModelRef != null) {
              ${imageModelRef} = {
                alias = mkModelAlias imageInstance;
                streaming = true;
              };
            });
        };
    })

    (lib.optionalAttrs (embeddingInstance != null) {
      agents.defaults.memorySearch = {
        enabled = true;
        provider = "openai";
        model = embeddingModelAlias;
        fallback = "none";
        remote = {
          baseUrl = "http://${embeddingInstance.host}:${toString embeddingInstance.port}/v1";
          apiKey = "local-embeddings";
        };
      };
    })

    (lib.optionalAttrs cfg.browser.enable {
      browser = {
        enabled = true;
        evaluateEnabled = cfg.browser.evaluateEnabled;
        headless = cfg.browser.headless;
      } // lib.optionalAttrs (cfg.browser.executablePath != null) {
        executablePath = cfg.browser.executablePath;
      };
    })

    (lib.optionalAttrs cfg.canvas.enable {
      canvasHost =
        {
          enabled = true;
        }
        // lib.optionalAttrs (cfg.canvas.root != null) {
          root = cfg.canvas.root;
        }
        // lib.optionalAttrs (cfg.canvas.port != null) {
          port = cfg.canvas.port;
        }
        // lib.optionalAttrs cfg.canvas.liveReload {
          liveReload = true;
        };
    })

    cfg.bootstrapConfig
  ];

  bootstrapConfigFile = pkgs.writeText "openclaw-bootstrap.json" (builtins.toJSON bootstrapConfig);

  gatewayExtraArgs = lib.concatMapStringsSep " " lib.escapeShellArg cfg.gateway.extraArgs;
  desktopNodeExtraArgs = lib.concatMapStringsSep " " lib.escapeShellArg cfg.desktopNode.extraArgs;

  gatewayLauncher = pkgs.writeShellScript "alanix-openclaw-gateway" ''
    export PATH=${lib.escapeShellArg servicePath}:$PATH
    ${pkgs.coreutils}/bin/mkdir -p "$HOME/.openclaw" "$HOME/.openclaw/logs"
    if [ ! -e "$OPENCLAW_CONFIG_PATH" ] && [ ${lib.escapeShellArg (builtins.toJSON bootstrapConfig)} != "{}" ]; then
      ${pkgs.coreutils}/bin/install -Dm600 ${bootstrapConfigFile} "$OPENCLAW_CONFIG_PATH"
    fi
    exec ${openclawCli}/bin/openclaw gateway --port ${toString cfg.port}${lib.optionalString (gatewayExtraArgs != "") " ${gatewayExtraArgs}"}
  '';

  desktopNodeLauncher = pkgs.writeShellScript "alanix-openclaw-node" ''
    export PATH=${lib.escapeShellArg servicePath}:$PATH
    ${pkgs.coreutils}/bin/mkdir -p "$HOME/.openclaw" "$HOME/.openclaw/logs"
    if [ ! -e "$OPENCLAW_CONFIG_PATH" ] && [ ${lib.escapeShellArg (builtins.toJSON bootstrapConfig)} != "{}" ]; then
      ${pkgs.coreutils}/bin/install -Dm600 ${bootstrapConfigFile} "$OPENCLAW_CONFIG_PATH"
    fi
    exec ${openclawCli}/bin/openclaw node run \
      --host ${lib.escapeShellArg desktopNodeGatewayHost} \
      --port ${toString desktopNodeGatewayPort}${lib.optionalString cfg.desktopNode.gatewayTls " --tls"}${lib.optionalString (cfg.desktopNode.displayName != null) " --display-name ${lib.escapeShellArg cfg.desktopNode.displayName}"}${lib.optionalString (desktopNodeExtraArgs != "") " ${desktopNodeExtraArgs}"}
  '';
in
{
  options.alanix.openclaw = {
    user = lib.mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "alanix.users account that owns the OpenClaw config and services.";
    };

    tokenSecret = lib.mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "SOPS secret name used for OPENCLAW_GATEWAY_TOKEN.";
    };

    bind = lib.mkOption {
      type = types.enum [
        "auto"
        "custom"
        "lan"
        "loopback"
        "tailnet"
      ];
      default = "loopback";
    };

    customBindHost = lib.mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Explicit host/IP to bind when bind = \"custom\".";
    };

    port = lib.mkOption {
      type = types.port;
      default = 18789;
    };

    primaryLlmInstance = lib.mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Name of the alanix.llm instance to seed as the primary chat model.";
    };

    imageLlmInstance = lib.mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Name of the alanix.llm instance to seed as the image model.";
    };

    embeddingLlmInstance = lib.mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Name of the alanix.llm instance to seed for memory embeddings.";
    };

    enableResponsesApi = lib.mkOption {
      type = types.bool;
      default = true;
    };

    enableChatCompletionsApi = lib.mkOption {
      type = types.bool;
      default = true;
    };

    enableTailscaleServe = lib.mkOption {
      type = types.bool;
      default = false;
    };

    trustedProxies = lib.mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Trusted proxy CIDRs to seed into the initial gateway config.";
    };

    controlUi = {
      allowedOrigins = lib.mkOption {
        type = types.listOf types.str;
        default = [ ];
      };

      dangerouslyDisableDeviceAuth = lib.mkOption {
        type = types.bool;
        default = false;
      };
    };

    browser = {
      enable = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Seed browser support in the initial OpenClaw config.";
      };

      evaluateEnabled = lib.mkOption {
        type = types.bool;
        default = false;
      };

      headless = lib.mkOption {
        type = types.bool;
        default = true;
      };

      package = lib.mkOption {
        type = types.nullOr types.package;
        default = null;
        description = "Browser package made available to OpenClaw via PATH.";
      };

      executablePath = lib.mkOption {
        type = types.nullOr types.str;
        default = null;
      };
    };

    canvas = {
      enable = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Seed canvas host support in the initial OpenClaw config.";
      };

      nodePackage = lib.mkOption {
        type = types.nullOr types.package;
        default = null;
        description = "Node.js package made available to OpenClaw via PATH.";
      };

      root = lib.mkOption {
        type = types.nullOr types.str;
        default = null;
      };

      port = lib.mkOption {
        type = types.nullOr types.port;
        default = null;
      };

      liveReload = lib.mkOption {
        type = types.bool;
        default = false;
      };
    };

    gateway = {
      enable = lib.mkEnableOption "OpenClaw gateway user service";

      linger = lib.mkOption {
        type = types.bool;
        default = true;
        description = "Keep the user manager running so the gateway starts without an interactive login.";
      };

      extraArgs = lib.mkOption {
        type = types.listOf types.str;
        default = [ ];
      };
    };

    desktopNode = {
      enable = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Run an OpenClaw node in the desktop user session.";
      };

      displayName = lib.mkOption {
        type = types.nullOr types.str;
        default = null;
      };

      gatewayHost = lib.mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Gateway host for the desktop node. Defaults to 127.0.0.1 when the gateway also runs locally.";
      };

      gatewayPort = lib.mkOption {
        type = types.nullOr types.port;
        default = null;
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

    bootstrapConfig = lib.mkOption {
      type = types.attrs;
      default = { };
      description = "Extra config merged into the initial ~/.openclaw/openclaw.json, written only if it does not already exist.";
    };
  };

  config = {
    assertions = [
      {
        assertion = !openclawEnabled || cfg.user != null;
        message = "alanix.openclaw.user must be set when any OpenClaw service is enabled.";
      }
      {
        assertion = !openclawEnabled || cfg.tokenSecret != null;
        message = "alanix.openclaw.tokenSecret must be set when any OpenClaw service is enabled.";
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
        assertion = !cfg.gateway.enable || cfg.bind != "custom" || cfg.customBindHost != null;
        message = "alanix.openclaw.customBindHost must be set when bind = \"custom\".";
      }
      {
        assertion = !cfg.enableTailscaleServe || config.alanix.tailscale.enable;
        message = "alanix.openclaw.enableTailscaleServe requires alanix.tailscale.enable = true.";
      }
      {
        assertion = !cfg.gateway.enable || cfg.primaryLlmInstance == null || primaryInstance != null;
        message = "alanix.openclaw.primaryLlmInstance must reference an enabled alanix.llm.instances entry.";
      }
      {
        assertion = !cfg.gateway.enable || cfg.imageLlmInstance == null || imageInstance != null;
        message = "alanix.openclaw.imageLlmInstance must reference an enabled alanix.llm.instances entry.";
      }
      {
        assertion = !cfg.gateway.enable || cfg.embeddingLlmInstance == null || embeddingInstance != null;
        message = "alanix.openclaw.embeddingLlmInstance must reference an enabled alanix.llm.instances entry.";
      }
      {
        assertion = !cfg.browser.enable || cfg.browser.package != null || cfg.browser.executablePath != null;
        message = "alanix.openclaw.browser: set package or executablePath when browser.enable = true.";
      }
      {
        assertion = !cfg.canvas.enable || cfg.canvas.nodePackage != null;
        message = "alanix.openclaw.canvas.nodePackage must be set when canvas.enable = true.";
      }
      {
        assertion = !cfg.desktopNode.enable || config.alanix.desktop.enable;
        message = "alanix.openclaw.desktopNode.enable requires alanix.desktop.enable = true.";
      }
      {
        assertion = !cfg.desktopNode.enable || cfg.gateway.enable || cfg.desktopNode.gatewayHost != null;
        message = "alanix.openclaw.desktopNode.gatewayHost must be set when the desktop node is enabled without a local gateway.";
      }
    ];

    users.users = lib.optionalAttrs (cfg.gateway.enable && cfg.gateway.linger && cfg.user != null) {
      ${cfg.user} = {
        linger = true;
      };
    };

    environment.systemPackages = lib.mkIf openclawEnabled [
      openclawCli
      openclawToolsPackage
    ];

    home-manager.users = lib.optionalAttrs openclawUserHomeReady {
      ${cfg.user} = lib.recursiveUpdate
        (lib.optionalAttrs cfg.gateway.enable {
          systemd.user.services.openclaw-gateway = {
            Unit = {
              Description = "OpenClaw gateway";
              After = [ "network-online.target" ];
              Wants = [ "network-online.target" ];
            };

            Service = {
              ExecStart = "${gatewayLauncher}";
              Environment = [
                "HOME=${openclawHomeDir}"
                "OPENCLAW_CONFIG_PATH=${openclawHomeDir}/.openclaw/openclaw.json"
                "OPENCLAW_STATE_DIR=${openclawHomeDir}/.openclaw"
                "OPENCLAW_NIX_MODE=0"
              ];
              EnvironmentFile = lib.optionals (openclawEnvFile != null) [ "${openclawEnvFile}" ];
              Restart = "always";
              RestartSec = 2;
              StandardOutput = "append:${openclawHomeDir}/.openclaw/logs/gateway.log";
              StandardError = "append:${openclawHomeDir}/.openclaw/logs/gateway.log";
            };

            Install.WantedBy = [ "default.target" ];
          };
        })
        (lib.optionalAttrs cfg.desktopNode.enable {
          systemd.user.services.openclaw-node = {
            Unit = {
              Description = "OpenClaw desktop node";
              After = [ "graphical-session.target" ];
              PartOf = [ "graphical-session.target" ];
            };

            Service = {
              ExecStart = "${desktopNodeLauncher}";
              Environment = [
                "HOME=${openclawHomeDir}"
                "OPENCLAW_CONFIG_PATH=${openclawHomeDir}/.openclaw/openclaw.json"
                "OPENCLAW_STATE_DIR=${openclawHomeDir}/.openclaw"
                "OPENCLAW_NIX_MODE=0"
              ];
              EnvironmentFile = lib.optionals (openclawEnvFile != null) [ "${openclawEnvFile}" ];
              Restart = "always";
              RestartSec = 2;
              StandardOutput = "append:${openclawHomeDir}/.openclaw/logs/node.log";
              StandardError = "append:${openclawHomeDir}/.openclaw/logs/node.log";
            };

            Install.WantedBy = [ "graphical-session.target" ];
          };
        });
    };
  };
}
