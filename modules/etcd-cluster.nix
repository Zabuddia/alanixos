{ config, lib, pkgs, hostname, ... }:
let
  cluster = config.alanix.cluster;
  cfg = cluster.controlPlane.etcd;
  nodeNames = lib.sort builtins.lessThan (builtins.attrNames cluster.nodes);
  nodeCount = builtins.length nodeNames;
  localNode = cluster.nodes.${hostname} or null;
  clusterInterface = cluster.transport.interface;
  endpointUrls = map
    (nodeName: "http://${cluster.nodes.${nodeName}.clusterAddress}:${toString cfg.clientPort}")
    nodeNames;
  endpointList = lib.concatStringsSep "," endpointUrls;
  initialCluster = map
    (nodeName: "${nodeName}=http://${cluster.nodes.${nodeName}.clusterAddress}:${toString cfg.peerPort}")
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
        "http://${localNode.clusterAddress}:${toString cfg.clientPort}"
      ];
      advertiseClientUrls = [ "http://${localNode.clusterAddress}:${toString cfg.clientPort}" ];
      listenPeerUrls = [ "http://${localNode.clusterAddress}:${toString cfg.peerPort}" ];
      initialAdvertisePeerUrls = [ "http://${localNode.clusterAddress}:${toString cfg.peerPort}" ];
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
      wants = [ "network-online.target" "tailscaled.service" ];
      after = [ "network-online.target" "tailscaled.service" ];
      unitConfig.StartLimitIntervalSec = 0;
      serviceConfig = {
        Type = lib.mkForce "simple";
        TimeoutStartSec = "infinity";
        ExecStartPre = [
          "${pkgs.writeShellScript "alanix-wait-for-cluster-interface" ''
          set -euo pipefail

          for _ in $("${pkgs.coreutils}/bin/seq" 1 60); do
            if "${pkgs.iproute2}/bin/ip" -o addr show dev ${lib.escapeShellArg clusterInterface} | "${pkgs.gnugrep}/bin/grep" -F ${lib.escapeShellArg localNode.clusterAddress} >/dev/null 2>&1; then
              exit 0
            fi
            "${pkgs.coreutils}/bin/sleep" 1
          done

          echo "Timed out waiting for ${clusterInterface} to have ${localNode.clusterAddress}" >&2
          exit 1
          ''}"
        ];
      };
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
      (pkgs.writeShellApplication {
        name = "alanix-etcd-local-health";
        runtimeInputs = [ config.services.etcd.package ];
        text = ''
          exec etcdctl --endpoints ${lib.escapeShellArg "http://127.0.0.1:${toString cfg.clientPort}"} endpoint health
        '';
      })
    ];

    networking.firewall.interfaces.${clusterInterface}.allowedTCPPorts = [
      cfg.clientPort
      cfg.peerPort
    ];
  };
}
