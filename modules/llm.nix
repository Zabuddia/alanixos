{ config, lib, pkgs, pkgs-unstable, ... }:

let
  cfg = config.alanix.llm;

  package =
    if cfg.backend == "cpu" then
      pkgs-unstable.llama-cpp
    else if cfg.backend == "rocm" then
      pkgs-unstable.llama-cpp-rocm
    else
      pkgs-unstable.llama-cpp-vulkan;

  modelAlias = if cfg.alias != null then cfg.alias else cfg.model.name;

  modelArgs =
    if cfg.model.path != null then
      [ "--model" cfg.model.path ]
    else if cfg.model.url != null then
      [ "--model-url" cfg.model.url ]
    else
      [ "--hf-repo" cfg.model.hfRepo ]
      ++ (lib.optionals (cfg.model.hfFile != null) [ "--hf-file" cfg.model.hfFile ]);

  staticArgs =
    [
      "--host"
      cfg.listenHost
      "--port"
      (toString cfg.port)
      "--alias"
      modelAlias
      "--ctx-size"
      (toString cfg.ctxSize)
      "--batch-size"
      (toString cfg.batchSize)
      "--ubatch-size"
      (toString cfg.ubatchSize)
      "--parallel"
      (toString cfg.parallel)
      "--flash-attn"
      cfg.flashAttention
      "--gpu-layers"
      (toString cfg.gpuLayers)
    ]
    ++ (lib.optionals cfg.mlock [ "--mlock" ])
    ++ (lib.optionals (!cfg.mmap) [ "--no-mmap" ])
    ++ modelArgs
    ++ cfg.extraArgs;

  startScript = pkgs.writeShellScript "alanix-llama-server" ''
    set -euo pipefail

    threads=${if cfg.threads == null then "$(${pkgs.coreutils}/bin/nproc)" else toString cfg.threads}
    threads_batch=${if cfg.threadsBatch == null then "$threads" else toString cfg.threadsBatch}

    exec ${lib.getExe' package "llama-server"} \
      --threads "$threads" \
      --threads-batch "$threads_batch" \
      ${lib.escapeShellArgs staticArgs}
  '';
in
{
  options.alanix.llm = {
    enable = lib.mkEnableOption "local llama.cpp server";

    backend = lib.mkOption {
      type = lib.types.enum [
        "cpu"
        "rocm"
        "vulkan"
      ];
      default = "vulkan";
    };

    host = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
    };

    listenHost = lib.mkOption {
      type = lib.types.str;
      default = cfg.host;
      description = "Address/interface llama-server binds to.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
    };

    alias = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Model alias exposed by llama-server's OpenAI-compatible API.";
    };

    ctxSize = lib.mkOption {
      type = lib.types.int;
      default = 32768;
    };

    batchSize = lib.mkOption {
      type = lib.types.int;
      default = 2048;
    };

    ubatchSize = lib.mkOption {
      type = lib.types.int;
      default = 512;
    };

    parallel = lib.mkOption {
      type = lib.types.int;
      default = 4;
    };

    gpuLayers = lib.mkOption {
      type = lib.types.oneOf [
        lib.types.int
        (lib.types.enum [ "auto" "all" ])
      ];
      default = "all";
    };

    flashAttention = lib.mkOption {
      type = lib.types.enum [ "on" "off" "auto" ];
      default = "on";
    };

    threads = lib.mkOption {
      type = lib.types.nullOr lib.types.int;
      default = null;
      description = "Generation threads. Null means use all available threads via nproc.";
    };

    threadsBatch = lib.mkOption {
      type = lib.types.nullOr lib.types.int;
      default = null;
      description = "Prompt/batch threads. Null means match threads.";
    };

    mmap = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };

    mlock = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/llm";
    };

    model = {
      name = lib.mkOption {
        type = lib.types.str;
      };

      path = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
      };

      url = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Remote GGUF URL passed to llama-server via --model-url.";
      };

      hfRepo = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Hugging Face repo passed to llama-server via --hf-repo.";
      };

      hfFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional Hugging Face GGUF file name passed via --hf-file.";
      };
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.length (lib.filter (x: x != null) [
          cfg.model.path
          cfg.model.url
          cfg.model.hfRepo
        ]) == 1;
        message = "alanix.llm.model: set exactly one of path, url, or hfRepo.";
      }
      {
        assertion = cfg.model.hfRepo != null || cfg.model.hfFile == null;
        message = "alanix.llm.model.hfFile requires alanix.llm.model.hfRepo.";
      }
    ];

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

    systemd.services.llama-server = {
      description = "Local llama.cpp model server";
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
        ExecStart = startScript;
        Restart = "always";
        RestartSec = "5s";
        StateDirectory = "llm";
        LogsDirectory = "llm";
      };
    };

    environment.systemPackages = [ package ];
  };
}
