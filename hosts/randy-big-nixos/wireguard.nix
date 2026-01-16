{ config, ... }:

{
  imports = [ ../../modules/wireguard-mesh.nix ];

  my.wireguard = {
    enable = true;
    nodeName = "randy-big-nixos";
    privateKeyFile = config.sops.secrets."wireguard-private-keys/randy-big-nixos".path;

    nodes = {
      alan-big-nixos = {
        vpnIP = "10.100.0.1";
        endpoint = "66.219.235.87:51820";
        publicKey = "19Kloz2N3r2ksivuyLNtSplbDxS1kneNzVNRFhnQoCA=";
      };

      randy-big-nixos = {
        vpnIP = "10.100.0.2";
        endpoint = "97.230.189.132:51820";
        publicKey = "YD/m4D7uTGFnWBEACTkc7MnY7yG0yvRVAEJKqOQ91UE=";
      };
    };
  };
}