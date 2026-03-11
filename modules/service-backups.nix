{ config, lib, hostname, ... }:
let
  cfg = config.alanix.serviceBackups;
  enabledInstances = lib.filterAttrs (_: inst: inst.enable) cfg.instances;

  mkInstance = name: inst:
    let
      localNodeName = inst.nodeName;
      nodes = inst.nodes;
      localNodeExists = builtins.hasAttr localNodeName nodes;

      orderedNodeNames =
        lib.sort (a: b: nodes.${a}.priority < nodes.${b}.priority) (builtins.attrNames nodes);
      remoteNodeNames = lib.filter (n: n != localNodeName) orderedNodeNames;

      mkBackupJobName = targetName: "${name}-to-${targetName}";
      mkRepository = targetName:
        "sftp:${nodes.${targetName}.sshTarget}:${inst.repositoryBasePath}/${localNodeName}";
      mkSftpCommand = targetName:
        "sftp.command='ssh -i ${config.sops.secrets.${inst.sshKeySecret}.path} -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=${inst.stateDir}/known_hosts ${nodes.${targetName}.sshTarget} -s sftp'";

      backupJobs = builtins.listToAttrs (map
        (targetName:
          let
            jobName = mkBackupJobName targetName;
          in
          {
            name = jobName;
            value = {
              repository = mkRepository targetName;
              initialize = true;
              paths = inst.paths;
              passwordFile = config.sops.secrets.${inst.passwordSecret}.path;
              extraOptions = [ (mkSftpCommand targetName) ];
              pruneOpts = inst.pruneOpts;
              runCheck = inst.runCheck;
              checkOpts = inst.checkOpts;
              timerConfig = {
                OnCalendar = inst.schedule;
                RandomizedDelaySec = inst.randomizedDelaySec;
                Persistent = true;
              };
            };
          })
        remoteNodeNames);

      backupServiceConditions = builtins.listToAttrs (map
        (targetName:
          let
            serviceName = "restic-backups-${mkBackupJobName targetName}";
          in
          {
            name = serviceName;
            value = lib.optionalAttrs (inst.activeMarkerPath != null) {
              serviceConfig = {
                ConditionPathExists = inst.activeMarkerPath;
              };
            };
          })
        remoteNodeNames);
    in
    {
      inherit name inst localNodeExists backupJobs backupServiceConditions;
    };

  instances = lib.mapAttrs mkInstance enabledInstances;

  allBackupJobs = lib.foldl' lib.recursiveUpdate {} (map (v: v.backupJobs) (builtins.attrValues instances));
  allServiceConditions = lib.foldl' lib.recursiveUpdate {} (map (v: v.backupServiceConditions) (builtins.attrValues instances));
in
{
  options.alanix.serviceBackups = {
    instances = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({ name, config, ... }: {
        options = {
          enable = lib.mkEnableOption "Restic backups for ${name} data";

          nodeName = lib.mkOption {
            type = lib.types.str;
            default = hostname;
            description = "Local node name; must match a key in nodes.";
          };

          stateDir = lib.mkOption {
            type = lib.types.str;
            default = "/var/lib/alanix-${name}-backups";
            description = "State directory used for SSH known_hosts tracking.";
          };

          activeMarkerPath = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = "/run/alanix-${name}-failover/active";
            description = ''
              If set, restic backup jobs only run when this marker exists.
              This keeps backups single-writer on the currently active node.
            '';
          };

          repositoryBasePath = lib.mkOption {
            type = lib.types.str;
            default = "/var/backups/restic/${name}";
            description = "Base directory on each node used as incoming restic repository storage.";
          };

          schedule = lib.mkOption {
            type = lib.types.str;
            default = "hourly";
            description = "Systemd OnCalendar schedule for backup timers.";
          };

          randomizedDelaySec = lib.mkOption {
            type = lib.types.str;
            default = "10m";
          };

          paths = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ "/var/lib/${name}" ];
            description = "Paths included in restic snapshots.";
          };

          pruneOpts = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [
              "--keep-hourly 24"
              "--keep-daily 7"
              "--keep-weekly 4"
              "--keep-monthly 6"
            ];
            description = "Retention policy arguments passed to restic forget --prune.";
          };

          runCheck = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Whether to run restic check after each backup.";
          };

          checkOpts = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ "--read-data-subset=10%" ];
            description = "Options passed to restic check when runCheck is enabled.";
          };

          passwordSecret = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "sops secret containing the restic repository password.";
          };

          sshKeySecret = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "sops secret containing SSH private key used for sftp transport.";
          };

          nodes = lib.mkOption {
            type = lib.types.attrsOf (lib.types.submodule ({ config, ... }: {
              options = {
                priority = lib.mkOption {
                  type = lib.types.int;
                  description = "Lower value means higher priority.";
                };

                clusterAddress = lib.mkOption {
                  type = lib.types.str;
                };

                clusterDnsName = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                };

                sshTarget = lib.mkOption {
                  type = lib.types.str;
                  default = "root@${config.clusterAddress}";
                };
              };
            }));
            description = "All nodes participating in backups.";
          };
        };
      }));
      default = {};
      description = "Declarative restic backup instances keyed by service name.";
    };
  };

  config = lib.mkIf (enabledInstances != {}) {
    assertions =
      lib.flatten (lib.mapAttrsToList (name: v: [
        {
          assertion = v.inst.nodes != {};
          message = "alanix.serviceBackups.instances.${name}.nodes must not be empty.";
        }
        {
          assertion = v.localNodeExists;
          message = "alanix.serviceBackups.instances.${name}.nodeName '${v.inst.nodeName}' is not present in nodes.";
        }
        {
          assertion = v.inst.passwordSecret != null;
          message = "alanix.serviceBackups.instances.${name}.passwordSecret must be set when enabled.";
        }
        {
          assertion = v.inst.sshKeySecret != null;
          message = "alanix.serviceBackups.instances.${name}.sshKeySecret must be set when enabled.";
        }
      ]) instances);

    systemd.tmpfiles.rules =
      lib.flatten (lib.mapAttrsToList (_: v: [
        "d ${v.inst.stateDir} 0700 root root - -"
        "d ${v.inst.repositoryBasePath} 0700 root root - -"
      ]) instances);

    services.restic.backups = allBackupJobs;
    systemd.services = allServiceConditions;
  };
}
