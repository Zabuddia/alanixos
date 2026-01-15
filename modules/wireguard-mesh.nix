{ lib, config, ... }:

let
  cfg = config.my.wireguard;

  nodes = cfg.nodes;

  thisNode = nodes.${cfg.nodeName};

  
{

}