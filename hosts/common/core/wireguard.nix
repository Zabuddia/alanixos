{ config, lib, hostname, ... }:
let
  cluster = config.alanix.cluster;
  localNode = cluster.nodes.${hostname};
  peerEndpoint =
    peerNode:
    let
      sameSite =
        localNode.site != null
        && peerNode.site != null
        && localNode.site == peerNode.site;
      useLan = sameSite && peerNode.wireguardLanEndpointHost != null;
      endpointHost =
        if useLan then
          peerNode.wireguardLanEndpointHost
        else
          peerNode.wireguardEndpointHost;
      endpointPort =
        if useLan then
          peerNode.wireguardLanEndpointPort
        else
          peerNode.wireguardPublicEndpointPort;
    in
    "${endpointHost}:${toString endpointPort}";
  sameSitePeersMissingLan =
    lib.attrNames (lib.filterAttrs
      (nodeName: peerNode:
        nodeName != hostname
        && localNode.site != null
        && peerNode.site != null
        && localNode.site == peerNode.site
        && peerNode.wireguardLanEndpointHost == null)
      cluster.nodes);
in
{
  imports = [
    ./cluster.nix
    ../../../modules/wireguard-mesh.nix
  ];

  my.wireguard = {
    enable = true;
    nodeName = hostname;
    listenPort = localNode.wireguardListenPort;
    privateKeyFile = config.sops.secrets."wireguard-private-keys/${hostname}".path;
    nodes = lib.mapAttrs (_: node: {
      vpnIP = node.vpnIP;
      endpoint = peerEndpoint node;
      publicKey = node.wireguardPublicKey;
    }) cluster.nodes;
  };

  warnings = lib.optional (sameSitePeersMissingLan != [ ]) ''
    ${hostname}: same-site WireGuard peers ${lib.concatStringsSep ", " sameSitePeersMissingLan} do not define wireguardLanEndpointHost.
    They will be reached through their public endpoints, which is fragile behind shared NAT or without hairpin routing.
  '';
}
