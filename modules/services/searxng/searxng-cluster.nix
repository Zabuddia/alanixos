{ config, lib, ... }:
let
  cfg = config.alanix.searxng;
  helpers = import ../../../lib/clusterServiceAdapter.nix { inherit config lib; };
  enabled = cfg.enable && cfg.cluster.enable;
in
{
  config = lib.mkIf enabled (lib.mkMerge [
    {
    assertions = [
      {
        assertion = lib.hasPrefix "/" cfg.stateDir;
        message = "SearXNG cluster mode requires alanix.searxng.stateDir to be an absolute path.";
      }
    ];

    alanix.clusterServices.searxng = {
      label = "SearXNG";
      controller = {
        name = "searxng";
        label = "SearXNG";
        recoveryMode = "declarative";
        recoveryDescription = "declarative secret";
        activeUnits = [ "searx.service" ];
      };
      targetUnits = [ "searx.service" ];
      exposureUnits = [ "searx.service" ];
      webEndpoints = [
        {
          id = "searxng";
          label = "SearXNG";
          endpoint = {
            address = cfg.listenAddress;
            port = cfg.port;
            protocol = "http";
          };
          expose = cfg.expose;
        }
      ];
    };
    }
    (helpers.mkActiveTargetUnits [ "searx.service" ])
  ]);
}
