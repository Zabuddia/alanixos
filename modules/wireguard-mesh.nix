{ lib, config, ... }:

let
  cfg = config.my.wireguard;

  nodes = cfg.nodes;

  thisNode = nodes.${cfg.nodeName};

  peers = 
    lib.mapAttrsToList
      (name: node:
        lib.mkIf (name != cfg.nodeName) {
          publicKey = node.publicKey;
          allowedIPs = [ "${node.vpnIP}/32" ];
          endpoint = node.endpoint;
          persistentKeepalive = 25;
        }
      )
      nodes;
in
{
  options.my.wireguard = {
    enable = lib.mkEnableOption "WireGuard mesh";

    nodeName = lib.mkOption {
      type = lib.types.str;
      description = "This node's name (must match entry in nodes).";
    };

    listenPort = lib.mkOption {
      type = lib.types.port;
      default = 51820;
    };

    privateKeyFile = lib.mkOption {
      type = lib.types.path;
    };

    nodes = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          vpnIP = lib.mkOption { type = lib.types.str; };
          endpoint = lib.mkOption { type = lib.types.str; };
          publicKey = lib.mkOption { type = lib.types.str; };
        };
      });
    };
  };

  config = lib.mkIf cfg.enable {
    networking.firewall.allowedUDPPorts = [ cfg.listenPort ];

    networking.wireguard.interfaces.wg0 = {
      ips = [ "${thisNode.vpnIP}/24" ];
      listenPort = cfg.listenPort;
      privateKeyFile = cfg.privateKeyFile;
      peers = lib.filter lib.isAttrs peers;
    };
  };
}