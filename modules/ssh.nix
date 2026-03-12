{ config, ... }:
{
  services.openssh = {
    enable = true;
    openFirewall = false;
  };

  networking.firewall.interfaces.${config.alanix.cluster.settings.wireguard.interface}.allowedTCPPorts = [ 22 ];

  programs.ssh.startAgent = true;
}
