{ config, lib, pkgs, pkgs-unstable, ... }:

let
  cfg = config.alanix.llm;
  inherit (lib) types;
  serviceExposure = import ../../../lib/mkServiceExposure.nix { inherit lib pkgs; };
  yamlFormat = pkgs.formats.yaml { };

  llamaPackage =
    if cfg.backend == "cpu" then
      pkgs-unstable.llama-cpp
    else if cfg.backend == "rocm" then
      pkgs-unstable.llama-cpp-rocm
    else
      pkgs-unstable.llama-cpp-vulkan;

  whisperPackage =
    if cfg.backend == "vulkan" then
      pkgs.whisper-cpp-vulkan
    else
      pkgs.whisper-cpp;

  normalizeLocalAddress =
    address:
    if address == "0.0.0.0" then
      "127.0.0.1"
    else if address == "::" then
      "::1"
    else
      address;

  mkUrl =
    {
      scheme,
      host,
      port,
      path ? "/",
    }:
    let
      defaultPort = if scheme == "https" then 443 else 80;
      hostText =
        if lib.hasInfix ":" host && !(lib.hasPrefix "[" host) && !(lib.hasSuffix "]" host) then
          "[${host}]"
        else
          host;
      portSuffix = if port == defaultPort then "" else ":${toString port}";
    in
    "${scheme}://${hostText}${portSuffix}${path}";

  mkModelOptions = descriptionPrefix: {
    name = lib.mkOption {
      type = types.str;
      description = "${descriptionPrefix} model name/alias seed.";
    };

    path = lib.mkOption {
      type = types.nullOr types.str;
      default = null;
    };

    url = lib.mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "${descriptionPrefix} remote GGUF URL passed to llama-server via --model-url.";
    };

    hfRepo = lib.mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "${descriptionPrefix} Hugging Face repo passed to llama-server via --hf-repo.";
    };

    hfFile = lib.mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "${descriptionPrefix} optional Hugging Face GGUF file name passed via --hf-file.";
    };

    mmprojPath = lib.mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "${descriptionPrefix} optional multimodal projector GGUF path passed via --mmproj.";
    };

    mmprojUrl = lib.mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "${descriptionPrefix} optional multimodal projector GGUF URL passed via --mmproj-url.";
    };

    downloadName = lib.mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "${descriptionPrefix} whisper.cpp built-in model name to auto-download.";
    };
  };

  mkInstanceSubmodule = types.submodule ({ name, ... }: {
    options = {
      enable = lib.mkEnableOption "model service instance ${name}";

      runtime = lib.mkOption {
        type = types.enum [ "llama" "whisper" ];
        description = "Local model runtime backing this instance.";
      };

      host = lib.mkOption {
        type = types.str;
      };

      listenHost = lib.mkOption {
        type = types.str;
        description = "Address/interface the runtime server binds to.";
      };

      port = lib.mkOption {
        type = types.port;
      };

      alias = lib.mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Model alias exposed by the runtime's OpenAI-compatible API.";
      };

      ctxSize = lib.mkOption {
        type = types.nullOr types.int;
        default = null;
      };

      batchSize = lib.mkOption {
        type = types.nullOr types.int;
        default = null;
      };

      ubatchSize = lib.mkOption {
        type = types.nullOr types.int;
        default = null;
      };

      parallel = lib.mkOption {
        type = types.nullOr types.int;
        default = null;
      };

      gpuLayers = lib.mkOption {
        type = types.nullOr (
          types.oneOf [
            types.int
            (types.enum [ "auto" "all" ])
          ]
        );
        default = null;
      };

      flashAttention = lib.mkOption {
        type = types.nullOr (types.enum [ "on" "off" "auto" ]);
        default = null;
      };

      threads = lib.mkOption {
        type = types.nullOr types.int;
        default = null;
        description = "Worker threads. Null means use all available threads via nproc.";
      };

      threadsBatch = lib.mkOption {
        type = types.nullOr types.int;
        default = null;
        description = "Prompt/batch threads for llama.cpp. Null means match threads.";
      };

      mmap = lib.mkOption {
        type = types.nullOr types.bool;
        default = null;
      };

      mlock = lib.mkOption {
        type = types.nullOr types.bool;
        default = null;
      };

      input = lib.mkOption {
        type = types.listOf (types.enum [ "text" "image" "audio" ]);
        description = "Capabilities advertised to OpenClaw for this model.";
      };

      imageMinTokens = lib.mkOption {
        type = types.nullOr types.int;
        default = null;
      };

      imageMaxTokens = lib.mkOption {
        type = types.nullOr types.int;
        default = null;
      };

      language = lib.mkOption {
        type = types.str;
        default = "auto";
        description = "whisper.cpp spoken language. Use auto for detection.";
      };

      translate = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Whether whisper.cpp should translate speech to English.";
      };

      processors = lib.mkOption {
        type = types.int;
        default = 1;
        description = "whisper.cpp processor count.";
      };

      convertAudio = lib.mkOption {
        type = types.bool;
        default = true;
        description = "Whether whisper.cpp should invoke ffmpeg to transcode uploads to WAV.";
      };

      requestPath = lib.mkOption {
        type = types.str;
        default = "/v1/audio/transcriptions";
        description = "HTTP request path exposed by whisper-server.";
      };

      inferencePath = lib.mkOption {
        type = types.str;
        default = "";
        description = "Optional whisper-server inference path.";
      };

      gpu = lib.mkOption {
        type = types.bool;
        default = cfg.backend == "vulkan";
        description = "Whether whisper.cpp should try to use GPU acceleration.";
      };

      model = mkModelOptions "Instance ${name}";

      extraArgs = lib.mkOption {
        type = types.listOf types.str;
        default = [ ];
      };
    };
  });

  enabledInstances = lib.filterAttrs (_: instance: instance.enable) cfg.instances;
  enabledPorts = lib.mapAttrsToList (_: instance: instance.port) enabledInstances;

  isLlamaInstance = instance: instance.runtime == "llama";
  isWhisperInstance = instance: instance.runtime == "whisper";

  hasLlamaInstance = lib.any isLlamaInstance (lib.attrValues enabledInstances);
  hasWhisperInstance = lib.any isWhisperInstance (lib.attrValues enabledInstances);

  mkModelAlias = instance:
    if instance.alias != null then instance.alias else instance.model.name;

  mkWhisperModelPath =
    instance:
    if instance.model.path != null then
      instance.model.path
    else
      "${cfg.stateDir}/models/whisper/ggml-${instance.model.downloadName}.bin";

  mkLlamaModelArgs = instance:
    if instance.model.path != null then
      [ "--model" instance.model.path ]
    else if instance.model.url != null then
      [ "--model-url" instance.model.url ]
    else
      [ "--hf-repo" instance.model.hfRepo ]
      ++ (lib.optionals (instance.model.hfFile != null) [ "--hf-file" instance.model.hfFile ]);

  mkLlamaStaticArgs = instance:
    [
      "--host"
      instance.listenHost
      "--port"
      (toString instance.port)
      "--alias"
      (mkModelAlias instance)
      "--ctx-size"
      (toString instance.ctxSize)
      "--batch-size"
      (toString instance.batchSize)
      "--ubatch-size"
      (toString instance.ubatchSize)
      "--parallel"
      (toString instance.parallel)
      "--flash-attn"
      instance.flashAttention
      "--gpu-layers"
      (toString instance.gpuLayers)
    ]
    ++ (lib.optionals instance.mlock [ "--mlock" ])
    ++ (lib.optionals (!instance.mmap) [ "--no-mmap" ])
    ++ (mkLlamaModelArgs instance)
    ++ (lib.optionals (instance.model.mmprojPath != null) [ "--mmproj" instance.model.mmprojPath ])
    ++ (lib.optionals (instance.model.mmprojUrl != null) [ "--mmproj-url" instance.model.mmprojUrl ])
    ++ (lib.optionals (instance.imageMinTokens != null) [ "--image-min-tokens" (toString instance.imageMinTokens) ])
    ++ (lib.optionals (instance.imageMaxTokens != null) [ "--image-max-tokens" (toString instance.imageMaxTokens) ])
    ++ instance.extraArgs;

  mkWhisperStaticArgs = instance:
    [
      "--host"
      instance.listenHost
      "--port"
      (toString instance.port)
      "--model"
      (mkWhisperModelPath instance)
      "--language"
      instance.language
      "--processors"
      (toString instance.processors)
      "--request-path"
      instance.requestPath
      "--inference-path"
      instance.inferencePath
    ]
    ++ (lib.optionals instance.translate [ "--translate" ])
    ++ (lib.optionals instance.convertAudio [ "--convert" ])
    ++ (lib.optionals (!instance.gpu) [ "--no-gpu" ])
    ++ instance.extraArgs;

  mkStartScript = instanceName: instance:
    if isLlamaInstance instance then
      pkgs.writeShellScript "alanix-llama-server-${instanceName}" ''
        set -euo pipefail

        threads=${if instance.threads == null then "$(${pkgs.coreutils}/bin/nproc)" else toString instance.threads}
        threads_batch=${if instance.threadsBatch == null then "$threads" else toString instance.threadsBatch}

        exec ${lib.getExe' llamaPackage "llama-server"} \
          --threads "$threads" \
          --threads-batch "$threads_batch" \
          ${lib.escapeShellArgs (mkLlamaStaticArgs instance)}
      ''
    else
      pkgs.writeShellScript "alanix-whisper-server-${instanceName}" ''
        set -euo pipefail

        threads=${if instance.threads == null then "$(${pkgs.coreutils}/bin/nproc)" else toString instance.threads}
        model_dir=${lib.escapeShellArg "${cfg.stateDir}/models/whisper"}
        model_path=${lib.escapeShellArg (mkWhisperModelPath instance)}

        ${lib.optionalString (instance.model.path == null) ''
          mkdir -p "$model_dir"
          if [ ! -f "$model_path" ]; then
            cd "$model_dir"
            ${lib.getExe' whisperPackage "whisper-cpp-download-ggml-model"} ${lib.escapeShellArg instance.model.downloadName}
          fi
        ''}

        exec ${lib.getExe' whisperPackage "whisper-server"} \
          --threads "$threads" \
          ${lib.escapeShellArgs (mkWhisperStaticArgs instance)}
      '';

  mkServiceName = instanceName: instance:
    let
      baseName = if isLlamaInstance instance then "llama-server" else "whisper-server";
    in
    if instanceName == "default" then baseName else "${baseName}-${instanceName}";

  instanceApiBasePath = instance:
    if isLlamaInstance instance || lib.hasPrefix "/v1/" instance.requestPath then
      "/v1"
    else
      "";

  instanceEndpointPath = instance:
    if isLlamaInstance instance then
      "/v1"
    else
      instance.requestPath + instance.inferencePath;

  instanceHealthPath = instance:
    if isLlamaInstance instance then
      "/v1/models"
    else
      instance.requestPath + instance.inferencePath;

  dashboardCfg = cfg.dashboard;
  dashboardEndpoint = {
    address = dashboardCfg.listenAddress;
    port = dashboardCfg.port;
    protocol = "http";
  };

  litellmConfig =
    yamlFormat.generate "alanix-litellm-config.yaml" {
      model_list =
        lib.mapAttrsToList
          (_: instance:
            {
              model_name = mkModelAlias instance;
              litellm_params = {
                model = "openai/${mkModelAlias instance}";
                api_base = "http://${instance.host}:${toString instance.port}${instanceApiBasePath instance}";
                api_key = "local-${mkModelAlias instance}";
              };
            }
            // lib.optionalAttrs (isLlamaInstance instance) {
              model_info = {
                max_input_tokens = instance.ctxSize;
              };
            })
          enabledInstances;
    };

  litellmStartScript =
    pkgs.writeShellScript "alanix-litellm-proxy" ''
      set -euo pipefail

      exec ${lib.getExe pkgs.litellm} \
        --config ${litellmConfig} \
        --host ${cfg.litellm.host} \
        --port ${toString cfg.litellm.port}${lib.optionalString (cfg.litellm.extraArgs != [ ]) " \\\n        ${lib.escapeShellArgs cfg.litellm.extraArgs}"}
    '';

  dashboardLinks =
    [
      {
        label = "Local dashboard";
        transport = "local";
        url = mkUrl {
          scheme = "http";
          host = normalizeLocalAddress dashboardCfg.listenAddress;
          port = dashboardCfg.port;
        };
      }
    ]
    ++ lib.optionals (
      dashboardCfg.expose.tailscale.enable
      && (
        config.alanix.tailscale.address != null
        || dashboardCfg.expose.tailscale.address != null
      )
      && dashboardCfg.expose.tailscale.port != null
    ) [
      {
        label = "Tailscale";
        transport = "tailscale";
        url = mkUrl {
          scheme = "http";
          host =
            if config.alanix.tailscale.address != null then
              config.alanix.tailscale.address
            else
              dashboardCfg.expose.tailscale.address;
          port = dashboardCfg.expose.tailscale.port;
        };
      }
    ]
    ++ lib.optionals (dashboardCfg.expose.tor.enable && dashboardCfg.expose.tor.hostname != null) [
      {
        label = "Tor";
        transport = "tor";
        url = "http://${dashboardCfg.expose.tor.hostname}/";
      }
    ]
    ++ lib.optionals (dashboardCfg.expose.wan.enable && dashboardCfg.expose.wan.domain != null) [
      {
        label = "WAN";
        transport = "wan";
        url = "https://${dashboardCfg.expose.wan.domain}/";
      }
    ];

  dashboardServices =
    lib.mapAttrsToList
      (instanceName: instance:
        {
          kind = "instance";
          runtime = instance.runtime;
          name = instanceName;
          displayName = instanceName;
          serviceName = mkServiceName instanceName instance;
          bindHost = instance.listenHost;
          host = instance.host;
          healthHost = normalizeLocalAddress instance.host;
          port = instance.port;
          endpointUrl = mkUrl {
            scheme = "http";
            host = normalizeLocalAddress instance.host;
            port = instance.port;
            path = instanceEndpointPath instance;
          };
          healthUrl = mkUrl {
            scheme = "http";
            host = normalizeLocalAddress instance.host;
            port = instance.port;
            path = instanceHealthPath instance;
          };
          healthCheckMode = if isLlamaInstance instance then "openai-models" else "http-options";
          alias = mkModelAlias instance;
          modelName = instance.model.name;
          model = {
            path = instance.model.path;
            url = instance.model.url;
            hfRepo = instance.model.hfRepo;
            hfFile = instance.model.hfFile;
            mmprojPath = instance.model.mmprojPath;
            mmprojUrl = instance.model.mmprojUrl;
            downloadName = instance.model.downloadName;
          };
          input = instance.input;
          threads = instance.threads;
          extraArgs = instance.extraArgs;
          litellmIncluded = cfg.litellm.enable;
        }
        // lib.optionalAttrs (isLlamaInstance instance) {
          ctxSize = instance.ctxSize;
          batchSize = instance.batchSize;
          ubatchSize = instance.ubatchSize;
          parallel = instance.parallel;
          gpuLayers = toString instance.gpuLayers;
          flashAttention = instance.flashAttention;
          threadsBatch = instance.threadsBatch;
          mmap = instance.mmap;
          mlock = instance.mlock;
        }
        // lib.optionalAttrs (isWhisperInstance instance) {
          language = instance.language;
          translate = instance.translate;
          processors = instance.processors;
          convertAudio = instance.convertAudio;
          requestPath = instance.requestPath;
          inferencePath = instance.inferencePath;
          gpu = instance.gpu;
        })
      enabledInstances
    ++ lib.optionals cfg.litellm.enable [
      {
        kind = "litellm";
        name = "litellm";
        displayName = "LiteLLM proxy";
        serviceName = "litellm-proxy";
        bindHost = cfg.litellm.host;
        host = cfg.litellm.host;
        healthHost = normalizeLocalAddress cfg.litellm.host;
        port = cfg.litellm.port;
        endpointUrl = mkUrl {
          scheme = "http";
          host = normalizeLocalAddress cfg.litellm.host;
          port = cfg.litellm.port;
          path = "/v1";
        };
        healthUrl = mkUrl {
          scheme = "http";
          host = normalizeLocalAddress cfg.litellm.host;
          port = cfg.litellm.port;
          path = "/v1/models";
        };
        healthCheckMode = "openai-models";
        modelAliases = lib.mapAttrsToList (_: instance: mkModelAlias instance) enabledInstances;
      }
    ];

  dashboardConfigFile =
    pkgs.writeText "alanix-llm-dashboard.json" (
      builtins.toJSON {
        hostName = config.networking.hostName;
        backend = cfg.backend;
        stateDir = cfg.stateDir;
        dashboard = {
          listenAddress = dashboardCfg.listenAddress;
          port = dashboardCfg.port;
          recentLogLines = dashboardCfg.recentLogLines;
          collectIntervalSeconds = 5;
          links = dashboardLinks;
        };
        services = dashboardServices;
      }
    );

  dashboardDependencies =
    lib.mapAttrsToList (instanceName: instance: "${mkServiceName instanceName instance}.service") enabledInstances
    ++ lib.optionals cfg.litellm.enable [ "litellm-proxy.service" ];

  runtimePackages =
    lib.unique (
      (lib.optionals hasLlamaInstance [ llamaPackage ])
      ++ (lib.optionals hasWhisperInstance [ whisperPackage ])
      ++ lib.optionals cfg.litellm.enable [ pkgs.litellm ]
    );
