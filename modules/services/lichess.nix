{ config, lib, pkgs, ... }:
let
  cfg = config.alanix.lichess;
  serviceExposure = import ../../lib/mkServiceExposure.nix { inherit lib pkgs; };
  serviceIdentity = import ../../lib/mkServiceIdentity.nix { inherit lib; };

  exposeCfg = cfg.expose;
  endpoint = {
    address = cfg.listenAddress;
    port = cfg.port;
    protocol = "http";
  };

  domain = serviceIdentity.advertisedDomain {
    inherit config exposeCfg;
    listenAddress = cfg.listenAddress;
  };
  url = serviceIdentity.rootUrl {
    inherit config exposeCfg;
    listenAddress = cfg.listenAddress;
    port = cfg.port;
  };
in
{
  options.alanix.lichess = {
    enable = lib.mkEnableOption "Lichess (lila) chess server";

    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Host bind address for the Lichess container port.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Host bind port for Lichess.";
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/lila";
      description = "Directory for persistent Lichess data.";
    };

    expose = serviceExposure.mkOptions {
      serviceName = "lichess";
      serviceDescription = "Lichess";
      defaultPublicPort = 80;
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions =
        [
          {
            assertion = lib.hasPrefix "/" cfg.dataDir;
            message = "alanix.lichess.dataDir must be an absolute path.";
          }
        ]
        ++ serviceExposure.mkAssertions {
          inherit config endpoint exposeCfg;
          optionPrefix = "alanix.lichess.expose";
        };

      systemd.tmpfiles.rules = [ "d ${cfg.dataDir} 0755 root root - -" ];

      virtualisation.podman.enable = true;
      virtualisation.oci-containers.backend = "podman";

      virtualisation.oci-containers.containers.lichess = {
        image = "ghcr.io/lichess-org/lila-docker:main";
        autoStart = true;
        ports = [ "${cfg.listenAddress}:${toString cfg.port}:8080" ];
        volumes = [ "${cfg.dataDir}:/data" ];
        environment = {
          LILA_DOMAIN = domain;
          LILA_URL = url;
        };
      };
    }

    (serviceExposure.mkConfig {
      inherit config endpoint exposeCfg;
      serviceName = "lichess";
      serviceDescription = "Lichess";
    })
  ]);
}
