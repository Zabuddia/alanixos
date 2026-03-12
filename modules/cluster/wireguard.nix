{ config, hostname, lib, ... }:
let
  cluster = config.alanix.cluster;
  wireguard = cluster.settings.wireguard;
  self = cluster.currentNode;
  privateKeySecret = "${wireguard.privateKeySecretPrefix}/${hostname}";
  peers = lib.mapAttrsToList
    (_: node: {
      publicKey = node.wireguardPublicKey;
      allowedIPs = [ "${node.vpnIp}/32" ];
      endpoint = "${node.endpointHost}:${toString wireguard.listenPort}";
      persistentKeepalive = 25;
    })
    (lib.filterAttrs (name: _: name != cluster.currentNodeName) cluster.nodes);
in
{
  networking.firewall.allowedUDPPorts = [ wireguard.listenPort ];

  networking.wireguard.interfaces.${wireguard.interface} = {
    ips = [ "${self.vpnIp}/24" ];
    listenPort = wireguard.listenPort;
    privateKeyFile = config.sops.secrets.${privateKeySecret}.path;
    peers = peers;
  };
}
