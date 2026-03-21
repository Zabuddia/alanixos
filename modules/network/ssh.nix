{ config, lib, ... }:

let
  cfg = config.alanix.ssh;
in
{
  options.alanix.ssh = {
    enable = lib.mkEnableOption "OpenSSH server";

    openFirewallOnWireguard = lib.mkOption {
      type = lib.types.bool;
      description = "Whether to allow SSH on the WireGuard interface.";
    };

    startAgent = lib.mkOption {
      type = lib.types.bool;
      description = "Whether to start the SSH agent service.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.openssh = {
      enable = true;
      openFirewall = false;
    };

    networking.firewall.interfaces.wg0.allowedTCPPorts =
      lib.optionals cfg.openFirewallOnWireguard [ 22 ];

    programs.ssh.startAgent = cfg.startAgent;
  };
}
