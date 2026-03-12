{ config, hostname, ... }:
let
  cluster = config.alanix.cluster.settings;
  wireguardPrivateKeySecret = "${cluster.wireguard.privateKeySecretPrefix}/${hostname}";
in
{
  sops = {
    defaultSopsFile = ../../secrets/secrets.yaml;
    age.keyFile = "/var/lib/sops-nix/key.txt";
  };

  sops.secrets."password-hashes/buddia" = {
    neededForUsers = true;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  sops.secrets."cloudflare/api-token" = {
    owner = "root";
    group = "root";
    mode = "0400";
  };

  sops.secrets."restic/cluster-password" = {
    owner = "root";
    group = "root";
    mode = "0400";
  };

  sops.secrets."cluster/sync-private-key" = {
    owner = "root";
    group = "root";
    mode = "0400";
  };

  sops.secrets.${wireguardPrivateKeySecret} = {
    owner = "root";
    group = "root";
    mode = "0400";
  };
}
