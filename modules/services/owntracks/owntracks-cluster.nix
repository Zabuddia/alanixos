{ config, lib, pkgs, ... }:
let
  cfg = config.alanix.owntracks;
  helpers = import ../../../lib/clusterServiceAdapter.nix { inherit config lib; };
  inherit (helpers) backupPrepProgressHelpers backupRepoUserGroup;
  enabled = cfg.enable && cfg.cluster.enable;

  viewerUsernames =
    if enabled then
      builtins.filter (username: cfg.users.${username}.recorderViewer) (builtins.attrNames cfg.users)
    else
      [ ];

  viewerPasswordPath =
    username:
    let
      userCfg = cfg.users.${username};
    in
    if userCfg.passwordFile != null then
      toString userCfg.passwordFile
    else if userCfg.passwordSecret != null && lib.hasAttrByPath [ "sops" "secrets" userCfg.passwordSecret "path" ] config then
      config.sops.secrets.${userCfg.passwordSecret}.path
    else
      null;

  mosquittoDataDir = config.services.mosquitto.dataDir;
  stagedMosquittoDataDir = "${cfg.backupDir}${mosquittoDataDir}";
  stagedRecorderStateDir = "${cfg.backupDir}${cfg.recorder.stateDir}";
  recorderGhashDir = "${cfg.recorder.stateDir}/store/ghash";
  stagedRecorderGhashDir = "${stagedRecorderStateDir}/store/ghash";

  anyCaddyRecorderExposure =
    cfg.recorder.expose.wan.enable
    || cfg.recorder.expose.tailscale.enable
    || (cfg.recorder.expose.tor.enable && cfg.recorder.expose.tor.tls);

  backupPrepScript = pkgs.writeShellScript "alanix-owntracks-cluster-backup-runtime" ''
    set -euo pipefail

    backup_dir=${lib.escapeShellArg cfg.backupDir}
    backup_group=${lib.escapeShellArg backupRepoUserGroup}
    mosquitto_data_dir=${lib.escapeShellArg mosquittoDataDir}
    recorder_state_dir=${lib.escapeShellArg cfg.recorder.stateDir}
    staged_mosquitto_data_dir=${lib.escapeShellArg stagedMosquittoDataDir}
    staged_recorder_state_dir=${lib.escapeShellArg stagedRecorderStateDir}
    recorder_ghash_dir=${lib.escapeShellArg recorderGhashDir}
    staged_recorder_ghash_dir=${lib.escapeShellArg stagedRecorderGhashDir}

    ${backupPrepProgressHelpers}

    rm -rf "$backup_dir"
    mkdir -p "$backup_dir"

    emit_prep_step 1 4 ${lib.escapeShellArg "flushing mosquitto persistence"}
    systemctl kill -s SIGUSR1 mosquitto.service
    sleep 2

    rsync_prep_step 2 4 ${lib.escapeShellArg "staging ${mosquittoDataDir}"} "$mosquitto_data_dir" "$staged_mosquitto_data_dir"
    rsync_prep_step 3 4 ${lib.escapeShellArg "staging ${cfg.recorder.stateDir}"} "$recorder_state_dir" "$staged_recorder_state_dir"

    emit_prep_step 4 4 ${lib.escapeShellArg "snapshotting owntracks recorder LMDB"}
    if [[ -f "$recorder_ghash_dir/data.mdb" ]]; then
      rm -rf "$staged_recorder_ghash_dir"
      mkdir -p "$staged_recorder_ghash_dir"
      ${pkgs.lmdb}/bin/mdb_copy "$recorder_ghash_dir" "$staged_recorder_ghash_dir"
    fi

    chown -R mosquitto:mosquitto "$staged_mosquitto_data_dir"
    chown -R owntracks:owntracks "$staged_recorder_state_dir"
    chgrp -R "$backup_group" "$backup_dir"
    chmod -R u=rwX,g=rX,o= "$backup_dir"
  '';

  restoreScript = pkgs.writeShellScript "alanix-owntracks-cluster-restore-runtime" ''
    set -euo pipefail

    backup_dir=${lib.escapeShellArg cfg.backupDir}
    mosquitto_data_dir=${lib.escapeShellArg mosquittoDataDir}
    recorder_state_dir=${lib.escapeShellArg cfg.recorder.stateDir}
    staged_mosquitto_data_dir=${lib.escapeShellArg stagedMosquittoDataDir}
    staged_recorder_state_dir=${lib.escapeShellArg stagedRecorderStateDir}
    trap 'rm -rf "$backup_dir"' EXIT

    restore_dir() {
      local target="$1"
      local staged_dir="$2"

      if [[ -e "$target" && ! -d "$target" ]]; then
        rm -rf "$target"
      fi
      mkdir -p "$target"

      if [[ -d "$staged_dir" ]]; then
        rsync -a --delete "$staged_dir"/ "$target"/
      else
        rm -rf "$target"
        mkdir -p "$target"
      fi
    }

    restore_dir "$mosquitto_data_dir" "$staged_mosquitto_data_dir"
    restore_dir "$recorder_state_dir" "$staged_recorder_state_dir"

    chown -R mosquitto:mosquitto "$mosquitto_data_dir"
    chown -R owntracks:owntracks "$recorder_state_dir"
  '';
