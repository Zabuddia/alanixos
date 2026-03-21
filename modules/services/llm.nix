{ config, lib, pkgs, pkgs-unstable, ... }:

let
  cfg = config.alanix.llm;
  inherit (lib) types;

  package =
    if cfg.backend == "cpu" then
      pkgs-unstable.llama-cpp
    else if cfg.backend == "rocm" then
      pkgs-unstable.llama-cpp-rocm
    else
      pkgs-unstable.llama-cpp-vulkan;

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
  };

  mkInstanceSubmodule = types.submodule ({ name, ... }: {
    options = {
      enable = lib.mkEnableOption "llama.cpp instance ${name}";

    host = lib.mkOption {
      type = types.str;
    };

    listenHost = lib.mkOption {
      type = types.str;
      description = "Address/interface llama-server binds to.";
    };

    port = lib.mkOption {
      type = types.port;
    };

      alias = lib.mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Model alias exposed by llama-server's OpenAI-compatible API.";
      };

      ctxSize = lib.mkOption {
        type = types.int;
      };

      batchSize = lib.mkOption {
        type = types.int;
      };

      ubatchSize = lib.mkOption {
        type = types.int;
      };

      parallel = lib.mkOption {
        type = types.int;
      };

      gpuLayers = lib.mkOption {
        type = types.oneOf [
          types.int
          (types.enum [ "auto" "all" ])
        ];
      };

      flashAttention = lib.mkOption {
        type = types.enum [ "on" "off" "auto" ];
      };

      threads = lib.mkOption {
        type = types.nullOr types.int;
        default = null;
        description = "Generation threads. Null means use all available threads via nproc.";
      };

      threadsBatch = lib.mkOption {
        type = types.nullOr types.int;
        default = null;
        description = "Prompt/batch threads. Null means match threads.";
      };

      mmap = lib.mkOption {
        type = types.bool;
      };

      mlock = lib.mkOption {
        type = types.bool;
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

      model = mkModelOptions "Instance ${name}";

      extraArgs = lib.mkOption {
        type = types.listOf types.str;
        default = [ ];
      };
    };
  });

  enabledInstances = lib.filterAttrs (_: instance: instance.enable) cfg.instances;
  enabledPorts = lib.mapAttrsToList (_: instance: instance.port) enabledInstances;

  mkModelAlias = instance:
    if instance.alias != null then instance.alias else instance.model.name;

  mkModelArgs = instance:
    if instance.model.path != null then
      [ "--model" instance.model.path ]
    else if instance.model.url != null then
      [ "--model-url" instance.model.url ]
    else
      [ "--hf-repo" instance.model.hfRepo ]
      ++ (lib.optionals (instance.model.hfFile != null) [ "--hf-file" instance.model.hfFile ]);

  mkStaticArgs = instance:
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
    ++ (mkModelArgs instance)
    ++ (lib.optionals (instance.model.mmprojPath != null) [ "--mmproj" instance.model.mmprojPath ])
    ++ (lib.optionals (instance.model.mmprojUrl != null) [ "--mmproj-url" instance.model.mmprojUrl ])
    ++ (lib.optionals (instance.imageMinTokens != null) [ "--image-min-tokens" (toString instance.imageMinTokens) ])
    ++ (lib.optionals (instance.imageMaxTokens != null) [ "--image-max-tokens" (toString instance.imageMaxTokens) ])
    ++ instance.extraArgs;

  mkStartScript = instanceName: instance:
    pkgs.writeShellScript "alanix-llama-server-${instanceName}" ''
      set -euo pipefail

      threads=${if instance.threads == null then "$(${pkgs.coreutils}/bin/nproc)" else toString instance.threads}
      threads_batch=${if instance.threadsBatch == null then "$threads" else toString instance.threadsBatch}

      exec ${lib.getExe' package "llama-server"} \
        --threads "$threads" \
        --threads-batch "$threads_batch" \
        ${lib.escapeShellArgs (mkStaticArgs instance)}
    '';

  mkServiceName = instanceName:
    if instanceName == "default" then "llama-server" else "llama-server-${instanceName}";
in
{
  options.alanix.llm = {
    enable = lib.mkEnableOption "local llama.cpp servers";

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
      description = "Named llama.cpp server instances.";
    };
  };

  config = lib.mkIf cfg.enable {
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
      ]
      ++ lib.flatten (
        lib.mapAttrsToList
          (instanceName: instance:
            lib.optionals instance.enable [
              {
                assertion = lib.length (lib.filter (x: x != null) [
                  instance.model.path
                  instance.model.url
                  instance.model.hfRepo
                ]) == 1;
                message = "alanix.llm.instances.${instanceName}.model: set exactly one of path, url, or hfRepo.";
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
            ])
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

    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0750 llm llm - -"
      "d ${cfg.stateDir}/models 0750 llm llm - -"
      "d ${cfg.stateDir}/cache 0750 llm llm - -"
      "d ${cfg.stateDir}/huggingface 0750 llm llm - -"
      "d ${cfg.stateDir}/logs 0750 llm llm - -"
    ];

    systemd.services =
      lib.mapAttrs'
        (instanceName: instance:
          lib.nameValuePair (mkServiceName instanceName) {
            description = "Local llama.cpp model server (${instanceName})";
            after = [ "network.target" ];
            wantedBy = [ "multi-user.target" ];

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
              LogsDirectory = "llm";
            };
          })
        enabledInstances;

    environment.systemPackages = [ package ];
  };
}
