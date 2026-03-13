{ config, lib, pkgs, inputs, ... }:

let
  cfg = config.alanix.openclaw;
  openclawPkgs = inputs.nix-openclaw.packages.${pkgs.stdenv.hostPlatform.system};
  openclawGatewayPackage = openclawPkgs.openclaw-gateway;
  openclawSourceInfo = import "${inputs.nix-openclaw}/nix/sources/openclaw-source.nix";
  openclawSource = pkgs.fetchFromGitHub (lib.removeAttrs openclawSourceInfo [ "pnpmDepsHash" ]);
  patchedNostrPluginSource = pkgs.runCommand "openclaw-nostr-plugin-source" { } ''
    cp -R "${openclawSource}/extensions/nostr" "$out"
    chmod -R u+w "$out"
    substituteInPlace "$out/src/nostr-bus.ts" \
      --replace-fail \
      '[{ kinds: [4], "#p": [pk], since }] as unknown as Parameters<typeof pool.subscribeMany>[1]' \
      '{ kinds: [4], "#p": [pk], since } as Parameters<typeof pool.subscribeMany>[1]'
    perl -0pi -e 's@\[\n\s*\{\n\s*kinds: \[0\],\n\s*authors: \[pubkey\],\n\s*limit: 1,\n\s*\},\n\s*\] as unknown as Parameters<typeof pool\.subscribeMany>\[1\]@\{\n            kinds: [0],\n            authors: [pubkey],\n            limit: 1,\n          } as Parameters<typeof pool.subscribeMany>[1]@g' \
      "$out/src/nostr-profile-import.ts"
  '';
  nostrPluginInstallRevision =
    "${openclawSourceInfo.rev}-subscribe-many-filter-fix-v2";
  bundledPluginsDir = pkgs.runCommand "openclaw-bundled-plugins" { } ''
    mkdir -p "$out"
    cp -R "${openclawGatewayPackage}/lib/openclaw/extensions/." "$out/"
    rm -rf "$out/nostr"
  '';
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
  nostrPluginInstallDir = "${config.services.openclaw-gateway.stateDir}/extensions/nostr";
  installNostrPluginScript = pkgs.writeShellScript "openclaw-install-nostr-plugin" ''
    set -euo pipefail

    src_dir="${patchedNostrPluginSource}"
    target_dir="${nostrPluginInstallDir}"
    rev_file="$target_dir/.nix-openclaw-source-rev"

    needs_install=0
    if [ ! -d "$target_dir" ] || [ ! -f "$rev_file" ]; then
      needs_install=1
    elif [ "$(cat "$rev_file")" != "${nostrPluginInstallRevision}" ]; then
      needs_install=1
    fi

    if [ "$needs_install" -eq 0 ]; then
      exit 0
    fi

    rm -rf "$target_dir"
    mkdir -p "$(dirname "$target_dir")"
    cp -R "$src_dir" "$target_dir"
    chmod -R u+w "$target_dir"
    (
      cd "$target_dir"
      npm install --omit=dev --omit=peer --silent --ignore-scripts
    )
    printf '%s\n' "${nostrPluginInstallRevision}" > "$rev_file"
  '';
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
          plugins = {
            allow = [ "nostr" ];
            load.paths = [ nostrPluginInstallDir ];
          };

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
      }
      // lib.optionalAttrs cfg.nostr.enable {
        OPENCLAW_BUNDLED_PLUGINS_DIR = "${bundledPluginsDir}";
      };

      execStartPre = lib.optionals cfg.nostr.enable [ "${installNostrPluginScript}" ];
      servicePath =
        lib.optionals cfg.nostr.enable [ pkgs.nodejs ]
        ++ lib.optionals config.services.tailscale.enable [ config.services.tailscale.package ];
    };

    environment.systemPackages = [
      openclawCli
      openclawPkgs.openclaw-tools
    ];
  };
}
