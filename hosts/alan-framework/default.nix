{ hostname, ... }:

{
  system = "x86_64-linux";

  module = { config, pkgs, pkgs-unstable, ... }: {
    imports = [
      ./hardware-configuration.nix
      ./secrets.nix
    ];

    alanix.system = {
      stateVersion = "25.11";
      timeZone = "America/Chicago";
      locale = "en_US.UTF-8";
      enableSystemdBoot = true;
      canTouchEfiVariables = true;
      allowUnfree = true;
      experimentalFeatures = [ "nix-command" "flakes" ];
      enableNixLd = true;
      enableNetworkManager = true;
      enableFirewall = true;
      packages = with pkgs; [
        age
        bind
        caddy
        curl
        git
        htop
        jq
        lm_sensors
        lsof
        nak
        ripgrep
        python3
        restic
        sops
        tree
        unzip
        zip
        p7zip
        parted
        dosfstools
        wget
        usbutils
      ];
      unstablePackages = with pkgs-unstable; [
        nodejs_24
      ];
      swapDevices = [
        # This host keeps several large local models warm; swap gives the box
        # some breathing room during cache churn and prevents brief OOM outages.
        {
          device = "/swapfile";
          size = 32768;
        }
      ];
    };

    alanix.users = {
      mutableUsers = false;
      accounts.buddia = {
        enable = true;
        isNormalUser = true;
        passwordlessSudo = true;
        extraGroups = [ "wheel" "networkmanager" "input" ];
        hashedPasswordFile = config.sops.secrets."password-hashes/buddia".path;

        sshPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILb22RXxaO/RmZkheVk+Ma9WBXABHN/IrDGq5RbBIunC fife.alan@protonmail.com";
        authorizedHosts = [ "alan-big-nixos" "alan-framework-laptop" "alan-home" "alan-node" "alan-optiplex" "alan-tv" "fife-tv" "randy-big-nixos" ];

        home = {
          enable = true;
          directory = "/home/buddia";
          stateVersion = "25.11";
          packages = with pkgs; [
            tmux
          ];
          unstablePackages = with pkgs-unstable; [ yt-dlp ];
          modules = [
            {
              home.sessionPath = [ "/home/buddia/.local/bin" ];
              home.sessionVariables = {
                NPM_CONFIG_PREFIX = "/home/buddia/.local";
                NODE_PATH = "/home/buddia/.local/lib/node_modules";
              };
            }
          ];
        };

        git = {
          enable = true;
          github.user = "zabuddia";
          user.name = "Alan Fife";
          user.email = "fife.alan@protonmail.com";
          init.defaultBranch = "main";
          extraSettings = { };
        };

        sh.enable = true;
        agentControl.enable = true;

        desktop = {
          enable = true;
          profile = "sway/default";
        };
        azahar.enable = true;
        chromium.enable = true;
        dolphin = {
          enable = true;
          gameDirs = [
            "${config.alanix.syncthing.syncRoot}/games/roms/gamecube"
            "${config.alanix.syncthing.syncRoot}/games/roms/wii"
          ];
        };
        melonds.enable = true;
        retroarch.enable = true;
        ryubing = {
          enable = true;
          gameDirs = [ "${config.alanix.syncthing.syncRoot}/games/roms/switch" ];
        };
        vscode.enable = true;
      };
    };

    alanix.desktop = {
      enable = true;
      profile = "sway";
      profiles.sway = {
        autoLogin = {
          enable = true;
          user = "buddia";
        };
        createHeadlessOutput = true;
        outputRules = [
          "output HEADLESS-1 resolution 1920x1080"
        ];
        idle = {
          lockSeconds = null;
          displayOffSeconds = null;
          suspendSeconds = null;
        };
      };
    };

    alanix.ssh = {
      enable = true;
      openFirewallOnTailscale = true;
      startAgent = true;
      hostPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDJKhkgpVCtwYKMoUpybQejUcyAcuDTRdEk0981whwds";
    };
    alanix.tailscale = {
      enable = true;
      loginServer = "https://headscale.fifefin.com";
      address = "alan-framework";
      acceptRoutes = true;
      operator = "buddia";
    };

    # OpenClaw is restarted by Home Manager during some system activations.
    # Run the control-plane rebuild as a system service so it is not a child of
    # the gateway and can finish after the gateway temporarily disconnects.
    systemd.services.alanix-rebuild = {
      description = "Durable NixOS rebuild for alan-framework";
      restartIfChanged = false;
      stopIfChanged = false;
      path = [
        config.system.build.nixos-rebuild
        pkgs.coreutils
        pkgs.git
        pkgs.nix
      ];
      serviceConfig = {
        Type = "oneshot";
        WorkingDirectory = "/home/buddia/.nixos";
        TimeoutStartSec = "infinity";
      };
      script = ''
        exec nixos-rebuild switch \
          --flake path:/home/buddia/.nixos#alan-framework
      '';
    };

    alanix.openclaw = {
      user = "buddia";
      actual = {
        enable = true;
        serverUrl = "https://actual.fifefin.com";
        passwordFile = config.sops.secrets."actual-passwords/server-password".path;
        syncIdFile = config.sops.secrets."actual-passwords/budget-sync-id".path;
        allowMutations = false;
      };
      bitcoin.enable = true;
      browser.enable = true;
      desktop = {
        enable = true;
        hosts = [
          "alan-big-nixos"
          "alan-framework"
          "alan-framework-laptop"
          "alan-home"
          "alan-node"
          "alan-optiplex"
          "alan-tv"
          "fife-tv"
          "randy-big-nixos"
        ];
      };
      files = {
        enable = true;
        root = "${config.alanix.syncthing.syncRoot}/filebrowser/users/buddia";
      };
      forgejo = {
        enable = true;
        passwordFile = config.sops.secrets."forgejo-passwords/buddia".path;
      };
      kodi.enable = true;
      media = {
        jellyfin = {
          enable = true;
          passwordFile = config.sops.secrets."jellyfin-passwords/buddia".path;
        };
        navidrome = {
          enable = true;
          passwordFile = config.sops.secrets."navidrome-passwords/buddia".path;
        };
        audiobookshelf = {
          enable = true;
          passwordFile = config.sops.secrets."audiobookshelf-passwords/buddia".path;
        };
      };
      radicale = {
        enable = true;
        passwordFile = config.sops.secrets."radicale-passwords/buddia".path;
      };
      gateway = {
        enable = true;
        enableFullExec = true;
        authMode = "none";
        dangerouslyDisableControlUiDeviceAuth = true;
        port = 18789;
        expose.tailscale = {
          enable = true;
          port = 18790;
        };
        workspaceFiles = {
          "AGENTS.md" = pkgs.writeText "openclaw-agents.md" (
            builtins.readFile ../../modules/services/openclaw/workspace/AGENTS.md
            + "\n\n"
            + builtins.readFile ../../modules/services/openclaw/workspace/CLUSTER.md
          );
          "CLUSTER.md" = ../../modules/services/openclaw/workspace/CLUSTER.md;
          "HEARTBEAT.md" = ../../modules/services/openclaw/workspace/HEARTBEAT.md;
          "IDENTITY.md" = ../../modules/services/openclaw/workspace/IDENTITY.md;
          "MEMORY.md" = ../../modules/services/openclaw/workspace/MEMORY.md;
          "POLICY.md" = ../../modules/services/openclaw/workspace/POLICY.md;
          "SERVICES.md" = ../../modules/services/openclaw/workspace/SERVICES.md;
          "SOUL.md" = ../../modules/services/openclaw/workspace/SOUL.md;
          "TOOLS.md" = ../../modules/services/openclaw/workspace/TOOLS.md;
          "USER.md" = ../../modules/services/openclaw/workspace/USER.md;
        };
        config = {
          gateway.controlUi.allowedOrigins = [
            "http://100.64.0.4:18790"
            "http://alan-framework:18790"
            "http://alan-framework.tail.fifefin.com:18790"
          ];
          models.providers.local-litellm = {
            api = "openai-completions";
            baseUrl = "http://127.0.0.1:4000/v1";
            apiKey = "local-litellm";
            authHeader = false;
            injectNumCtxForOpenAICompat = true;
            models = [
              {
                id = "qwen3.8-27b";
                name = "Qwen3.8 27B";
                api = "openai-completions";
                reasoning = true;
                input = [ "text" "image" ];
                contextWindow = 131072;
                maxTokens = 32768;
              }
              {
                id = "ornith-1.5-35b-a3b";
                name = "Ornith 1.5 35B A3B";
                api = "openai-completions";
                reasoning = true;
                input = [ "text" ];
                contextWindow = 65536;
                maxTokens = 32768;
              }
            ];
          };
          agents = {
            defaults = {
              workspace = "/home/buddia/.openclaw/workspaces/jarvis";
              skipBootstrap = true;
              heartbeat = {
                every = "1h";
                includeSystemPromptSection = false;
                isolatedSession = true;
                lightContext = true;
                skipWhenBusy = true;
                target = "telegram";
                to = "7336229793";
              };
              compaction.memoryFlush = {
                enabled = true;
                forceFlushTranscriptBytes = "512kb";
                systemPrompt = ''
                  Preserve only verified, reusable context. Prioritize stable
                  operator preferences, corrections, system topology, naming
                  conventions, and durable decisions. Never store secrets,
                  credentials, guesses, transient failures, routine commands,
                  or historical authorization.
                '';
                prompt = ''
                  Write lasting context to MEMORY.md or today's dated memory
                  note as appropriate. Update superseded facts instead of
                  duplicating them. Reply with exactly NO_REPLY if there is
                  nothing worth retaining.
                '';
              };
              memorySearch = {
                provider = "openai-compatible";
                model = "qwen3-embedding-4b";
                fallback = "none";
                remote = {
                  baseUrl = "http://127.0.0.1:8082/v1";
                  apiKey = "local-embeddings";
                  nonBatchConcurrency = 1;
                };
                sync.embeddingBatchTimeoutSeconds = 600;
                query.hybrid = {
                  enabled = true;
                  mmr.enabled = true;
                  temporalDecay = {
                    enabled = true;
                    halfLifeDays = 90;
                  };
                };
              };
              model = {
                primary = "local-litellm/ornith-1.5-35b-a3b";
                fallbacks = [ ];
              };
              imageModel = {
                primary = "local-litellm/qwen3.8-27b";
                fallbacks = [ ];
                timeoutMs = 180000;
              };
              models = {
                "local-litellm/qwen3.8-27b" = {
                  alias = "qwen3.8-27b";
                  streaming = true;
                };
                "local-litellm/ornith-1.5-35b-a3b" = {
                  alias = "ornith-1.5-35b-a3b";
                  streaming = true;
                };
              };
            };
            list = [
              {
                id = "jarvis";
                default = true;
                name = "Jarvis";
                workspace = "/home/buddia/.openclaw/workspaces/jarvis";
                agentDir = "/home/buddia/.openclaw/agents/jarvis/agent";
                model = {
                  primary = "local-litellm/ornith-1.5-35b-a3b";
                  fallbacks = [ ];
                };
              }
            ];
          };
          hooks.internal = {
            enabled = true;
            entries."session-memory" = {
              enabled = true;
              messages = 15;
              llmSlug = false;
            };
          };
          tools = {
            profile = "minimal";
            alsoAllow = [
              "exec"
              "process"
              "cron"
              "read"
              "write"
              "edit"
              "memory_get"
              "memory_search"
              "image"
              "web_search"
              "web_fetch"
            ];
            loopDetection.enabled = true;
            elevated.enabled = false;
            exec = {
              mode = "full";
              host = "gateway";
              strictInlineEval = false;
              timeoutSec = 60;
            };
            fs.workspaceOnly = true;
            web = {
              search = {
                enabled = true;
                provider = "searxng";
              };
              fetch.enabled = true;
            };
          };
          plugins.load.paths = [
            "${pkgs.runCommand "openclaw-searxng-plugin-${pkgs-unstable.openclaw.version}" { } ''
              cp -R ${pkgs-unstable.openclaw}/lib/openclaw/extensions/searxng "$out"
            ''}"
          ];
          plugins.entries.searxng = {
            enabled = true;
            config.webSearch = {
              baseUrl = "http://alan-big-nixos:18888";
              language = "en";
            };
          };
          plugins.entries."memory-core" = {
            enabled = true;
            config.dreaming = {
              enabled = true;
              frequency = "0 3 * * *";
              timezone = "America/Chicago";
            };
          };
          channels.telegram = {
            enabled = true;
            tokenFile = config.sops.secrets."openclaw/telegram-bot-token".path;
            dmPolicy = "allowlist";
            allowFrom = [ "7336229793" ];
            groupPolicy = "disabled";
          };
          commands.ownerAllowFrom = [ "telegram:7336229793" ];
          session.dmScope = "per-channel-peer";
        };
      };

      homeAssistant = {
        enable = true;
        accessTokenFile = config.sops.secrets."home-assistant/openclaw-token".path;
      };
    };

    alanix.wifi.radio.enable = false;

    alanix.syncthing = {
      enable = true;
      transport = "tailscale";
      deviceId = "EKNKF5K-6DW57FP-M2LGDA4-NTASEPT-EWD5GCI-KCSIOXJ-LO3PZFC-A6CWOAH";
      listenPort = 22000;
      peers = [
        "alan-big-nixos"
        "alan-framework-laptop"
        "alan-optiplex"
        "alan-tv"
        "randy-big-nixos"
      ];
      folderSets = [
        "emulation-azahar"
        "emulation-dolphin"
        "emulation-melonds"
        "emulation-n64"
        "emulation-retroarch"
        "emulation-ryujinx"
        "filebrowser-buddia-files"
      ];
      linkFolderSets = [
        "emulation-azahar"
        "emulation-dolphin"
        "emulation-melonds"
        "emulation-ryujinx"
      ];
      externalDevices.pixel-fold = {
        id = "BT23SPJ-ICTEBQ7-GJTDRQT-LCUQ773-U63QFZR-472O3YA-2KRJ4KY-AMPZ7AF";
        addresses = [ "tcp://pixel-fold:22000" ];
        folderSets = [
          "emulation-azahar"
          "emulation-dolphin"
          "emulation-melonds"
          "emulation-n64"
          "emulation-retroarch"
        ];
      };
    };

    alanix.llm = {
      enable = true;
      backend = "vulkan";
      stateDir = "/var/lib/llm";
      dashboard = {
        enable = true;
        listenAddress = "127.0.0.1";
        port = 9843;
        recentLogLines = 40;
        expose = {
          tailscale = {
            enable = true;
            port = 19843;
          };
          tor = {
            enable = true;
            publicPort = 80;
            secretKeyBase64Secret = "tor/llm-dashboard/alan-framework/secret-key-base64";
            hostname = "vx4hkzxkj6s2wslxahmnm5evo5hv3xc75sdgittbnulx4g2upkhvegad.onion";
          };
        };
      };
      litellm = {
        enable = true;
        host = "0.0.0.0";
        port = 4000;
      };
      instances = {
        # Retained in the model cache for optional future use, but not loaded.
        chat = {
          enable = false;
          runtime = "llama";
          host = "127.0.0.1";
          listenHost = "0.0.0.0";
          port = 8083;
          alias = "qwen3.6-35b-a3b";
          ctxSize = 131072;
          batchSize = 4096;
          ubatchSize = 1024;
          # Keep two independent prompt-cache slots so Voice PE and another
          # Jarvis session do not constantly evict one another's long prefix.
          parallel = 2;
          gpuLayers = "all";
          flashAttention = "on";
          threads = null;
          threadsBatch = null;
          mmap = true;
          mlock = false;
          input = [ "text" ];
          imageMinTokens = null;
          imageMaxTokens = null;
          model = {
            name = "qwen3.6-35b-a3b";
            path = null;
            url = null;
            hfRepo = "unsloth/Qwen3.6-35B-A3B-GGUF";
            hfFile = "Qwen3.6-35B-A3B-UD-Q5_K_XL.gguf";
            mmprojPath = null;
            mmprojUrl = null;
          };
          # OpenClaw and Open WebUI expect plain assistant content here; when
          # Qwen thinks out loud it can stall chats and return empty content.
          extraArgs = [
            "--reasoning"
            "off"
          ];
        };

        # Optional multimodal OpenClaw model. Its matching projector enables
        # native image input, while the MTP sidecar provides four-token drafting.
        qwen38 = {
          enable = true;
          runtime = "llama";
          host = "127.0.0.1";
          listenHost = "0.0.0.0";
          port = 8086;
          alias = "qwen3.8-27b";
          ctxSize = 131072;
          batchSize = 2048;
          ubatchSize = 512;
          parallel = 1;
          gpuLayers = "all";
          flashAttention = "on";
          threads = null;
          threadsBatch = null;
          mmap = true;
          mlock = false;
          input = [
            "text"
            "image"
          ];
          imageMinTokens = null;
          imageMaxTokens = null;
          model = {
            name = "qwen3.8-27b";
            path = null;
            url = null;
            hfRepo = "unsloth/Qwen3.8-27B-GGUF";
            hfFile = "Qwen3.8-27B-UD-Q5_K_XL.gguf";
            mmprojPath = null;
            mmprojUrl = "https://huggingface.co/unsloth/Qwen3.8-27B-GGUF/resolve/main/mmproj-F16.gguf";
          };
          extraArgs = [
            "--fit"
            "off"
            "--cache-type-k"
            "q8_0"
            "--cache-type-v"
            "q8_0"
            "--spec-type"
            "draft-mtp"
            "--spec-draft-hf"
            "ggml-org/Qwen3.8-27B-GGUF:Q4_0"
            "--spec-draft-ngl"
            "all"
            "--spec-draft-type-k"
            "q8_0"
            "--spec-draft-type-v"
            "q8_0"
            "--spec-draft-n-max"
            "4"
            "--reasoning"
            "on"
            "--temp"
            "1.0"
            "--top-p"
            "0.95"
            "--top-k"
            "20"
            "--min-p"
            "0.0"
            "--presence-penalty"
            "0.0"
            "--repeat-penalty"
            "1.0"
          ];
        };

        # Optional reasoning/tool-calling model for OpenClaw. llama.cpp uses
        # the official tool-aware Jinja template embedded in this GGUF.
        ornith = {
          enable = true;
          runtime = "llama";
          host = "127.0.0.1";
          listenHost = "0.0.0.0";
          port = 8088;
          alias = "ornith-1.5-35b-a3b";
          ctxSize = 65536;
          batchSize = 2048;
          ubatchSize = 512;
          parallel = 1;
          gpuLayers = "all";
          flashAttention = "on";
          threads = null;
          threadsBatch = null;
          mmap = true;
          mlock = false;
          input = [ "text" ];
          imageMinTokens = null;
          imageMaxTokens = null;
          model = {
            name = "ornith-1.5-35b-a3b";
            path = null;
            url = null;
            hfRepo = "ornith-ai/Ornith-1.5-35B-A3B-GGUF";
            hfFile = "Ornith-1.5-35B-Q4_K_M.gguf";
            mmprojPath = null;
            mmprojUrl = null;
          };
          extraArgs = [
            "--fit"
            "off"
            "--cache-type-k"
            "f16"
            "--cache-type-v"
            "f16"
            "--jinja"
            "--reasoning"
            "on"
            "--temp"
            "0.25"
            "--top-p"
            "0.95"
            "--top-k"
            "20"
          ];
        };

        # Retained in the model cache for optional future use, but not loaded.
        # The IQ4_XS quant keeps this 80B-total/3B-active MoE model compact.
        coder = {
          enable = false;
          runtime = "llama";
          host = "127.0.0.1";
          listenHost = "0.0.0.0";
          port = 8087;
          alias = "qwen3-coder-next";
          ctxSize = 65536;
          batchSize = 2048;
          ubatchSize = 512;
          parallel = 1;
          gpuLayers = "all";
          flashAttention = "on";
          threads = null;
          threadsBatch = null;
          mmap = true;
          mlock = false;
          input = [ "text" ];
          imageMinTokens = null;
          imageMaxTokens = null;
          model = {
            name = "qwen3-coder-next";
            path = null;
            url = null;
            hfRepo = "unsloth/Qwen3-Coder-Next-GGUF";
            hfFile = "Qwen3-Coder-Next-UD-IQ4_XS.gguf";
            mmprojPath = null;
            mmprojUrl = null;
          };
          extraArgs = [ ];
        };

        # Retained in the model cache for optional future use, but not loaded.
        fast = {
          enable = false;
          runtime = "llama";
          host = "127.0.0.1";
          listenHost = "0.0.0.0";
          port = 8084;
          alias = "qwen3-8b";
          ctxSize = 40960;
          batchSize = 4096;
          ubatchSize = 1024;
          parallel = 1;
          gpuLayers = "all";
          flashAttention = "on";
          threads = null;
          threadsBatch = null;
          mmap = true;
          mlock = false;
          input = [ "text" ];
          imageMinTokens = null;
          imageMaxTokens = null;
          model = {
            name = "qwen3-8b";
            path = null;
            url = null;
            hfRepo = "Qwen/Qwen3-8B-GGUF";
            hfFile = "Qwen3-8B-Q4_K_M.gguf";
            mmprojPath = null;
            mmprojUrl = null;
          };
          extraArgs = [
            "--reasoning"
            "off"
          ];
        };

        # Retained in the model cache for optional future use, but not loaded.
        vision = {
          enable = false;
          runtime = "llama";
          host = "127.0.0.1";
          listenHost = "0.0.0.0";
          port = 8081;
          alias = "qwen3-vl-30b-a3b-instruct";
          ctxSize = 32768;
          batchSize = 2048;
          ubatchSize = 512;
          parallel = 1;
          gpuLayers = "all";
          flashAttention = "on";
          threads = null;
          threadsBatch = null;
          mmap = true;
          mlock = false;
          input = [
            "text"
            "image"
          ];
          imageMinTokens = null;
          imageMaxTokens = null;
          model = {
            name = "qwen3-vl-30b-a3b-instruct";
            path = null;
            url = null;
            hfRepo = "unsloth/Qwen3-VL-30B-A3B-Instruct-GGUF";
            hfFile = "Qwen3-VL-30B-A3B-Instruct-Q4_K_M.gguf";
            mmprojPath = null;
            mmprojUrl = "https://huggingface.co/unsloth/Qwen3-VL-30B-A3B-Instruct-GGUF/resolve/main/mmproj-F16.gguf";
          };
          extraArgs = [ ];
        };

        # Dedicated local embedding model for OpenClaw's hybrid memory index.
        embeddings = {
          enable = true;
          runtime = "llama";
          host = "127.0.0.1";
          listenHost = "127.0.0.1";
          port = 8082;
          alias = "qwen3-embedding-4b";
          ctxSize = 8192;
          # llama.cpp embeddings require n_batch <= n_ubatch.
          batchSize = 512;
          ubatchSize = 512;
          parallel = 1;
          gpuLayers = "all";
          flashAttention = "on";
          threads = null;
          threadsBatch = null;
          mmap = true;
          mlock = false;
          input = [ "text" ];
          imageMinTokens = null;
          imageMaxTokens = null;
          model = {
            name = "qwen3-embedding-4b";
            path = null;
            url = null;
            hfRepo = "Qwen/Qwen3-Embedding-4B-GGUF";
            hfFile = "Qwen3-Embedding-4B-Q5_K_M.gguf";
            mmprojPath = null;
            mmprojUrl = null;
          };
          extraArgs = [ "--embeddings" ];
        };

        # Audio transcription model, exposed directly and through LiteLLM.
        transcribe = {
          enable = true;
          runtime = "whisper";
          host = "127.0.0.1";
          listenHost = "0.0.0.0";
          port = 8085;
          alias = "whisper-small";
          threads = null;
          input = [ "audio" ];
          language = "auto";
          translate = false;
          processors = 1;
          convertAudio = true;
          requestPath = "/v1/audio/transcriptions";
          inferencePath = "";
          gpu = true;
          model = {
            name = "small";
            path = null;
            url = null;
            hfRepo = null;
            hfFile = null;
            mmprojPath = null;
            mmprojUrl = null;
            downloadName = "small";
          };
          extraArgs = [ ];
        };
      };
    };

    alanix.wyoming = {
      enable = true;
      openFirewallOnTailscale = true;
      whisper = {
        enable = true;
        listenAddress = "0.0.0.0";
        port = 10300;
        sttLibrary = "faster-whisper";
        model = "large-v3-turbo";
        language = "en";
        device = "cpu";
        computeType = "int8";
        cpuThreads = 16;
        beamSize = 1;
      };
      piper = {
        enable = true;
        listenAddress = "0.0.0.0";
        port = 10200;
        voice = "en_US-lessac-medium";
      };
    };

    alanix.remote-desktop = {
      enable = true;
      autoStart = true;
      port = 5900;
      output = "HEADLESS-1";
    };

    alanix.sunshine = {
      enable = true;
      autoStart = true;
      openFirewall = true;
      capSysAdmin = true;
      webUi = {
        port = 47990;
        username = "buddia";
        passwordFile = config.sops.secrets."sunshine-web-ui-passwords/alan-framework".path;
      };
    };
  };
}
