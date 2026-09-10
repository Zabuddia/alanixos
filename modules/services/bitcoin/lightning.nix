{ config, lib, ... }:

let
  cfg = config.alanix.bitcoin.lightning;
in
{
  options.alanix.bitcoin.lightning = {
    enable = lib.mkEnableOption "Core Lightning";

    announceOnion = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Accept and announce incoming Lightning connections through Tor.";
    };

    rtl = {
      enable = lib.mkEnableOption "the Ride The Lightning web interface";

      listenAddress = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
        description = "Address on which RTL listens.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 3000;
        description = "Port on which RTL listens.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.alanix.bitcoin.enable;
        message = "alanix.bitcoin.lightning.enable requires alanix.bitcoin.enable.";
      }
    ];

    services.clightning.enable = true;

    nix-bitcoin.onionServices.clightning.public = cfg.announceOnion;

    services.rtl = {
      enable = cfg.rtl.enable;
      address = cfg.rtl.listenAddress;
      port = cfg.rtl.port;
      nodes.clightning.enable = cfg.rtl.enable;
    };
  };
}
