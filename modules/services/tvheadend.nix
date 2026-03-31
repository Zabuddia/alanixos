{ config, lib, pkgs, ... }:
let
  cfg = config.alanix.tvheadend;
  serviceExposure = import ../../lib/mkServiceExposure.nix { inherit lib pkgs; };

  portMapping =
    address: hostPort: containerPort:
    if address == null || address == "" then
      "${toString hostPort}:${toString containerPort}"
    else
      "${address}:${toString hostPort}:${toString containerPort}";

  webEndpoint = {
    address = cfg.listenAddress;
    port = cfg.port;
    protocol = "http";
  };

  htspEndpoint = {
    address = cfg.htsp.listenAddress;
    port = cfg.htsp.port;
    protocol = "tcp";
  };

  htspExposed =
    cfg.htsp.expose.tor.enable
    || cfg.htsp.expose.tailscale.enable
    || cfg.htsp.expose.wireguard.enable
    || cfg.htsp.expose.wan.enable;

  containerVolumes =
    [
      "${cfg.dataDir}:/config"
      "/etc/localtime:/etc/localtime:ro"
    ]
    ++ lib.optional (cfg.recordingsDir != null) "${cfg.recordingsDir}:/recordings"
    ++ cfg.extraVolumes;

  containerPorts =
    [ (portMapping cfg.listenAddress cfg.port 9981) ]
    ++ lib.optional cfg.htsp.enable (portMapping cfg.htsp.listenAddress cfg.htsp.port 9982);

  containerOptions =
    (map (devicePath: "--device=${devicePath}") cfg.devicePaths)
    ++ cfg.extraContainerOptions;

  containerEnvironment =
    {
      TZ = cfg.timeZone;
    }
    // lib.optionalAttrs (cfg.runOpts != null && cfg.runOpts != "") {
      RUN_OPTS = cfg.runOpts;
    };
in
{
  options.alanix.tvheadend = {
    enable = lib.mkEnableOption "TVHeadend (Alanix, container-backed)";

    image = lib.mkOption {
      type = lib.types.str;
      default = "lscr.io/linuxserver/tvheadend:latest";
      description = "Container image used for TVHeadend.";
    };

    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Host bind address for the TVHeadend web UI container port.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 9981;
      description = "Host bind port for the TVHeadend web UI.";
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/tvheadend";
      description = "Directory used for persistent TVHeadend configuration data.";
    };

    recordingsDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional directory to mount into /recordings for DVR output.";
    };

    devicePaths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "/dev/dvb" ];
      description = "Host device paths passed into the TVHeadend container.";
    };

    timeZone = lib.mkOption {
      type = lib.types.str;
      default = config.time.timeZone or "UTC";
      description = "Timezone passed to the TVHeadend container.";
    };

    runOpts = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional extra tvheadend runtime arguments passed via RUN_OPTS.";
    };

    extraVolumes = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional Podman volume mappings.";
    };

    extraContainerOptions = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional Podman extraOptions appended to the TVHeadend container.";
    };

    htsp = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Expose the HTSP/Kodi port from the container on the host.";
      };

      listenAddress = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
        description = "Host bind address for the TVHeadend HTSP port.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 9982;
        description = "Host bind port for the TVHeadend HTSP server.";
      };

      expose = serviceExposure.mkOptions {
        serviceName = "tvheadend-htsp";
        serviceDescription = "TVHeadend HTSP";
        defaultPublicPort = 9982;
      };
    };

    expose = serviceExposure.mkOptions {
      serviceName = "tvheadend";
      serviceDescription = "TVHeadend Web UI";
      defaultPublicPort = 80;
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions =
        [
          {
            assertion = lib.hasPrefix "/" cfg.dataDir;
            message = "alanix.tvheadend.dataDir must be an absolute path.";
          }
          {
            assertion = cfg.recordingsDir == null || lib.hasPrefix "/" cfg.recordingsDir;
            message = "alanix.tvheadend.recordingsDir must be an absolute path when set.";
          }
          {
            assertion = lib.all (path: lib.hasPrefix "/" path) cfg.devicePaths;
            message = "alanix.tvheadend.devicePaths must contain absolute paths.";
          }
          {
            assertion = !htspExposed || cfg.htsp.enable;
            message = "alanix.tvheadend.htsp.enable must be true when any HTSP exposure is enabled.";
          }
        ]
        ++ serviceExposure.mkAssertions {
          inherit config;
          endpoint = webEndpoint;
          exposeCfg = cfg.expose;
          optionPrefix = "alanix.tvheadend.expose";
        }
        ++ serviceExposure.mkAssertions {
          inherit config;
          endpoint = htspEndpoint;
          exposeCfg = cfg.htsp.expose;
          optionPrefix = "alanix.tvheadend.htsp.expose";
        };

      systemd.tmpfiles.rules =
        [ "d ${cfg.dataDir} 0755 root root - -" ]
        ++ lib.optional (cfg.recordingsDir != null) "d ${cfg.recordingsDir} 0755 root root - -";

      virtualisation.podman.enable = true;
      virtualisation.oci-containers.backend = "podman";

      virtualisation.oci-containers.containers.tvheadend = {
        image = cfg.image;
        autoStart = true;
        ports = containerPorts;
        volumes = containerVolumes;
        environment = containerEnvironment;
        extraOptions = containerOptions;
      };

      environment.systemPackages = [ pkgs.v4l-utils ];
    }

    (serviceExposure.mkConfig {
      inherit config;
      endpoint = webEndpoint;
      exposeCfg = cfg.expose;
      serviceName = "tvheadend";
      serviceDescription = "TVHeadend Web UI";
    })

    (serviceExposure.mkConfig {
      inherit config;
      endpoint = htspEndpoint;
      exposeCfg = cfg.htsp.expose;
      serviceName = "tvheadend-htsp";
      serviceDescription = "TVHeadend HTSP";
    })
  ]);
}
