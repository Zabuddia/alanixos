{ config, lib, pkgs, ... }:

let
  cfg = config.alanix.wyoming;
  types = lib.types;

  whisperDataDir = "/var/lib/${cfg.whisper.stateDirectory}";
  piperDataDir = "/var/lib/${cfg.piper.stateDirectory}";

  mkServiceConfig = stateDirectory: execStart: {
    DynamicUser = true;
    StateDirectory = stateDirectory;
    StateDirectoryMode = "0750";
    ExecStart = lib.escapeShellArgs execStart;
    Restart = "on-failure";
    RestartSec = "5s";
    NoNewPrivileges = true;
    PrivateTmp = true;
    ProtectHome = true;
    ProtectSystem = "strict";
  };
in
{
  options.alanix.wyoming = {
    enable = lib.mkEnableOption "Wyoming voice services for Home Assistant";

    openFirewallOnTailscale = lib.mkOption {
      type = types.bool;
      default = false;
      description = "Whether to allow enabled Wyoming services through the Tailscale interface.";
    };

    whisper = {
      enable = lib.mkOption {
        type = types.bool;
        default = true;
        description = "Whether to run the Wyoming Faster Whisper speech-to-text service.";
      };

      package = lib.mkOption {
        type = types.package;
        default = pkgs.wyoming-faster-whisper;
        defaultText = lib.literalExpression "pkgs.wyoming-faster-whisper";
        description = "Wyoming Faster Whisper package to run.";
      };

      listenAddress = lib.mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "Address on which the Wyoming Whisper service listens.";
      };

      port = lib.mkOption {
        type = types.port;
        default = 10300;
        description = "TCP port for the Wyoming Whisper service.";
      };

      stateDirectory = lib.mkOption {
        type = types.strMatching "[A-Za-z0-9_.-]+";
        default = "wyoming-whisper";
        description = "Persistent service directory beneath /var/lib.";
      };

      sttLibrary = lib.mkOption {
        type = types.str;
        default = "faster-whisper";
        description = "Speech-to-text backend passed through --stt-library.";
      };

      model = lib.mkOption {
        type = types.str;
        default = "large-v3-turbo";
        description = "Faster Whisper model name or Hugging Face model identifier.";
      };

      language = lib.mkOption {
        type = types.str;
        default = "auto";
        description = "Default transcription language, or auto for detection.";
      };

      device = lib.mkOption {
        type = types.str;
        default = "cpu";
        description = "CTranslate2 inference device.";
      };

      computeType = lib.mkOption {
        type = types.str;
        default = "int8";
        description = "CTranslate2 compute type, such as int8 or float16.";
      };

      cpuThreads = lib.mkOption {
        type = types.ints.positive;
        default = 4;
        description = "CPU threads available to Faster Whisper.";
      };

      beamSize = lib.mkOption {
        type = types.ints.positive;
        default = 1;
        description = "Transcription beam size; 1 prioritizes voice-command latency.";
      };

      extraArgs = lib.mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Additional command-line arguments for Wyoming Faster Whisper.";
      };
    };

    piper = {
      enable = lib.mkOption {
        type = types.bool;
        default = true;
        description = "Whether to run the Wyoming Piper text-to-speech service.";
      };

      package = lib.mkOption {
        type = types.package;
        default = pkgs.wyoming-piper;
        defaultText = lib.literalExpression "pkgs.wyoming-piper";
        description = "Wyoming Piper package to run.";
      };

      listenAddress = lib.mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "Address on which the Wyoming Piper service listens.";
      };

      port = lib.mkOption {
        type = types.port;
        default = 10200;
        description = "TCP port for the Wyoming Piper service.";
      };

      stateDirectory = lib.mkOption {
        type = types.strMatching "[A-Za-z0-9_.-]+";
        default = "wyoming-piper";
        description = "Persistent service directory beneath /var/lib.";
      };

      voice = lib.mkOption {
        type = types.str;
        default = "en_US-lessac-medium";
        description = "Default Piper voice name.";
      };

      extraArgs = lib.mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Additional command-line arguments for Wyoming Piper.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.whisper.enable || cfg.piper.enable;
        message = "alanix.wyoming requires at least one of whisper.enable or piper.enable.";
      }
      {
        assertion = !cfg.openFirewallOnTailscale || config.alanix.tailscale.enable;
        message = "alanix.wyoming.openFirewallOnTailscale requires alanix.tailscale.enable.";
      }
      {
        assertion = !cfg.whisper.enable || !cfg.piper.enable || cfg.whisper.port != cfg.piper.port;
        message = "alanix.wyoming Whisper and Piper ports must be different.";
      }
    ];

    systemd.services = {
      wyoming-faster-whisper = lib.mkIf cfg.whisper.enable {
        description = "Wyoming Faster Whisper speech-to-text server";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        wantedBy = [ "multi-user.target" ];
        environment = {
          HOME = whisperDataDir;
          HF_HOME = "${whisperDataDir}/huggingface";
          XDG_CACHE_HOME = "${whisperDataDir}/cache";
        };
        serviceConfig = mkServiceConfig cfg.whisper.stateDirectory (
          [
            (lib.getExe cfg.whisper.package)
            "--uri"
            "tcp://${cfg.whisper.listenAddress}:${toString cfg.whisper.port}"
            "--stt-library"
            cfg.whisper.sttLibrary
            "--model"
            cfg.whisper.model
            "--language"
            cfg.whisper.language
            "--device"
            cfg.whisper.device
            "--compute-type"
            cfg.whisper.computeType
            "--cpu-threads"
            (toString cfg.whisper.cpuThreads)
            "--beam-size"
            (toString cfg.whisper.beamSize)
            "--data-dir"
            whisperDataDir
            "--download-dir"
            whisperDataDir
          ]
          ++ cfg.whisper.extraArgs
        );
      };

      wyoming-piper = lib.mkIf cfg.piper.enable {
        description = "Wyoming Piper text-to-speech server";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        wantedBy = [ "multi-user.target" ];
        environment.HOME = piperDataDir;
        serviceConfig = mkServiceConfig cfg.piper.stateDirectory (
          [
            (lib.getExe cfg.piper.package)
            "--uri"
            "tcp://${cfg.piper.listenAddress}:${toString cfg.piper.port}"
            "--voice"
            cfg.piper.voice
            "--data-dir"
            piperDataDir
            "--download-dir"
            piperDataDir
          ]
          ++ cfg.piper.extraArgs
        );
      };
    };

    networking.firewall.interfaces.${config.services.tailscale.interfaceName}.allowedTCPPorts =
      lib.optionals cfg.openFirewallOnTailscale (
        lib.optional cfg.whisper.enable cfg.whisper.port
        ++ lib.optional cfg.piper.enable cfg.piper.port
      );
  };
}