in
{
  options.alanix.llm = {
    enable = lib.mkEnableOption "local model servers";

    backend = lib.mkOption {
      type = types.enum [
        "cpu"
        "rocm"
        "vulkan"
      ];
      default = "cpu";
    };

    stateDir = lib.mkOption {
      type = types.str;
      default = "/var/lib/llm";
    };

    instances = lib.mkOption {
      type = types.attrsOf mkInstanceSubmodule;
      default = { };
      description = "Named local model server instances.";
    };

    litellm = {
      enable = lib.mkEnableOption "LiteLLM proxy in front of enabled local model instances";

      host = lib.mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "Address/interface LiteLLM binds to.";
      };

      port = lib.mkOption {
        type = types.port;
        default = 4000;
        description = "Port LiteLLM listens on.";
      };

      extraArgs = lib.mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Extra CLI flags passed to litellm.";
      };
    };

    dashboard = {
      enable = lib.mkEnableOption "read-only dashboard for local LLM services";

      listenAddress = lib.mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "Local bind address for the LLM dashboard.";
      };

      port = lib.mkOption {
        type = types.port;
        default = 9843;
        description = "Local HTTP port for the LLM dashboard.";
      };

      recentLogLines = lib.mkOption {
        type = types.int;
        default = 40;
        description = "Number of recent journal lines to show per LLM service.";
      };

      expose = serviceExposure.mkOptions {
        serviceName = "llm-dashboard";
        serviceDescription = "LLM Dashboard";
        defaultPublicPort = 80;
      };
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions =
        [
          {
            assertion = enabledInstances != { };
            message = "alanix.llm.instances must contain at least one enabled instance when alanix.llm.enable = true.";
          }
          {
            assertion = lib.length enabledPorts == lib.length (lib.unique enabledPorts);
            message = "Enabled alanix.llm instances must use unique ports.";
          }
          {
            assertion = !cfg.litellm.enable || !(lib.elem cfg.litellm.port enabledPorts);
            message = "alanix.llm.litellm.port must not conflict with an enabled model instance port.";
          }
          {
            assertion = !dashboardCfg.enable || !(lib.elem dashboardCfg.port enabledPorts);
            message = "alanix.llm.dashboard.port must not conflict with an enabled model instance port.";
          }
          {
            assertion = !dashboardCfg.enable || !cfg.litellm.enable || dashboardCfg.port != cfg.litellm.port;
            message = "alanix.llm.dashboard.port must not conflict with alanix.llm.litellm.port.";
          }
        ]
        ++ serviceExposure.mkAssertions {
          inherit config;
          optionPrefix = "alanix.llm.dashboard.expose";
          endpoint = dashboardEndpoint;
          exposeCfg = dashboardCfg.expose;
        }
        ++ lib.flatten (
          lib.mapAttrsToList
            (instanceName: instance:
              lib.optionals instance.enable (
                [
                  {
                    assertion = instance.runtime == "llama" || instance.runtime == "whisper";
                    message = "alanix.llm.instances.${instanceName}.runtime must be set to llama or whisper.";
                  }
                ]
                ++ lib.optionals (isLlamaInstance instance) [
                  {
                    assertion = lib.all (value: value != null) [
                      instance.ctxSize
                      instance.batchSize
                      instance.ubatchSize
                      instance.parallel
                      instance.gpuLayers
                      instance.flashAttention
                      instance.mmap
                      instance.mlock
                    ];
                    message = "alanix.llm.instances.${instanceName}: llama runtime requires ctxSize, batchSize, ubatchSize, parallel, gpuLayers, flashAttention, mmap, and mlock.";
                  }
                  {
                    assertion = lib.length (lib.filter (x: x != null) [
                      instance.model.path
                      instance.model.url
                      instance.model.hfRepo
                    ]) == 1;
                    message = "alanix.llm.instances.${instanceName}.model: llama runtime requires exactly one of path, url, or hfRepo.";
                  }
                  {
                    assertion = instance.model.hfRepo != null || instance.model.hfFile == null;
                    message = "alanix.llm.instances.${instanceName}.model.hfFile requires alanix.llm.instances.${instanceName}.model.hfRepo.";
                  }
                  {
                    assertion = lib.length (lib.filter (x: x != null) [
                      instance.model.mmprojPath
                      instance.model.mmprojUrl
                    ]) <= 1;
                    message = "alanix.llm.instances.${instanceName}.model: set at most one of mmprojPath or mmprojUrl.";
                  }
                  {
                    assertion = instance.model.downloadName == null;
                    message = "alanix.llm.instances.${instanceName}.model.downloadName is only valid for whisper runtime.";
                  }
                ]
                ++ lib.optionals (isWhisperInstance instance) [
                  {
                    assertion = lib.length (lib.filter (x: x != null) [
                      instance.model.path
                      instance.model.downloadName
                    ]) == 1;
                    message = "alanix.llm.instances.${instanceName}.model: whisper runtime requires exactly one of path or downloadName.";
                  }
                  {
                    assertion = lib.all (value: value == null) [
                      instance.model.url
                      instance.model.hfRepo
                      instance.model.hfFile
                      instance.model.mmprojPath
                      instance.model.mmprojUrl
                      instance.ctxSize
                      instance.batchSize
                      instance.ubatchSize
                      instance.parallel
                      instance.gpuLayers
                      instance.flashAttention
                      instance.threadsBatch
                      instance.mmap
                      instance.mlock
                      instance.imageMinTokens
                      instance.imageMaxTokens
                    ];
                    message = "alanix.llm.instances.${instanceName}: whisper runtime does not accept llama-specific options.";
                  }
                ]
              ))
            cfg.instances
        );

      users.users.llm = {
        isSystemUser = true;
        group = "llm";
        home = cfg.stateDir;
        createHome = true;
        extraGroups = lib.optionals (cfg.backend != "cpu") [ "render" "video" ];
      };

      users.groups.llm = { };

      users.users.llm-dashboard = lib.mkIf dashboardCfg.enable {
        isSystemUser = true;
        group = "llm-dashboard";
        description = "Read-only dashboard user for local LLM services";
        extraGroups = [
          "llm"
          "systemd-journal"
        ];
      };

      users.groups.llm-dashboard = lib.mkIf dashboardCfg.enable { };

      systemd.tmpfiles.rules = [
        "d ${cfg.stateDir} 0750 llm llm - -"
        "z ${cfg.stateDir} 0750 llm llm - -"
        "d ${cfg.stateDir}/models 0750 llm llm - -"
        "z ${cfg.stateDir}/models 0750 llm llm - -"
        "d ${cfg.stateDir}/models/whisper 0750 llm llm - -"
        "z ${cfg.stateDir}/models/whisper 0750 llm llm - -"
        "d ${cfg.stateDir}/cache 0750 llm llm - -"
        "z ${cfg.stateDir}/cache 0750 llm llm - -"
        "d ${cfg.stateDir}/huggingface 0750 llm llm - -"
        "z ${cfg.stateDir}/huggingface 0750 llm llm - -"
        "d ${cfg.stateDir}/logs 0750 llm llm - -"
        "z ${cfg.stateDir}/logs 0750 llm llm - -"
      ];

      systemd.services =
        (lib.mapAttrs'
          (instanceName: instance:
            lib.nameValuePair (mkServiceName instanceName instance) {
              description = "Local ${instance.runtime}.cpp model server (${instanceName})";
              after = [ "network.target" ];
              wantedBy = [ "multi-user.target" ];
              path =
                lib.optionals (isWhisperInstance instance) (
                  with pkgs;
                  [
                    coreutils
                    curl
                    ffmpeg
                    gnugrep
                  ]
                );

              environment = {
                HOME = cfg.stateDir;
                XDG_CACHE_HOME = "${cfg.stateDir}/cache";
                HF_HOME = "${cfg.stateDir}/huggingface";
              };

              serviceConfig = {
                User = "llm";
                Group = "llm";
                WorkingDirectory = cfg.stateDir;
                ExecStart = mkStartScript instanceName instance;
                Restart = "always";
                RestartSec = "5s";
                StateDirectory = "llm";
                StateDirectoryMode = "0750";
                LogsDirectory = "llm";
                LogsDirectoryMode = "0750";
              };
            })
          enabledInstances)
        // lib.optionalAttrs dashboardCfg.enable {
          "alanix-llm-dashboard" = {
            description = "Alanix LLM dashboard";
            after = [ "network-online.target" ] ++ dashboardDependencies;
            wants = [ "network-online.target" ] ++ dashboardDependencies;
            wantedBy = [ "multi-user.target" ];
            path = with pkgs; [
              coreutils
              python3
              systemd
            ];
            environment = {
              PYTHONUNBUFFERED = "1";
            };
            serviceConfig = {
              Type = "simple";
              User = "llm-dashboard";
              Group = "llm-dashboard";
              WorkingDirectory = "/";
              ExecStart = "${pkgs.python3}/bin/python3 ${./llm-dashboard.py} ${dashboardConfigFile}";
              Restart = "always";
              RestartSec = "5s";
            };
          };
        }
        // lib.optionalAttrs cfg.litellm.enable {
          litellm-proxy = {
            description = "LiteLLM proxy for local model servers";
            after = [ "network.target" ] ++ lib.mapAttrsToList (instanceName: instance: "${mkServiceName instanceName instance}.service") enabledInstances;
            wants = lib.mapAttrsToList (instanceName: instance: "${mkServiceName instanceName instance}.service") enabledInstances;
            wantedBy = [ "multi-user.target" ];

            environment = {
              HOME = cfg.stateDir;
              XDG_CACHE_HOME = "${cfg.stateDir}/cache";
              LITELLM_CONFIG_PATH = litellmConfig;
            };

            serviceConfig = {
              User = "llm";
              Group = "llm";
              WorkingDirectory = cfg.stateDir;
              ExecStart = litellmStartScript;
              Restart = "always";
              RestartSec = "5s";
              StateDirectory = "llm";
              StateDirectoryMode = "0750";
              LogsDirectory = "llm";
              LogsDirectoryMode = "0750";
            };
          };
        };

      environment.systemPackages = runtimePackages;
    }

    (lib.mkIf dashboardCfg.enable (
      serviceExposure.mkConfig {
        serviceName = "llm-dashboard";
        serviceDescription = "LLM Dashboard";
        inherit config;
        endpoint = dashboardEndpoint;
        exposeCfg = dashboardCfg.expose;
      }
    ))
  ]);
}
