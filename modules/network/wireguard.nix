{ lib, config, hostname, allHosts, ... }:

let
  cfg = config.alanix.wireguard;

  peers = lib.mapAttrsToList
    (name: hostCfg:
      let peer = hostCfg.config.alanix.wireguard; in {
        publicKey = peer.publicKey;
        allowedIPs = [ "${peer.vpnIP}/32" ];
        endpoint = peer.endpoint;
        persistentKeepalive = 25;
        dynamicEndpointRefreshSeconds = 60;
        dynamicEndpointRefreshRestartSeconds = 5;
      }
    )
    (lib.filterAttrs
      (name: hostCfg: name != hostname && hostCfg.config.alanix.wireguard.enable)
      allHosts
    );
in
{
  options.alanix.wireguard = {
    enable = lib.mkEnableOption "WireGuard mesh";
    vpnIP = lib.mkOption { type = lib.types.str; };
    endpoint = lib.mkOption { type = lib.types.str; };
    publicKey = lib.mkOption { type = lib.types.str; };
    privateKeyFile = lib.mkOption { type = lib.types.path; };
    listenPort = lib.mkOption { type = lib.types.port; default = 51820; };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.vpnIP != "";
        message = "alanix.wireguard: vpnIP must not be empty.";
      }
      {
        assertion = cfg.publicKey != "";
        message = "alanix.wireguard: publicKey must not be empty.";
      }
      {
        assertion = cfg.endpoint != "";
        message = "alanix.wireguard: endpoint must not be empty.";
      }
    ];

    networking.firewall.allowedUDPPorts = [ cfg.listenPort ];
    networking.wireguard.interfaces.wg0 = {
      ips = [ "${cfg.vpnIP}/24" ];
      listenPort = cfg.listenPort;
      privateKeyFile = cfg.privateKeyFile;
      peers = peers;
    };
  };
}
