{ config, lib, hostname, ... }:
let
  cfg = config.alanix.filebrowserBackups;

  localNodeName = cfg.nodeName;
  nodes = cfg.nodes;
  localNodeExists = builtins.hasAttr localNodeName nodes;

  orderedNodeNames =
    lib.sort (a: b: nodes.${a}.priority < nodes.${b}.priority) (builtins.attrNames nodes);

  remoteNodeNames = lib.filter (name: name != localNodeName) orderedNodeNames;

  mkBackupJobName = targetName: "filebrowser-to-${targetName}";

  mkRepository = targetName:
    "sftp:${nodes.${targetName}.sshTarget}:${cfg.repositoryBasePath}/${localNodeName}";

  mkSftpCommand = targetName:
    "sftp.command='ssh -i ${config.sops.secrets.${cfg.sshKeySecret}.path} -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=${cfg.stateDir}/known_hosts ${nodes.${targetName}.sshTarget} -s sftp'";

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
          paths = cfg.paths;
          passwordFile = config.sops.secrets.${cfg.passwordSecret}.path;
          extraOptions = [ (mkSftpCommand targetName) ];
          pruneOpts = cfg.pruneOpts;
          runCheck = cfg.runCheck;
          checkOpts = cfg.checkOpts;
          timerConfig = {
            OnCalendar = cfg.schedule;
            RandomizedDelaySec = cfg.randomizedDelaySec;
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
        value = lib.optionalAttrs (cfg.activeMarkerPath != null) {
          serviceConfig = {
            ConditionPathExists = cfg.activeMarkerPath;
          };
        };
      })
    remoteNodeNames);
in
{
  options.alanix.filebrowserBackups = {
    enable = lib.mkEnableOption "Restic backups for Filebrowser data";

    nodeName = lib.mkOption {
      type = lib.types.str;
      default = hostname;
      description = "Local node name; must match a key in alanix.filebrowserBackups.nodes.";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/alanix-filebrowser-backups";
      description = "State directory used for SSH known_hosts tracking.";
    };

    activeMarkerPath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "/run/alanix-filebrowser-failover/active";
      description = ''
        If set, restic backup jobs only run when this marker exists.
        This keeps backups single-writer on the currently active node.
      '';
    };

    repositoryBasePath = lib.mkOption {
      type = lib.types.str;
      default = "/var/backups/restic/filebrowser";
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
      default = [
        "/var/lib/filebrowser"
        "/srv/filebrowser"
      ];
      description = "Paths included in filebrowser restic snapshots.";
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

          vpnIP = lib.mkOption {
            type = lib.types.str;
          };

          sshTarget = lib.mkOption {
            type = lib.types.str;
            default = "root@${config.vpnIP}";
          };
        };
      }));
      description = "All nodes participating in filebrowser backups.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions =
      [
        {
          assertion = cfg.nodes != {};
          message = "alanix.filebrowserBackups.nodes must not be empty.";
        }
        {
          assertion = localNodeExists;
          message = "alanix.filebrowserBackups.nodeName '${localNodeName}' is not present in alanix.filebrowserBackups.nodes.";
        }
        {
          assertion = cfg.passwordSecret != null;
          message = "alanix.filebrowserBackups.passwordSecret must be set when enabled.";
        }
        {
          assertion = cfg.sshKeySecret != null;
          message = "alanix.filebrowserBackups.sshKeySecret must be set when enabled.";
        }
      ];

    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0700 root root - -"
      "d ${cfg.repositoryBasePath} 0700 root root - -"
    ];

    services.restic.backups = backupJobs;

    # Ensure restic jobs run only on active role when using failover marker.
    systemd.services = backupServiceConditions;
  };
}
