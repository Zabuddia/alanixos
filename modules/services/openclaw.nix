{ config, lib, pkgs, inputs, ... }:

let
  cfg = config.alanix.openclaw;
  types = lib.types;
  openclawPkgs = inputs.nix-openclaw.packages.${pkgs.stdenv.hostPlatform.system};
  openclawGatewayPackage = openclawPkgs.openclaw-gateway.overrideAttrs (old: {
    # nix-openclaw currently skips upstream runtime-postbuild, which is what
    # writes bundled plugin manifests into dist/extensions/* for built installs.
    buildPhase = lib.concatStringsSep "\n" [
      old.buildPhase
      "node scripts/runtime-postbuild.mjs"
    ];
  });
  openclawCli = pkgs.symlinkJoin {
    name = "openclaw-gateway-system";
    paths = [ openclawGatewayPackage ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram "$out/bin/openclaw" \
        --set-default OPENCLAW_CONFIG_PATH "${config.services.openclaw-gateway.configPath}" \
        --set-default OPENCLAW_STATE_DIR "${config.services.openclaw-gateway.stateDir}"
    '';
  };

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

  desktopNodeGatewayHost =
    if cfg.desktopNode.gatewayHost != null then
      cfg.desktopNode.gatewayHost
    else if cfg.customBindHost != null then
      cfg.customBindHost
    else
      "127.0.0.1";

  desktopUser =
    if cfg.desktopNode.user != null then
      lib.attrByPath [ "alanix" "users" "accounts" cfg.desktopNode.user ] null config
    else
      null;
  desktopUserHomeReady = desktopUser != null && desktopUser.enable && desktopUser.home.enable;
in
{
  options.alanix.openclaw = {
    enable = lib.mkEnableOption "OpenClaw gateway";

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

    tokenSecret = lib.mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "SOPS secret name used for OPENCLAW_GATEWAY_TOKEN.";
    };

    primaryLlmInstance = lib.mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Name of the alanix.llm instance OpenClaw should use as its primary chat model.";
    };

    imageLlmInstance = lib.mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Name of the alanix.llm instance OpenClaw should use for image analysis.";
    };

    embeddingLlmInstance = lib.mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Name of the alanix.llm instance OpenClaw should use for memory embeddings.";
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
      description = "Trusted proxy CIDRs forwarded by the OpenClaw gateway.";
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

    telegram = {
      enable = lib.mkEnableOption "OpenClaw Telegram channel";

      tokenSecret = lib.mkOption {
        type = types.nullOr types.str;
        default = null;
      };

      allowFrom = lib.mkOption {
        type = types.listOf (types.oneOf [ types.int types.str ]);
        default = [ ];
      };

      dmPolicy = lib.mkOption {
        type = types.nullOr types.str;
        default = null;
      };

      groupPolicy = lib.mkOption {
        type = types.nullOr types.str;
        default = null;
      };

      configWrites = lib.mkOption {
        type = types.bool;
        default = false;
      };
    };

    webSearch = {
      enable = lib.mkEnableOption "OpenClaw web search";

      apiKeySecret = lib.mkOption {
        type = types.nullOr types.str;
        default = null;
      };

      braveMode = lib.mkOption {
        type = types.enum [
          "web"
          "llm-context"
        ];
        default = "web";
      };
    };

    browser = {
      enable = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Enable OpenClaw browser control on this host.";
      };

      evaluateEnabled = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Allow browser-side evaluate helpers when browser control is enabled.";
      };

      headless = lib.mkOption {
        type = types.bool;
        default = true;
        description = "Launch the managed browser headlessly by default.";
      };

      package = lib.mkOption {
        type = types.nullOr types.package;
        default = null;
        description = "Browser package whose bin dir should be available to the OpenClaw service.";
      };

      executablePath = lib.mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Explicit browser executable path for hosts where auto-detection is insufficient.";
      };
    };

    canvas = {
      enable = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Enable the OpenClaw canvas host on this system.";
      };

      nodePackage = lib.mkOption {
        type = types.nullOr types.package;
        default = null;
        description = "Node.js package made available to the OpenClaw service for the canvas host.";
      };
    };

    desktopNode = {
      enable = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Run an OpenClaw node in a desktop user session for visible browser windows.";
      };

      user = lib.mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "User account that should run the desktop OpenClaw node.";
      };

      displayName = lib.mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Optional display name advertised by the desktop OpenClaw node.";
      };

      gatewayHost = lib.mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Gateway host the desktop node should connect to. Defaults to 127.0.0.1.";
      };
    };

    extraConfig = lib.mkOption {
      type = types.attrs;
      default = { };
      description = "Extra OpenClaw gateway config merged into the generated config.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.tokenSecret != null;
        message = "alanix.openclaw.tokenSecret must be set when alanix.openclaw.enable = true.";
      }
      {
        assertion = cfg.bind != "custom" || cfg.customBindHost != null;
        message = "alanix.openclaw.customBindHost must be set when bind = \"custom\".";
      }
      {
        assertion = !cfg.enableTailscaleServe || config.alanix.tailscale.enable;
        message = "alanix.openclaw.enableTailscaleServe requires alanix.tailscale.enable = true.";
      }
      {
        assertion = cfg.primaryLlmInstance == null || primaryInstance != null;
        message = "alanix.openclaw.primaryLlmInstance must reference an enabled alanix.llm.instances entry.";
      }
      {
        assertion = cfg.imageLlmInstance == null || imageInstance != null;
        message = "alanix.openclaw.imageLlmInstance must reference an enabled alanix.llm.instances entry.";
      }
      {
        assertion = cfg.embeddingLlmInstance == null || embeddingInstance != null;
        message = "alanix.openclaw.embeddingLlmInstance must reference an enabled alanix.llm.instances entry.";
      }
      {
        assertion = !cfg.desktopNode.enable || cfg.desktopNode.user != null;
        message = "alanix.openclaw.desktopNode.user must be set when desktopNode.enable = true.";
      }
      {
        assertion = !cfg.desktopNode.enable || config.alanix.desktop.enable;
        message = "alanix.openclaw.desktopNode.enable requires alanix.desktop.enable = true.";
      }
      {
        assertion = !cfg.desktopNode.enable || (desktopUser != null && desktopUser.enable);
        message = "alanix.openclaw.desktopNode.user must reference an enabled alanix.users.accounts entry.";
      }
      {
        assertion = !cfg.desktopNode.enable || (desktopUser != null && desktopUser.enable && desktopUser.home.enable);
        message = "alanix.openclaw.desktopNode.user must reference an alanix.users.accounts entry with home.enable = true.";
      }
      {
        assertion = !cfg.browser.enable || cfg.browser.package != null || cfg.browser.executablePath != null;
        message = "alanix.openclaw.browser: set package or executablePath when browser.enable = true.";
      }
      {
        assertion = !cfg.telegram.enable || cfg.telegram.tokenSecret != null;
        message = "alanix.openclaw.telegram.tokenSecret must be set when alanix.openclaw.telegram.enable = true.";
      }
      {
        assertion = !cfg.telegram.enable || cfg.telegram.dmPolicy != null;
        message = "alanix.openclaw.telegram.dmPolicy must be set when alanix.openclaw.telegram.enable = true.";
      }
      {
        assertion = !cfg.telegram.enable || cfg.telegram.groupPolicy != null;
        message = "alanix.openclaw.telegram.groupPolicy must be set when alanix.openclaw.telegram.enable = true.";
      }
      {
        assertion = !cfg.webSearch.enable || cfg.webSearch.apiKeySecret != null;
        message = "alanix.openclaw.webSearch.apiKeySecret must be set when alanix.openclaw.webSearch.enable = true.";
      }
      {
        assertion = !cfg.canvas.enable || cfg.canvas.nodePackage != null;
        message = "alanix.openclaw.canvas.nodePackage must be set when alanix.openclaw.canvas.enable = true.";
      }
    ];

    services.openclaw-gateway = {
      enable = true;
      package = openclawGatewayPackage;
      port = cfg.port;
      environmentFiles =
        lib.optionals (cfg.tokenSecret != null) [ config.sops.templates."openclaw-gateway-env".path ]
        ++ lib.optionals (cfg.webSearch.enable && cfg.webSearch.apiKeySecret != null) [ config.sops.templates."openclaw-brave-env".path ];

      config = lib.mkMerge [
        {
          gateway =
            {
              mode = "local";
              bind = cfg.bind;
              auth = {
                mode = "token";
                allowTailscale = cfg.enableTailscaleServe;
              };
              reload = {
                mode = "hot";
                debounceMs = 500;
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
        }

        (lib.mkIf (llmInstances != { }) {
          models.providers = providerAttrs;
        })

        (lib.mkIf (primaryModelRef != null || imageModelRef != null) {
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

        (lib.mkIf (embeddingInstance != null) {
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

        (lib.mkIf (cfg.telegram.enable && cfg.telegram.tokenSecret != null) {
          channels.telegram = {
            enabled = true;
            tokenFile = config.sops.templates."openclaw-telegram-bot-token".path;
            allowFrom = cfg.telegram.allowFrom;
            dmPolicy = cfg.telegram.dmPolicy;
            groupPolicy = cfg.telegram.groupPolicy;
            configWrites = cfg.telegram.configWrites;
          };
        })

        (lib.mkIf (cfg.webSearch.enable && cfg.webSearch.apiKeySecret != null) {
          tools.web.search =
            {
              enabled = true;
              provider = "brave";
            }
            // lib.optionalAttrs (cfg.webSearch.braveMode != "web") {
              brave.mode = cfg.webSearch.braveMode;
            };
        })

        (lib.mkIf cfg.browser.enable {
          browser = {
            enabled = true;
            evaluateEnabled = cfg.browser.evaluateEnabled;
            headless = cfg.browser.headless;
          } // lib.optionalAttrs (cfg.browser.executablePath != null) {
            executablePath = cfg.browser.executablePath;
          };
        })

        cfg.extraConfig
      ];

      environment = {
        HOME = config.services.openclaw-gateway.stateDir;
        OPENCLAW_NIX_MODE = "1";
        OPENCLAW_SKIP_BROWSER_CONTROL_SERVER = if cfg.browser.enable && !cfg.desktopNode.enable then "0" else "1";
        OPENCLAW_SKIP_CANVAS_HOST = if cfg.canvas.enable then "0" else "1";
        OPENCLAW_SKIP_GMAIL_WATCHER = "1";
        OPENCLAW_DISABLE_BONJOUR = "1";
      };

      servicePath =
        lib.optionals config.services.tailscale.enable [ config.services.tailscale.package ]
        ++ lib.optionals (cfg.browser.enable && cfg.browser.package != null) [ cfg.browser.package ]
        ++ lib.optionals cfg.canvas.enable [ cfg.canvas.nodePackage ];
    };

    environment.systemPackages = [
      openclawCli
      openclawPkgs.openclaw-tools
    ];

    systemd.services.${config.services.openclaw-gateway.unitName} = lib.mkIf cfg.enableTailscaleServe {
      wants = [ "tailscaled.service" ];
      after = [ "tailscaled.service" ];
    };

    home-manager.users = lib.mkIf desktopUserHomeReady {
      ${cfg.desktopNode.user} = {
        systemd.user.services.openclaw-node = {
          Unit = {
            Description = "OpenClaw desktop node";
            After = [ "graphical-session.target" ];
            PartOf = [ "graphical-session.target" ];
          };

          Service = {
            ExecStart =
              let
                displayNameArg = lib.optionalString (cfg.desktopNode.displayName != null)
                  " --display-name ${lib.escapeShellArg cfg.desktopNode.displayName}";
              in
              "${openclawCli}/bin/openclaw node run --host ${lib.escapeShellArg desktopNodeGatewayHost} --port ${toString cfg.port}${displayNameArg}";
            Environment = [
              "OPENCLAW_CONFIG_PATH=${config.services.openclaw-gateway.configPath}"
              "OPENCLAW_STATE_DIR=%h/.local/state/openclaw"
            ];
            EnvironmentFile = lib.optionals (cfg.tokenSecret != null) [ config.sops.templates."openclaw-node-env".path ];
            Restart = "always";
            RestartSec = 2;
          };

          Install.WantedBy = [ "graphical-session.target" ];
        };
      };
    };
  };
}
