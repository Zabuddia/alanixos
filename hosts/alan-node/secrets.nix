{ config, ... }:

{
  sops = {
    defaultSopsFile = (import ../../secrets/files.nix).users;
    age.keyFile = "/var/lib/sops-nix/key.txt";
  };

  sops.secrets."password-hashes/buddia" = {
    sopsFile = (import ../../secrets/files.nix).users;
    neededForUsers = true;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  sops.secrets."ssh-private-keys/alan-node" = {
    sopsFile = (import ../../secrets/files.nix).users;
    owner = "buddia";
    group = "users";
    mode = "0600";
    path = "/home/buddia/.ssh/id_ed25519";
  };

  sops.secrets."ssh-host-keys/alan-node" = {
    sopsFile = (import ../../secrets/files.nix).network;
    owner = "root";
    group = "root";
    mode = "0600";
    path = "/etc/ssh/ssh_host_ed25519_key";
  };

  sops.secrets."sunshine-web-ui-passwords/alan-node" = {
    sopsFile = (import ../../secrets/files.nix).servicePasswords;
    owner = "buddia";
    group = "users";
    mode = "0400";
  };
}
