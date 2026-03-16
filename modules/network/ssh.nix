{ ... }:
{
  services.openssh = {
    enable = true;
    openFirewall = false;
  };

  # Allow SSH only over WireGuard
  networking.firewall.interfaces.wg0.allowedTCPPorts = [ 22 ];

  programs.ssh.startAgent = true;
}