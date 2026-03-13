{ config, lib, pkgs, inputs, ... }:

let
  cfg = config.alanix.openclaw;
  openclawPkgs = inputs.nix-openclaw.packages.${pkgs.stdenv.hostPlatform.system};
  hasLlm = lib.hasAttrByPath [ "alanix" "llm" ] config;
  llmCfg = if hasLlm then config.alanix.llm else null;
  llmModelAlias =
    if hasLlm && llmCfg.alias != null then llmCfg.alias else if hasLlm then llmCfg.model.name else null;
  llmModelRef = "local-llama/${llmModelAlias}";
  tokenPlaceholder = config.sops.placeholder.${cfg.tokenSecret};
in
{
  options.alanix.openclaw = {
    enable = lib.mkEnableOption "OpenClaw gateway";

    bind = lib.mkOption {
      type = lib.types.enum [
        "auto"
        "custom"
        "lan"
        "loopback"
        "tailnet"
      ];
      default = "tailnet";
    };

    customBindHost = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Explicit host/IP to bind when bind = \"custom\".";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 18789;
    };

    tokenSecret = lib.mkOption {
      type = lib.types.str;
      default = "openclaw/gateway-token";
      description = "SOPS secret name used for OPENCLAW_GATEWAY_TOKEN.";
    };

    enableResponsesApi = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };

    enableChatCompletionsApi = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };

    extraConfig = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = "Extra OpenClaw gateway config merged into the generated config.";
    };
  };

  config = lib.mkIf cfg.enable {
    sops.secrets.${cfg.tokenSecret} = {
      owner = "openclaw";
      group = "openclaw";
      mode = "0400";
    };

    sops.templates."openclaw-gateway-env" = {
      content = "OPENCLAW_GATEWAY_TOKEN=${tokenPlaceholder}";
      owner = "openclaw";
      group = "openclaw";
      mode = "0400";
    };

    services.openclaw-gateway = {
      enable = true;
      package = openclawPkgs.openclaw-gateway;
      port = cfg.port;
      environmentFiles = [ config.sops.templates."openclaw-gateway-env".path ];

      config = lib.mkMerge [
        {
          gateway =
            {
              mode = "local";
              bind = cfg.bind;
              auth.mode = "token";
              reload = {
                mode = "hot";
                debounceMs = 500;
              };
              http.endpoints = {
                responses.enabled = cfg.enableResponsesApi;
                chatCompletions.enabled = cfg.enableChatCompletionsApi;
              };
            }
            // lib.optionalAttrs (cfg.customBindHost != null) {
              customBindHost = cfg.customBindHost;
            };

          discovery.mdns.mode = "minimal";
          plugins.enabled = false;
        }

        (lib.mkIf (hasLlm && llmCfg.enable) {
          models.providers.local-llama = {
            api = "openai-completions";
            baseUrl = "http://${llmCfg.host}:${toString llmCfg.port}/v1";
            apiKey = "local-llama";
            authHeader = false;
            injectNumCtxForOpenAICompat = true;
            models = [
              {
                id = llmModelAlias;
                name = llmModelAlias;
                api = "openai-completions";
                contextWindow = llmCfg.ctxSize;
              }
            ];
          };

          agents.defaults = {
            model.primary = llmModelRef;
            models.${llmModelRef} = {
              alias = llmModelAlias;
              streaming = true;
            };
          };
        })

        cfg.extraConfig
      ];

      environment = {
        OPENCLAW_SKIP_BROWSER_CONTROL_SERVER = "1";
        OPENCLAW_SKIP_CANVAS_HOST = "1";
        OPENCLAW_SKIP_CHANNELS = "1";
        OPENCLAW_SKIP_CRON = "1";
        OPENCLAW_SKIP_GMAIL_WATCHER = "1";
        OPENCLAW_DISABLE_BONJOUR = "1";
      };
    };
    environment.systemPackages = [
      openclawPkgs.openclaw-gateway
      openclawPkgs.openclaw-tools
    ];
  };
}
