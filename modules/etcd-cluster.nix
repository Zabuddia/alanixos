{ config, lib, pkgs, hostname, ... }:
let
  cluster = config.alanix.cluster;
  cfg = cluster.controlPlane.etcd;
  nodeNames = lib.sort builtins.lessThan (builtins.attrNames cluster.nodes);
  nodeCount = builtins.length nodeNames;
  localNode = cluster.nodes.${hostname} or null;
  endpointUrls = map
    (nodeName: "http://${cluster.nodes.${nodeName}.vpnIP}:${toString cfg.clientPort}")
    nodeNames;
  endpointList = lib.concatStringsSep "," endpointUrls;
  initialCluster = map
    (nodeName: "${nodeName}=http://${cluster.nodes.${nodeName}.vpnIP}:${toString cfg.peerPort}")
    nodeNames;
in
{
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = localNode != null;
        message = "alanix.cluster.controlPlane.etcd.enable requires ${hostname} to exist in alanix.cluster.nodes.";
      }
      {
        assertion = nodeCount >= 3;
        message = "alanix.cluster.controlPlane.etcd requires at least 3 cluster nodes.";
      }
      {
        assertion = (lib.mod nodeCount 2) == 1;
        message = "alanix.cluster.controlPlane.etcd requires an odd number of nodes for quorum.";
      }
      {
        assertion = cfg.electionTimeoutMs >= (cfg.heartbeatIntervalMs * 5);
        message = "alanix.cluster.controlPlane.etcd.electionTimeoutMs must be at least 5x heartbeatIntervalMs.";
      }
    ];

    services.etcd = {
      enable = true;
      name = hostname;
      dataDir = cfg.dataDir;
      listenClientUrls = [
        "http://127.0.0.1:${toString cfg.clientPort}"
        "http://${localNode.vpnIP}:${toString cfg.clientPort}"
      ];
      advertiseClientUrls = [ "http://${localNode.vpnIP}:${toString cfg.clientPort}" ];
      listenPeerUrls = [ "http://${localNode.vpnIP}:${toString cfg.peerPort}" ];
      initialAdvertisePeerUrls = [ "http://${localNode.vpnIP}:${toString cfg.peerPort}" ];
      inherit initialCluster;
      initialClusterState = cfg.initialClusterState;
      initialClusterToken = cfg.initialClusterToken;
      openFirewall = false;
      extraConf = {
        HEARTBEAT_INTERVAL = toString cfg.heartbeatIntervalMs;
        ELECTION_TIMEOUT = toString cfg.electionTimeoutMs;
        AUTO_COMPACTION_MODE = cfg.autoCompactionMode;
        AUTO_COMPACTION_RETENTION = cfg.autoCompactionRetention;
      };
    };

    systemd.services.etcd = {
      requires = [ "wireguard-wg0.service" ];
      after = [ "wireguard-wg0.service" ];
    };

    environment.systemPackages = [
      (pkgs.writeShellApplication {
        name = "alanix-etcdctl";
        runtimeInputs = [ config.services.etcd.package ];
        text = ''
          exec etcdctl --endpoints ${lib.escapeShellArg endpointList} "$@"
        '';
      })
      (pkgs.writeShellApplication {
        name = "alanix-etcd-health";
        runtimeInputs = [ config.services.etcd.package ];
        text = ''
          exec etcdctl --endpoints ${lib.escapeShellArg endpointList} endpoint status --cluster --write-out=table
        '';
      })
      (pkgs.writeShellApplication {
        name = "alanix-etcd-members";
        runtimeInputs = [ config.services.etcd.package ];
        text = ''
          exec etcdctl --endpoints ${lib.escapeShellArg endpointList} member list --write-out=table
        '';
      })
    ];

    networking.firewall.interfaces.wg0.allowedTCPPorts = [
      cfg.clientPort
      cfg.peerPort
    ];
  };
}
