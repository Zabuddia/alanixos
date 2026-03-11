{ config, lib, hostname, ... }:
let
  cluster = config.alanix.cluster;
in
{
  imports = [
    ./cluster.nix
    ../../../modules/wireguard-mesh.nix
  ];

  my.wireguard = {
    enable = true;
    nodeName = hostname;
    listenPort = cluster.nodes.${hostname}.wireguardListenPort;
    privateKeyFile = config.sops.secrets."wireguard-private-keys/${hostname}".path;
    nodes = lib.mapAttrs (_: node: {
      vpnIP = node.vpnIP;
      endpoint = "${node.wireguardEndpointHost}:${toString node.wireguardListenPort}";
      publicKey = node.wireguardPublicKey;
    }) cluster.nodes;
  };
}
