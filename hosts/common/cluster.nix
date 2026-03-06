{ ... }:
{
  imports = [ ../../modules/cluster.nix ];

  alanix.cluster = {
    domain = "fifefin.com";
    wgSubnetCIDR = "10.100.0.0/24";
    dns = {
      provider = "cloudflare";
      apiTokenSecret = "cloudflare/api-token";
    };

    nodes = {
      alan-big-nixos = {
        vpnIP = "10.100.0.1";
        priority = 20;
        wireguardPublicKey = "19Kloz2N3r2ksivuyLNtSplbDxS1kneNzVNRFhnQoCA=";
        wireguardEndpointHost = "alan-big-nixos-wg.fifefin.com";
      };

      randy-big-nixos = {
        vpnIP = "10.100.0.2";
        priority = 10;
        wireguardPublicKey = "YD/m4D7uTGFnWBEACTkc7MnY7yG0yvRVAEJKqOQ91UE=";
        wireguardEndpointHost = "randy-big-nixos-wg.fifefin.com";
      };
    };

    services.filebrowser = {
      domain = "filebrowser.fifefin.com";
      backendPort = 8088;
      reverseProxyOpenFirewall = true;
      wireguardAccess = {
        enable = false;
        port = 8089;
      };
      syncPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJqPS32ILVnc3Xyp23eo17esKfhOExuMNfKHikQXjtZc filebrowser-failover-sync";
    };
  };
}
