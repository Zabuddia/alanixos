{ lib, config, hostname, allHosts, ... }:

let
  cfg = config.alanix.wireguard;
  hasValue = value: value != null && value != "";
  ready =
    hasValue cfg.vpnIP
    && hasValue cfg.endpoint
    && hasValue cfg.publicKey
    && cfg.privateKeyFile != null
    && cfg.listenPort != null;

  peerHosts =
    map
      (peerName: {
        name = peerName;
        hostCfg = lib.attrByPath [ peerName ] null allHosts;
      })
      cfg.peers;

  peers =
    map
    ({ hostCfg, ... }:
      let
        peer = hostCfg.config.alanix.wireguard;
      in {
        publicKey = peer.publicKey;
        allowedIPs = [ "${peer.vpnIP}/32" ];
        endpoint = peer.endpoint;
        persistentKeepalive = 25;
        dynamicEndpointRefreshSeconds = 60;
        dynamicEndpointRefreshRestartSeconds = 5;
      })
    (lib.filter
      ({ hostCfg, ... }: hostCfg != null && hostCfg.config.alanix.wireguard.enable)
      peerHosts);
in
{
  options.alanix.wireguard = {
    enable = lib.mkEnableOption "WireGuard mesh";
    vpnIP = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
    endpoint = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
    publicKey = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
    privateKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
    };
    listenPort = lib.mkOption {
      type = lib.types.nullOr lib.types.port;
      default = null;
    };
    peers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Names of alanix hosts that should be WireGuard peers of this host.";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      assertions =
        [
          {
            assertion = hasValue cfg.vpnIP;
            message = "alanix.wireguard.vpnIP must be set when alanix.wireguard.enable = true.";
          }
          {
            assertion = hasValue cfg.publicKey;
            message = "alanix.wireguard.publicKey must be set when alanix.wireguard.enable = true.";
          }
          {
            assertion = hasValue cfg.endpoint;
            message = "alanix.wireguard.endpoint must be set when alanix.wireguard.enable = true.";
          }
          {
            assertion = cfg.privateKeyFile != null;
            message = "alanix.wireguard.privateKeyFile must be set when alanix.wireguard.enable = true.";
          }
          {
            assertion = cfg.listenPort != null;
            message = "alanix.wireguard.listenPort must be set when alanix.wireguard.enable = true.";
          }
          {
            assertion = lib.unique cfg.peers == cfg.peers;
            message = "alanix.wireguard.peers must not contain duplicates.";
          }
        ]
        ++ map
          (peerHost: {
            assertion = peerHost != hostname;
            message = "alanix.wireguard.peers must not include the current host (${hostname}).";
          })
          cfg.peers
        ++ map
          ({ name, hostCfg }: {
            assertion = hostCfg != null;
            message = "alanix.wireguard.peers contains unknown host '${name}'.";
          })
          peerHosts
        ++ map
          ({ name, hostCfg }: {
            assertion = hostCfg != null && hostCfg.config.alanix.wireguard.enable;
            message = "alanix.wireguard.peers.${name} must reference a host with alanix.wireguard.enable = true.";
          })
          peerHosts;
    })

    (lib.mkIf (cfg.enable && ready) {
      networking.firewall.allowedUDPPorts = [ cfg.listenPort ];
      networking.wireguard.interfaces.wg0 = {
        ips = [ "${cfg.vpnIP}/24" ];
        listenPort = cfg.listenPort;
        privateKeyFile = cfg.privateKeyFile;
        peers = peers;
      };
    })
  ];
}
