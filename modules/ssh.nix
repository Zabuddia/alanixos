{ ... }:
{
  services.openssh = {
    enable = true;
    openFirewall = false;
  };

  programs.ssh.startAgent = true;
}