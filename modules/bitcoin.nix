{ lib, pkgs, inputs, ... }:
{
  imports = [
    (inputs.nix-bitcoin + "/modules/presets/secure-node.nix")
  ];

  nix-bitcoin.configVersion = "0.0.85";

  nix-bitcoin.generateSecrets = true;

  # Not necessary, fulcrum enables these options
  services.bitcoind = {
    enable = true;
    txindex = true;
  };

  # Not necessary, mempool enables this
  services.fulcrum.enable = true;

  services.mempool = {
    enable = true;
    electrumServer = "fulcrum";
    frontend = {
      address = "0.0.0.0";
      port = 4080;
    };
  };
}