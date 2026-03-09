{ config, hostname, ... }:
let
  cluster = config.alanix.cluster;
in
{
  imports = [
    ./cluster.nix
    ../../../modules/dynamic-dns.nix
  ];

  alanix.dynamicDns = {
    enable = true;
    provider = cluster.dns.provider;
    zone = cluster.domain;
    apiTokenSecret = cluster.dns.apiTokenSecret;
    interval = "2min";
    records = [
      cluster.nodes.${hostname}.ddnsRecord
    ];
  };
}
