{ config, ... }:

{
  imports = [ ../../modules/wireguard-mesh.nix ];

  my.wireguard = {
    enable = true;
    nodeName = "alan-framework";
    privateKeyFile = config.sops.secrets."wireguard-private-keys/alan-framework".path;

    nodes = {
      alan-big-nixos = {
        vpnIP = "10.100.0.1";
        endpoint = "alan-big-nixos-wg.fifefin.com:51820";
        publicKey = "19Kloz2N3r2ksivuyLNtSplbDxS1kneNzVNRFhnQoCA=";
      };

      randy-big-nixos = {
        vpnIP = "10.100.0.2";
        endpoint = "randy-big-nixos-wg.fifefin.com:51820";
        publicKey = "YD/m4D7uTGFnWBEACTkc7MnY7yG0yvRVAEJKqOQ91UE=";
      };

      alan-framework = {
        vpnIP = "10.100.0.3";
        endpoint = "alan-framework-wg.fifefin.com:51820";
        publicKey = "f6MBPUIr8jLqr8F4LDvJksJIN/BvGnDGG8OycXbrd1c=";
      };
    };
  };
}
