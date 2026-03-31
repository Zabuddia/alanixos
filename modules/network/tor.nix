{ lib, config, ... }:

let
  cfg = config.alanix.tor;
in
{
  options.alanix.tor = {
    enable = lib.mkEnableOption "Tor SOCKS proxy";

    socksPort = lib.mkOption {
      type = lib.types.port;
      default = 9050;
      description = "Port for the local Tor SOCKS5 proxy.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.tor = {
      enable = true;
      client = {
        enable = true;
        socksListenAddress = {
          IsolateDestAddr = true;
          addr = "127.0.0.1";
          port = cfg.socksPort;
        };
      };
    };
  };
}
