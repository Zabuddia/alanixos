{ hostname, config, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./secrets.nix
    ../../modules/roles/server.nix
  ];

  alanix.ddns = {
    enable = true;
    provider = "cloudflare";
    domains = [ "randy-big-nixos-wg.fifefin.com" ];
    credentialsFile = config.sops.templates."cloudflare-env".path;
  };

  alanix.wireguard = {
    enable = true;
    vpnIP = "10.100.0.2";
    endpoint = "randy-big-nixos-wg.fifefin.com:51820";
    publicKey = "YD/m4D7uTGFnWBEACTkc7MnY7yG0yvRVAEJKqOQ91UE=";
    privateKeyFile = config.sops.secrets."wireguard-private-keys/${hostname}".path;
  };

  alanix.desktop.enable = true;

  home-manager.users.buddia = {
    home.file.".ssh/id_ed25519.pub" = {
      text = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKpHeGMaMDqWna8I5fu0K2kaZ1GdOFIGw+8NsgH3aXE3 fife.alan@protonmail.com";
      force = true;
    };
  };

  swapDevices = [
    { device = "/swapfile"; size = 8192; }
  ];
}
