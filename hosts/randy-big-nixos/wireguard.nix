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
        publicKey = "JgKqp30jK1Gl3+A0KM98zUTpgzyqXVRAoNlSUBXL4S4=";
      };

      randy-big-nixos = {
        vpnIP = "10.100.0.2";
        endpoint = "97.230.189.132:51820";
        publicKey = "Sfn2P9gOyUgCqo7eewz7XwZYoH+a3EbTivO2bwxM6h0=";
      };
    };
  };
}