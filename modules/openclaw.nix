{ config, lib, pkgs, inputs, ... }:

let
  cfg = config.alanix.openclaw;
  openclawPkgs = inputs.nix-openclaw.packages.${pkgs.stdenv.hostPlatform.system};
  openclawGatewayPackage = openclawPkgs.openclaw-gateway.overrideAttrs (old: {
    installPhase = old.installPhase + ''

      if [ -d "$out/lib/openclaw/extensions/nostr" ]; then
        store_path_file="''${PNPM_STORE_PATH_FILE:-.pnpm-store-path}"
        if [ -f "$store_path_file" ]; then
          store_path="$(cat "$store_path_file")"
          export PNPM_STORE_DIR="$store_path"
          export PNPM_STORE_PATH="$store_path"
          export NPM_CONFIG_STORE_DIR="$store_path"
          export NPM_CONFIG_STORE_PATH="$store_path"
          export PNPM_CONFIG_MANAGE_PACKAGE_MANAGER_VERSIONS=false
          export HOME="$(mktemp -d)"

          (
            cd "$out/lib/openclaw/extensions/nostr"
            pnpm install --offline --prod --ignore-scripts --store-dir "$store_path"
          )
        fi
      fi
    '';
  });
  types = lib.types;
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
  hasLlm = lib.hasAttrByPath [ "alanix" "llm" ] config;
  llmCfg = if hasLlm then config.alanix.llm else null;
  llmModelAlias =
    if hasLlm && llmCfg.alias != null then llmCfg.alias else if hasLlm then llmCfg.model.name else null;
  llmModelRef = "local-llama/${llmModelAlias}";
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

    enableTailscaleServe = lib.mkOption {
      type = types.bool;
      default = false;
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
        type = types.str;
        default = "telegram/bot-token";
      };

      allowFrom = lib.mkOption {
        type = types.listOf (types.oneOf [ types.int types.str ]);
        default = [ ];
      };

      dmPolicy = lib.mkOption {
        type = types.str;
        default = "allowlist";
      };

      groupPolicy = lib.mkOption {
        type = types.str;
        default = "disabled";
      };

      configWrites = lib.mkOption {
        type = types.bool;
        default = false;
      };
    };

    nostr = {
      enable = lib.mkEnableOption "OpenClaw Nostr channel";

      privateKeySecret = lib.mkOption {
        type = types.str;
        default = "nostr/private-key";
      };

      dmPolicy = lib.mkOption {
        type = types.str;
        default = "pairing";
      };

      allowFrom = lib.mkOption {
        type = types.listOf types.str;
        default = [ ];
      };

      relays = lib.mkOption {
        type = types.listOf types.str;
        default = [ ];
      };
    };

    extraConfig = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = "Extra OpenClaw gateway config merged into the generated config.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.openclaw-gateway = {
      enable = true;
      package = openclawGatewayPackage;
      port = cfg.port;
      environmentFiles =
        [ config.sops.templates."openclaw-gateway-env".path ]
        ++ lib.optionals cfg.nostr.enable [ config.sops.templates."openclaw-nostr-env".path ];

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
            // lib.optionalAttrs cfg.enableTailscaleServe {
              tailscale.mode = "serve";
            };

          discovery.mdns.mode = "minimal";
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

        (lib.mkIf cfg.telegram.enable {
          channels.telegram = {
            enabled = true;
            tokenFile = config.sops.templates."openclaw-telegram-bot-token".path;
            allowFrom = cfg.telegram.allowFrom;
            dmPolicy = cfg.telegram.dmPolicy;
            groupPolicy = cfg.telegram.groupPolicy;
            configWrites = cfg.telegram.configWrites;
          };
        })

        (lib.mkIf cfg.nostr.enable {
          plugins.entries.nostr.enabled = true;

          channels.nostr =
            {
              enabled = true;
              privateKey = "\${NOSTR_PRIVATE_KEY}";
              dmPolicy = cfg.nostr.dmPolicy;
              allowFrom = cfg.nostr.allowFrom;
            }
            // lib.optionalAttrs (cfg.nostr.relays != [ ]) {
              relays = cfg.nostr.relays;
            };
        })

        cfg.extraConfig
      ];

      environment = {
        HOME = config.services.openclaw-gateway.stateDir;
        OPENCLAW_NIX_MODE = "1";
        OPENCLAW_SKIP_BROWSER_CONTROL_SERVER = "1";
        OPENCLAW_SKIP_CANVAS_HOST = "1";
        OPENCLAW_SKIP_GMAIL_WATCHER = "1";
        OPENCLAW_DISABLE_BONJOUR = "1";
      };
    };

    systemd.services.openclaw-gateway.path = lib.optionals config.services.tailscale.enable [
      config.services.tailscale.package
    ];

    environment.systemPackages = [
      openclawCli
      openclawPkgs.openclaw-tools
    ];
  };
}
