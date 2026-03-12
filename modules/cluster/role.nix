{ config, lib, pkgs, ... }:
let
  cluster = config.alanix.cluster;

  roleScript = pkgs.writeShellScriptBin "alanix-cluster-role" ''
    set -euo pipefail
    cat <<'EOF'
    node=${cluster.currentNodeName}
    role=${cluster.role}
    active_node=${cluster.activeNodeName}
    domain=${cluster.settings.domain}
    wireguard_ip=${cluster.currentNode.vpnIp}
    EOF
  '';

  servicesScript = pkgs.writeShellScriptBin "alanix-cluster-services" ''
    set -euo pipefail
    cat <<'EOF'
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: service: "${name} ${if service.enable then "enabled" else "disabled"}") cluster.services)}
    EOF
  '';
in
{
  environment.etc."alanix/role.json".text = builtins.toJSON {
    node = cluster.currentNodeName;
    role = cluster.role;
    activeNode = cluster.activeNodeName;
    currentNode = cluster.currentNode;
  };

  environment.etc."alanix/inventory.json".text = builtins.toJSON cluster.inventory;

  environment.systemPackages = [
    roleScript
    servicesScript
  ];
}
