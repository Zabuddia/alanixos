{ config, lib, ... }:

let
  cfg = config.alanix.ssh;
in
{
  options.alanix.ssh = {
    enable = lib.mkEnableOption "OpenSSH server";

    openFirewallOnWireguard = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to allow SSH on the WireGuard interface.";
    };

    startAgent = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to start the SSH agent service.";
    };
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = !cfg.openFirewallOnWireguard || cfg.enable;
          message = "alanix.ssh.openFirewallOnWireguard requires alanix.ssh.enable = true.";
        }
        {
          assertion = !cfg.openFirewallOnWireguard || config.alanix.wireguard.enable;
          message = "alanix.ssh.openFirewallOnWireguard requires alanix.wireguard.enable = true.";
        }
      ];
    }

    (lib.mkIf cfg.enable {
      services.openssh = {
        enable = true;
        openFirewall = false;
      };

      networking.firewall.interfaces.wg0.allowedTCPPorts =
        lib.optionals cfg.openFirewallOnWireguard [ 22 ];
    })

    (lib.mkIf cfg.startAgent {
      programs.ssh.startAgent = true;
    })
  ];
}
