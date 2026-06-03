{ config, lib, pkgs, ... }:
let
  cfg = config.alanix.tvheadend;
  serviceExposure = import ../../../lib/mkServiceExposure.nix { inherit lib pkgs; };

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
      PUID = toString cfg.userId;
      PGID = toString cfg.groupId;
      TZ = cfg.timeZone;
    }
    // lib.optionalAttrs (cfg.runOpts != null && cfg.runOpts != "") {
      RUN_OPTS = cfg.runOpts;
    };

  tvheadendApiAddress =
    if cfg.listenAddress == "" || cfg.listenAddress == "0.0.0.0" then
      "127.0.0.1"
    else
      cfg.listenAddress;

  disableOverTheAirEpgGrabbers = pkgs.writeShellScript "tvheadend-disable-over-the-air-epggrabbers" ''
    set -eu

    base_url="http://${tvheadendApiAddress}:${toString cfg.port}"

    for attempt in $(${pkgs.coreutils}/bin/seq 1 60); do
      if ${pkgs.curl}/bin/curl -fsS --max-time 2 "$base_url/api/serverinfo" >/dev/null; then
        break
      fi

      if [ "$attempt" -eq 60 ]; then
        echo "TVHeadend API did not become ready; leaving EPG grabber state unchanged." >&2
        exit 0
      fi

      ${pkgs.coreutils}/bin/sleep 1
    done

    module_json="$(${pkgs.curl}/bin/curl -fsS --max-time 10 "$base_url/api/epggrab/module/list" || true)"
    if [ -z "$module_json" ]; then
      echo "Could not read TVHeadend EPG grabber modules; leaving state unchanged." >&2
      exit 0
    fi

    uuids="$(printf '%s' "$module_json" | ${pkgs.jq}/bin/jq -r '
      .entries[]
      | select(.status != "epggrabmodNone")
      | select(
          .title == "Over-the-air: PSIP: ATSC Grabber"
          or .title == "Over-the-air: EIT: EPG Grabber"
        )
      | .uuid
    ' || true)"

    for uuid in $uuids; do
      ${pkgs.curl}/bin/curl -fsS --max-time 10 \
        -X POST \
        --data-urlencode "node={\"uuid\":\"$uuid\",\"enabled\":false}" \
        "$base_url/api/idnode/save" >/dev/null \
        || echo "Could not disable TVHeadend EPG grabber $uuid." >&2
    done
  '';

  proxyUnitNamesFor =
    serviceName: exposeCfg:
    lib.optionals (exposeCfg.tailscale.enable && !exposeCfg.tailscale.tls) [ "alanix-expose-tailscale-${serviceName}" ];

  proxyUnitNames =
    proxyUnitNamesFor "tvheadend" cfg.expose
    ++ proxyUnitNamesFor "tvheadend-htsp" cfg.htsp.expose;
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

    userId = lib.mkOption {
      type = lib.types.ints.positive;
      default = 911;
      description = "UID passed to the LinuxServer TVHeadend image as PUID.";
    };

    groupId = lib.mkOption {
      type = lib.types.ints.positive;
      default = config.ids.gids.video;
      description = "GID passed to the LinuxServer TVHeadend image as PGID. Defaults to the host video group so TVHeadend can read DVB device nodes.";
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

    epg.disableOverTheAirGrabbers = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Disable TVHeadend's over-the-air PSIP/EIT EPG grabbers after startup. This is useful for tuners where OTA EPG grabbing can monopolize or wedge DVB inputs.";
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

      systemd.sockets = lib.genAttrs proxyUnitNames (_: {
        unitConfig.ConditionPathExists = cfg.devicePaths;
      });
      systemd.services =
        {
          "podman-tvheadend" = {
            unitConfig.ConditionPathExists = cfg.devicePaths;
            serviceConfig = lib.mkIf cfg.epg.disableOverTheAirGrabbers {
              ExecStartPost = lib.mkAfter [ "${disableOverTheAirEpgGrabbers}" ];
            };
          };
        }
        // lib.genAttrs proxyUnitNames (_: {
          unitConfig.ConditionPathExists = cfg.devicePaths;
        });

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
