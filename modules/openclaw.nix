{ config, lib, pkgs, inputs, ... }:

let
  cfg = config.alanix.openclaw;
  openclawPkgs = inputs.nix-openclaw.packages.${pkgs.stdenv.hostPlatform.system};
  openclawGatewayPackageBase = openclawPkgs.openclaw-gateway;
  openclawGatewayPackage = pkgs.runCommandLocal "openclaw-gateway-with-patched-nostr" {
    nativeBuildInputs = [ pkgs.perl ];
  } ''
    cp -a ${openclawGatewayPackageBase} "$out"
    chmod -R u+w "$out/lib/openclaw/extensions/nostr"

    perl -0pi -e 's@\[\{ kinds: \[4\], "#p": \[pk\], since \}\] as unknown as Parameters<typeof pool\.subscribeMany>\[1\]@\{ kinds: [4], "#p": [pk], since } as Parameters<typeof pool.subscribeMany>[1]@g' \
      "$out/lib/openclaw/extensions/nostr/src/nostr-bus.ts"

    perl -0pi -e 's@\[\n\s*\{\n\s*kinds: \[0\],\n\s*authors: \[pubkey\],\n\s*limit: 1,\n\s*\},\n\s*\] as unknown as Parameters<typeof pool\.subscribeMany>\[1\]@\{\n          kinds: [0],\n          authors: [pubkey],\n          limit: 1,\n        } as Parameters<typeof pool.subscribeMany>[1]@g' \
      "$out/lib/openclaw/extensions/nostr/src/nostr-profile-import.ts"

    perl -0 - "$out/lib/openclaw/extensions/nostr/src/channel.ts" > /dev/null <<'PERL'
use strict;
use warnings;

my $path = shift @ARGV;
local $/;
open my $fh, '<', $path or die "open $path: $!";
my $src = <$fh>;
close $fh;

my $from = <<'FROM';
      // Return cleanup function
      return {
        stop: () => {
          bus.close();
          activeBuses.delete(account.accountId);
          metricsSnapshots.delete(account.accountId);
          ctx.log?.info(`[''${account.accountId}] Nostr provider stopped`);
        },
      };
FROM

my $to = <<'TO';
      try {
        await new Promise<void>((resolve) => {
          if (ctx.abortSignal.aborted) {
            resolve();
            return;
          }
          ctx.abortSignal.addEventListener("abort", () => resolve(), { once: true });
        });
      } finally {
        bus.close();
        activeBuses.delete(account.accountId);
        metricsSnapshots.delete(account.accountId);
        ctx.log?.info("[" + account.accountId + "] Nostr provider stopped");
      }
TO

my $count = ($src =~ s/\Q$from\E/$to/);
die "failed to patch Nostr channel lifecycle in $path\n" unless $count == 1;

open my $out_fh, '>', $path or die "write $path: $!";
print {$out_fh} $src;
close $out_fh;
PERL
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
  nostrProfile = lib.filterAttrs (_: value: value != null) {
    name = cfg.nostr.profile.username;
    displayName = cfg.nostr.profile.displayName;
    about = cfg.nostr.profile.bio;
    picture = cfg.nostr.profile.avatarUrl;
    banner = cfg.nostr.profile.bannerUrl;
    website = cfg.nostr.profile.websiteUrl;
    nip05 = cfg.nostr.profile.nip05;
    lud16 = cfg.nostr.profile.lud16;
  };
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

      accountName = lib.mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Display name for the Nostr account in OpenClaw.";
      };

      defaultAccount = lib.mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Explicit default Nostr account id.";
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

      profile = {
        username = lib.mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Nostr profile username (NIP-01 name).";
        };

        displayName = lib.mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Nostr profile display name (NIP-01 display_name).";
        };

        bio = lib.mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Nostr profile bio/description (NIP-01 about).";
        };

        avatarUrl = lib.mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "HTTPS avatar URL for the Nostr profile.";
        };

        bannerUrl = lib.mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "HTTPS banner URL for the Nostr profile.";
        };

        websiteUrl = lib.mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "HTTPS website URL for the Nostr profile.";
        };

        nip05 = lib.mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Optional NIP-05 identifier (for example user@example.com).";
        };

        lud16 = lib.mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Optional Lightning address (LUD-16).";
        };
      };
    };

    webSearch = {
      enable = lib.mkEnableOption "OpenClaw web search";

      apiKeySecret = lib.mkOption {
        type = types.str;
        default = "brave/api-key";
      };

      braveMode = lib.mkOption {
        type = types.enum [
          "web"
          "llm-context"
        ];
        default = "web";
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
      execStartPre = lib.optionals cfg.nostr.enable [
        "${pkgs.coreutils}/bin/rm -rf ${config.services.openclaw-gateway.stateDir}/extensions/nostr"
      ];
      environmentFiles =
        [ config.sops.templates."openclaw-gateway-env".path ]
        ++ lib.optionals cfg.nostr.enable [ config.sops.templates."openclaw-nostr-env".path ]
        ++ lib.optionals cfg.webSearch.enable [ config.sops.templates."openclaw-brave-env".path ];

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
            // lib.optionalAttrs (cfg.nostr.accountName != null) {
              name = cfg.nostr.accountName;
            }
            // lib.optionalAttrs (cfg.nostr.defaultAccount != null) {
              defaultAccount = cfg.nostr.defaultAccount;
            }
            // lib.optionalAttrs (cfg.nostr.relays != [ ]) {
              relays = cfg.nostr.relays;
            }
            // lib.optionalAttrs (nostrProfile != { }) {
              profile = nostrProfile;
            };
        })

        (lib.mkIf cfg.webSearch.enable {
          tools.web.search =
            {
              enabled = true;
              provider = "brave";
            }
            // lib.optionalAttrs (cfg.webSearch.braveMode != "web") {
              brave.mode = cfg.webSearch.braveMode;
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

      servicePath = lib.optionals config.services.tailscale.enable [ config.services.tailscale.package ];
    };

    environment.systemPackages = [
      openclawCli
      openclawPkgs.openclaw-tools
    ];
  };
}