in
{
  config = lib.mkIf enabled (lib.mkMerge [
    {
    assertions = [
      {
        assertion = lib.hasPrefix "/" cfg.recorder.stateDir;
        message = "OwnTracks cluster mode requires alanix.owntracks.recorder.stateDir to be an absolute path.";
      }
      {
        assertion = lib.hasPrefix "/" cfg.backupDir;
        message = "OwnTracks cluster mode requires alanix.owntracks.backupDir to be an absolute path.";
      }
      {
        assertion = lib.all (username: viewerPasswordPath username != null) viewerUsernames;
        message = "OwnTracks cluster mode requires recorderViewer users to use passwordFile or passwordSecret.";
      }
    ];

    alanix.clusterServices.owntracks = {
      label = "OwnTracks";
      controller = {
        name = "owntracks";
        label = "OwnTracks";
        backupInterval = cfg.cluster.backupInterval;
        maxBackupAge = cfg.cluster.maxBackupAge;
        activeUnits = [
          "mosquitto.service"
          "ot-recorder.service"
        ];
        backupPaths = [ cfg.backupDir ];
        preBackupCommand = [ backupPrepScript ];
        postBackupCommand = [ "rm" "-rf" cfg.backupDir ];
        postRestoreCommand = [ restoreScript ];
        restoreTarget = "/";
      };
      targetUnits = [
        "mosquitto.service"
        "ot-recorder.service"
      ];
      exposureUnits = [ "ot-recorder.service" ];
      firewallAllowedTCPPorts = [ cfg.mqtt.publicPort ];
      tmpfiles = [
        "d ${cfg.backupDir} 0750 root ${backupRepoUserGroup} - -"
      ];
      extraExposureStart = lib.optionalString anyCaddyRecorderExposure ''
        owntracks_auth_file="$runtime_dir/caddy/owntracks-basic-auth.caddy"
        : > "$owntracks_auth_file"
        cat >> "$owntracks_auth_file" <<'EOF'
        basic_auth {
        EOF
        ${lib.concatMapStringsSep "\n" (username: ''
          owntracks_hash="$(${config.services.caddy.package}/bin/caddy hash-password --plaintext "$(tr -d '\n' < ${lib.escapeShellArg (viewerPasswordPath username)})")"
          printf '  %s %s\n' ${lib.escapeShellArg username} "$owntracks_hash" >> "$owntracks_auth_file"
        '') viewerUsernames}
        cat >> "$owntracks_auth_file" <<'EOF'
        }
        EOF
      '';
      webEndpoints = [
        {
          id = "owntracks";
          label = "OwnTracks";
          endpoint = {
            address = cfg.recorder.listenAddress;
            port = cfg.recorder.port;
            protocol = "http";
          };
          expose = cfg.recorder.expose;
          extraCaddyConfig = ''
            @owntracks_pub path /pub /pub/*
            respond @owntracks_pub 404
            import "$owntracks_auth_file"
          '';
        }
      ];
    };
    }
    (helpers.mkActiveTargetUnits [
      "mosquitto.service"
      "ot-recorder.service"
    ])
  ]);
}
