{ config, lib, allHosts, ... }:

let
  cfg = config.alanix.ssh;

  hostsWithHostKey = lib.filterAttrs
    (_: hostCfg: hostCfg.config.alanix.ssh.hostPublicKey != null)
    allHosts;
in
{
  options.alanix.ssh = {
    enable = lib.mkEnableOption "OpenSSH server";

    openFirewallOnTailscale = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to allow SSH on the Tailscale interface.";
    };

    startAgent = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to start the SSH agent service.";
    };

    hostPublicKey = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "SSH host public key for this machine (content of /etc/ssh/ssh_host_ed25519_key.pub). When set, all other hosts add a programs.ssh.knownHosts entry using this host's Tailscale name.";
    };
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = !cfg.openFirewallOnTailscale || cfg.enable;
          message = "alanix.ssh.openFirewallOnTailscale requires alanix.ssh.enable = true.";
        }
        {
          assertion = !cfg.openFirewallOnTailscale || config.alanix.tailscale.enable;
          message = "alanix.ssh.openFirewallOnTailscale requires alanix.tailscale.enable = true.";
        }
      ];
    }

    (lib.mkIf cfg.enable {
      services.openssh = {
        enable = true;
        openFirewall = false;
        hostKeys = lib.mkIf (cfg.hostPublicKey != null) [
          { type = "ed25519"; path = "/etc/ssh/ssh_host_ed25519_key"; }
        ];
      };

      environment.etc."ssh/ssh_host_ed25519_key.pub" = lib.mkIf (cfg.hostPublicKey != null) {
        text = cfg.hostPublicKey + "\n";
        mode = "0644";
      };

      networking.firewall.interfaces.${config.services.tailscale.interfaceName}.allowedTCPPorts =
        lib.optionals cfg.openFirewallOnTailscale [ 22 ];
    })

    (lib.mkIf cfg.startAgent {
      programs.ssh.startAgent = true;
    })

    (lib.mkIf (hostsWithHostKey != { }) {
      programs.ssh.knownHosts = lib.mapAttrs'
        (hostName: hostCfg:
          let
            tailscaleName = hostCfg.config.alanix.tailscale.address;
            extraNames = lib.optional (tailscaleName != null) tailscaleName;
          in
          lib.nameValuePair
            hostName
            {
              hostNames = [ hostName ] ++ extraNames;
              publicKey = hostCfg.config.alanix.ssh.hostPublicKey;
            })
        hostsWithHostKey;
    })
  ];
}
