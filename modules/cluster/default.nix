{ config, lib, pkgs, hostname, allHosts, ... }:
let
  cfg = config.alanix.cluster;
  types = lib.types;
  serviceExposure = import ../../lib/mkServiceExposure.nix { inherit lib pkgs; };

  parseDurationMs =
    value:
    let
      msMatch = builtins.match "^([0-9]+)ms$" value;
      sMatch = builtins.match "^([0-9]+)s$" value;
    in
    if msMatch != null then
      builtins.fromJSON (builtins.head msMatch)
    else if sMatch != null then
      1000 * builtins.fromJSON (builtins.head sMatch)
    else
      throw "Unsupported duration `${value}`. Use <n>ms or <n>s.";

  normalizeLocalAddress =
    address:
    if address == "0.0.0.0" then
      "127.0.0.1"
    else if address == "::" then
      "::1"
    else
      address;
in
{
  options.alanix.cluster = {
    enable = lib.mkEnableOption "Alanix cluster controller";

    name = lib.mkOption {
      type = types.str;
      default = "cluster";
    };

    transport = lib.mkOption {
      type = types.enum [ "tailscale" "wireguard" ];
      default = "tailscale";
    };

    members = lib.mkOption {
      type = types.listOf types.str;
      default = [ ];
    };

    voters = lib.mkOption {
      type = types.listOf types.str;
      default = [ ];
    };

    priority = lib.mkOption {
      type = types.listOf types.str;
      default = [ ];
    };

    addresses = lib.mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "Cluster transport address for each member, keyed by hostname.";
    };

    etcd = {
      bootstrapGeneration = lib.mkOption {
        type = types.int;
        default = 1;
        description = ''
          Explicit etcd bootstrap generation. Bump this when cluster membership or
          initial etcd topology changes and the cluster should be re-initialized.
        '';
      };

      heartbeatInterval = lib.mkOption {
        type = types.str;
        default = "500ms";
      };

      electionTimeout = lib.mkOption {
        type = types.str;
        default = "5s";
      };

      leaseTtl = lib.mkOption {
        type = types.str;
        default = "30s";
      };

      renewEvery = lib.mkOption {
        type = types.str;
        default = "5s";
      };

      acquisitionStep = lib.mkOption {
        type = types.str;
        default = "5s";
      };
    };

    backup = {
      repoUser = lib.mkOption {
        type = types.str;
        default = "buddia";
      };

      repoBaseDir = lib.mkOption {
        type = types.str;
        default = "/var/lib/alanix-backups";
      };

      passwordSecret = lib.mkOption {
        type = types.str;
        default = "cluster/restic-password";
      };
    };

    dashboard = {
      enable = lib.mkEnableOption "Alanix cluster dashboard";

      listenAddress = lib.mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "Local bind address for the cluster dashboard.";
      };

      port = lib.mkOption {
        type = types.port;
        default = 9842;
        description = "Local HTTP port for the cluster dashboard.";
      };

      recentEvents = lib.mkOption {
        type = types.int;
        default = 40;
        description = "Number of recent controller events to show in the dashboard.";
      };

      expose = serviceExposure.mkOptions {
        serviceName = "cluster-dashboard";
        serviceDescription = "Cluster Dashboard";
        defaultPublicPort = 80;
      };
    };

    ddns = {
      enable = lib.mkEnableOption "cluster-leader-tracking Cloudflare DDNS";

      domains = lib.mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Domains to point at the current cluster leader via Cloudflare DDNS.";
      };

      credentialsFile = lib.mkOption {
        type = types.path;
        description = "Path to file containing CLOUDFLARE_API_TOKEN=<token>.";
      };
    };
  };

  config = lib.mkIf cfg.enable (
    let
      hostTransportAddress = hostName: cfg.addresses.${hostName} or null;
      localTransportAddress = hostTransportAddress hostname;
      isVoter = builtins.elem hostname cfg.voters;

      nextcloudCfg = config.alanix.nextcloud;
      nextcloudCollaboraCfg = nextcloudCfg.collabora;
      filebrowserCfg = config.alanix.filebrowser;
      radicaleCfg = config.alanix.radicale;
      vaultwardenCfg = config.alanix.vaultwarden;
      forgejoCfg = config.alanix.forgejo;
      invidiousCfg = config.alanix.invidious;
      immichCfg = config.alanix.immich;
      jellyfinCfg = config.alanix.jellyfin;
      openwebuiCfg = config.alanix.openwebui;
      searxngCfg = config.alanix.searxng;
      nextcloudCluster = nextcloudCfg.enable && nextcloudCfg.cluster.enable;
      filebrowserCluster = filebrowserCfg.enable && filebrowserCfg.cluster.enable;
      radicaleCluster = radicaleCfg.enable && radicaleCfg.cluster.enable;
      vaultwardenCluster = vaultwardenCfg.enable && vaultwardenCfg.cluster.enable;
      forgejoCluster = forgejoCfg.enable && forgejoCfg.cluster.enable;
      invidiousCluster = invidiousCfg.enable && invidiousCfg.cluster.enable;
      immichCluster = immichCfg.enable && immichCfg.cluster.enable;
      jellyfinCluster = jellyfinCfg.enable && jellyfinCfg.cluster.enable;
      openwebuiCluster = openwebuiCfg.enable && openwebuiCfg.cluster.enable;
      searxngCluster = searxngCfg.enable && searxngCfg.cluster.enable;
      dashboardCfg = cfg.dashboard;
      ddnsCfg = cfg.ddns;
      dashboardEndpoint = {
        address = dashboardCfg.listenAddress;
        port = dashboardCfg.port;
        protocol = "http";
      };

      peerHostCfg = peer: lib.attrByPath [ peer ] null allHosts;

      peerTailscaleAddress =
        peer:
        let
          hostCfg = peerHostCfg peer;
        in
        if hostCfg != null then hostCfg.config.alanix.tailscale.address else null;

      peerWireguardAddress =
        peer:
        let
          hostCfg = peerHostCfg peer;
        in
        if hostCfg != null then hostCfg.config.alanix.wireguard.vpnIP else null;

      mkUrl =
        {
          scheme,
          host,
          port,
          path ? "/",
        }:
        let
          defaultPort =
            if scheme == "https" then
              443
            else
              80;
          portSuffix = if port == defaultPort then "" else ":${toString port}";
        in
        "${scheme}://${host}${portSuffix}${path}";

      mkConstantLinksByHost =
        links:
        lib.listToAttrs (
          map (peer: {
            name = peer;
            value = links;
          }) cfg.members
        );

      mkPeerLinksByHost =
        {
          label,
          transport,
          scheme,
          port,
          addressFn,
        }:
        lib.listToAttrs (
          map (peer: {
            name = peer;
            value =
              let
                address = addressFn peer;
              in
              lib.optionals (address != null && address != "") [
                {
                  inherit scheme transport;
                  label = "${label} (${transport})";
                  host = peer;
                  url = mkUrl {
                    inherit scheme port;
                    host = address;
                  };
                }
              ];
          }) cfg.members
        );

      mkPeerConfigLinksByHost =
        {
          label,
          transport ? "canonical",
          urlFn,
        }:
        lib.listToAttrs (
          map (peer: {
            name = peer;
            value =
              let
                url = urlFn peer;
              in
              lib.optionals (url != null && url != "") [
                {
                  inherit label transport;
                  host = peer;
                  url = url;
                }
              ];
          }) cfg.members
        );

      mergeLinksByHost =
        attrsets:
        lib.listToAttrs (
          map (peer: {
            name = peer;
            value = lib.concatLists (map (attrs: attrs.${peer} or [ ]) attrsets);
          }) cfg.members
        );

      peerDashboardTorHostname =
        peer:
        let
          hostCfg = peerHostCfg peer;
        in
        if hostCfg != null then hostCfg.config.alanix.cluster.dashboard.expose.tor.hostname else null;

      dashboardLinks =
        lib.optionals dashboardCfg.expose.tailscale.enable (
          map (peer: {
            label = "${peer} dashboard (tailscale)";
            host = peer;
            transport = "tailscale";
            url = mkUrl {
              scheme = "http";
              host = peerTailscaleAddress peer;
              port = dashboardCfg.expose.tailscale.port;
            };
          }) (lib.filter (peer: peerTailscaleAddress peer != null && peerTailscaleAddress peer != "") cfg.members)
        )
        ++ lib.optionals dashboardCfg.expose.wireguard.enable (
          map (peer: {
            label = "${peer} dashboard (wireguard)";
            host = peer;
            transport = "wireguard";
            url = mkUrl {
              scheme = "http";
              host = peerWireguardAddress peer;
              port = dashboardCfg.expose.wireguard.port;
            };
          }) (lib.filter (peer: peerWireguardAddress peer != null && peerWireguardAddress peer != "") cfg.members)
        )
        ++ lib.optionals dashboardCfg.expose.tor.enable (
          lib.concatMap (peer:
            let torHostname = peerDashboardTorHostname peer;
            in lib.optionals (torHostname != null) [{
              label = "${peer} dashboard (tor)";
              host = peer;
              transport = "tor";
              url = "http://${torHostname}/";
            }]
          ) cfg.members
        );

      vaultwardenRestoreScript =
        if vaultwardenCluster then
          pkgs.writeShellScript "alanix-vaultwarden-cluster-restore-runtime" ''
            set -euo pipefail

            backup_dir=${lib.escapeShellArg vaultwardenCfg.backupDir}
            data_dir=/var/lib/vaultwarden

            rm -rf "$data_dir"
            mkdir -p "$data_dir"
            cp -a "$backup_dir"/. "$data_dir"/
            chown -R vaultwarden:vaultwarden "$backup_dir" "$data_dir"
          ''
        else
          null;

      filebrowserRestoreScript =
        if filebrowserCluster then
          let
            stagedDatabasePath = "${filebrowserCfg.backupDir}${filebrowserCfg.database}";
          in
          pkgs.writeShellScript "alanix-filebrowser-cluster-restore-runtime" ''
            set -euo pipefail

            backup_dir=${lib.escapeShellArg filebrowserCfg.backupDir}
            db_path=${lib.escapeShellArg filebrowserCfg.database}
            staged_db_path=${lib.escapeShellArg stagedDatabasePath}

            mkdir -p "$(dirname "$db_path")"

            if [[ -f "$staged_db_path" ]]; then
              cp -a "$staged_db_path" "$db_path"
              chown filebrowser:filebrowser "$db_path"
            fi

            chown -R filebrowser:filebrowser "$backup_dir"
          ''
        else
          null;

      radicaleRestoreScript =
        if radicaleCluster then
          let
            stagedStorageDir = "${radicaleCfg.backupDir}${radicaleCfg.storageDir}";
          in
          pkgs.writeShellScript "alanix-radicale-cluster-restore-runtime" ''
            set -euo pipefail

            backup_dir=${lib.escapeShellArg radicaleCfg.backupDir}
            storage_dir=${lib.escapeShellArg radicaleCfg.storageDir}
            staged_storage_dir=${lib.escapeShellArg stagedStorageDir}

            rm -rf "$storage_dir"
            mkdir -p "$storage_dir"

            if [[ -d "$staged_storage_dir" ]]; then
              cp -a "$staged_storage_dir"/. "$storage_dir"/
            fi

            chown -R radicale:radicale "$backup_dir" "$storage_dir"
          ''
        else
          null;

      backupRepoUserGroup =
        if lib.hasAttrByPath [ "users" "users" cfg.backup.repoUser ] config then
          config.users.users.${cfg.backup.repoUser}.group
        else
          null;

      nextcloudDataDir = if nextcloudCfg.dataDir != null then nextcloudCfg.dataDir else nextcloudCfg.stateDir;
      nextcloudClusteredPaths = lib.unique (
        [ nextcloudCfg.stateDir ]
        ++ lib.optional (nextcloudDataDir != nextcloudCfg.stateDir) nextcloudDataDir
      );

      jellyfinClusteredPaths =
        [ jellyfinCfg.dataDir ];

      forgejoRestoreScript =
        if forgejoCluster then
          let
            stagedStateDir = "${forgejoCfg.backupDir}${forgejoCfg.stateDir}";
            stagedDbPath = "${forgejoCfg.backupDir}${config.services.forgejo.database.path}";
          in
          pkgs.writeShellScript "alanix-forgejo-cluster-restore-runtime" ''
            set -euo pipefail

            backup_dir=${lib.escapeShellArg forgejoCfg.backupDir}
            state_dir=${lib.escapeShellArg forgejoCfg.stateDir}
            db_path=${lib.escapeShellArg config.services.forgejo.database.path}
            staged_state_dir=${lib.escapeShellArg stagedStateDir}
            staged_db_path=${lib.escapeShellArg stagedDbPath}

            rm -rf "$state_dir"
            mkdir -p "$state_dir"
            if [[ -d "$staged_state_dir" ]]; then
              cp -a "$staged_state_dir"/. "$state_dir"/
            fi

            mkdir -p "$(dirname "$db_path")"
            cp -a "$staged_db_path" "$db_path"

            chown -R forgejo:forgejo "$backup_dir" "$state_dir"
            chown forgejo:forgejo "$db_path"
          ''
        else
          null;

      invidiousRestoreScript =
        if invidiousCluster then
          let
            invidiousStateDir = "/var/lib/invidious";
            companionStateDir = "/var/lib/invidious-companion";
            stagedInvidiousStateDir = "${invidiousCfg.backupDir}${invidiousStateDir}";
            stagedCompanionStateDir = "${invidiousCfg.backupDir}${companionStateDir}";
            stagedDatabaseDump = "${invidiousCfg.backupDir}/database/invidious.pgcustom";
          in
          pkgs.writeShellScript "alanix-invidious-cluster-restore-runtime" ''
            set -euo pipefail

            backup_dir=${lib.escapeShellArg invidiousCfg.backupDir}
            state_dir=${lib.escapeShellArg invidiousStateDir}
            companion_dir=${lib.escapeShellArg companionStateDir}
            staged_state_dir=${lib.escapeShellArg stagedInvidiousStateDir}
            staged_companion_dir=${lib.escapeShellArg stagedCompanionStateDir}
            staged_dump=${lib.escapeShellArg stagedDatabaseDump}
            pg_user=${lib.escapeShellArg config.services.invidious.settings.db.user}
            pg_database=${lib.escapeShellArg config.services.invidious.settings.db.dbname}

            rm -rf "$state_dir" "$companion_dir"
            mkdir -p "$state_dir" "$companion_dir"

            if [[ -d "$staged_state_dir" ]]; then
              cp -a "$staged_state_dir"/. "$state_dir"/
            fi

            if [[ -d "$staged_companion_dir" ]]; then
              cp -a "$staged_companion_dir"/. "$companion_dir"/
            fi

            chown -R invidious:invidious "$backup_dir" "$state_dir" "$companion_dir"

            if [[ -f "$staged_dump" ]]; then
              runuser -u invidious -- env \
                PGHOST=/run/postgresql \
                PGUSER="$pg_user" \
                PGDATABASE="$pg_database" \
                pg_restore \
                  --clean \
                  --if-exists \
                  --no-owner \
                  --no-privileges \
                  --exit-on-error \
                  --dbname="$pg_database" \
                  "$staged_dump"
            fi
          ''
        else
          null;

      immichRestoreScript =
        if immichCluster then
          let
            stagedMediaDir = "${immichCfg.backupDir}${toString immichCfg.mediaLocation}";
            stagedDatabaseDump = "${immichCfg.backupDir}/database/immich.pgcustom";
          in
          pkgs.writeShellScript "alanix-immich-cluster-restore-runtime" ''
            set -euo pipefail

            backup_dir=${lib.escapeShellArg immichCfg.backupDir}
            media_dir=${lib.escapeShellArg (toString immichCfg.mediaLocation)}
            staged_media_dir=${lib.escapeShellArg stagedMediaDir}
            staged_dump=${lib.escapeShellArg stagedDatabaseDump}
            pg_host=${lib.escapeShellArg config.services.immich.database.host}
            pg_user=${lib.escapeShellArg config.services.immich.database.user}
            pg_database=${lib.escapeShellArg config.services.immich.database.name}

            rm -rf "$media_dir"
            mkdir -p "$media_dir"

            if [[ -d "$staged_media_dir" ]]; then
              cp -a "$staged_media_dir"/. "$media_dir"/
            fi

            chown -R immich:immich "$backup_dir" "$media_dir"

            if [[ -f "$staged_dump" ]]; then
              restore_dump="$(mktemp /var/tmp/alanix-immich-restore-XXXXXX.pgcustom)"
              trap 'rm -f "$restore_dump"' EXIT

              install -m 0600 -o postgres -g postgres "$staged_dump" "$restore_dump"

              runuser -u postgres -- env \
                PGHOST="$pg_host" \
                dropdb --if-exists "$pg_database"

              runuser -u postgres -- env \
                PGHOST="$pg_host" \
                createdb --owner="$pg_user" "$pg_database"

              runuser -u postgres -- env \
                PGHOST="$pg_host" \
                pg_restore \
                  --clean \
                  --if-exists \
                  --no-privileges \
                  --exit-on-error \
                  --dbname="$pg_database" \
                  "$restore_dump"
            fi
          ''
        else
          null;

      nextcloudRestoreScript =
        if nextcloudCluster then
          let
            stagedDatabaseDump = "${nextcloudCfg.backupDir}/database/nextcloud.pgcustom";
          in
          pkgs.writeShellScript "alanix-nextcloud-cluster-restore-runtime" ''
            set -euo pipefail

            backup_dir=${lib.escapeShellArg nextcloudCfg.backupDir}
            staged_dump=${lib.escapeShellArg stagedDatabaseDump}
            pg_host=${lib.escapeShellArg config.services.nextcloud.config.dbhost}
            pg_user=${lib.escapeShellArg config.services.nextcloud.config.dbuser}
            pg_database=${lib.escapeShellArg config.services.nextcloud.config.dbname}

            restore_dir() {
              local target="$1"
              local staged_dir="$backup_dir$target"

              rm -rf "$target"
              mkdir -p "$target"

              if [[ -d "$staged_dir" ]]; then
                cp -a "$staged_dir"/. "$target"/
              fi
            }

            ${lib.concatMapStringsSep "\n" (path: ''
              restore_dir ${lib.escapeShellArg path}
            '') nextcloudClusteredPaths}

            chown -R nextcloud:nextcloud ${lib.escapeShellArg nextcloudCfg.stateDir}
            ${lib.optionalString (nextcloudDataDir != nextcloudCfg.stateDir) ''
              chown -R nextcloud:nextcloud ${lib.escapeShellArg nextcloudDataDir}
            ''}

            # override.config.php is a node-local symlink into the Nix store.
            # Restoring from another node replaces it with a dangling cross-node path.
            # Re-apply tmpfiles to recreate the correct local symlink.
            rm -f ${lib.escapeShellArg "${nextcloudCfg.stateDir}/config/override.config.php"}
            systemd-tmpfiles --create --prefix=${lib.escapeShellArg "${nextcloudCfg.stateDir}/config/override.config.php"}

            if [[ -f "$staged_dump" ]]; then
              restore_dump="$(mktemp /var/tmp/alanix-nextcloud-restore-XXXXXX.pgcustom)"
              trap 'rm -f "$restore_dump"' EXIT

              install -m 0600 -o postgres -g postgres "$staged_dump" "$restore_dump"

              runuser -u postgres -- env \
                PGHOST="$pg_host" \
                dropdb --if-exists "$pg_database"

              runuser -u postgres -- env \
                PGHOST="$pg_host" \
                createdb --owner="$pg_user" "$pg_database"

              runuser -u postgres -- env \
                PGHOST="$pg_host" \
                pg_restore \
                  --clean \
                  --if-exists \
                  --no-privileges \
                  --exit-on-error \
                  --dbname="$pg_database" \
                  "$restore_dump"
            fi
          ''
        else
          null;

      jellyfinRestoreScript =
        if jellyfinCluster then
          let
            mediaFolderOwnershipFixups = lib.concatMapStringsSep "\n"
              (folderCfg: ''
                chown -R ${folderCfg.user}:${folderCfg.group} ${lib.escapeShellArg folderCfg.path}
              '')
              (builtins.attrValues jellyfinCfg.mediaFolders);
            recordingOwnershipFixup =
              lib.optionalString (
                jellyfinCfg.liveTv.recordingPath != null
                && !(lib.any (folderCfg: folderCfg.path == jellyfinCfg.liveTv.recordingPath) (builtins.attrValues jellyfinCfg.mediaFolders))
              ) ''
                chown -R root:root ${lib.escapeShellArg jellyfinCfg.liveTv.recordingPath}
              '';
          in
          pkgs.writeShellScript "alanix-jellyfin-cluster-restore-runtime" ''
            set -euo pipefail

            backup_dir=${lib.escapeShellArg jellyfinCfg.backupDir}

            restore_dir() {
              local target="$1"
              local staged_dir="$backup_dir$target"

              rm -rf "$target"
              mkdir -p "$target"

              if [[ -d "$staged_dir" ]]; then
                cp -a "$staged_dir"/. "$target"/
              fi
            }

            ${lib.concatMapStringsSep "\n" (path: ''
              restore_dir ${lib.escapeShellArg path}
            '') jellyfinClusteredPaths}

            chown -R jellyfin:jellyfin ${lib.escapeShellArg jellyfinCfg.dataDir}
            ${mediaFolderOwnershipFixups}
            ${recordingOwnershipFixup}

            system_xml=${lib.escapeShellArg "${jellyfinCfg.dataDir}/config/system.xml"}
            if [[ -f "$system_xml" ]]; then
              ${pkgs.gnused}/bin/sed -i 's|<ServerName>[^<]*</ServerName>|<ServerName>${hostname}</ServerName>|' "$system_xml"
            fi
          ''
        else
          null;

      openwebuiRestoreScript =
        if openwebuiCluster then
          let
            stagedStateDir = "${openwebuiCfg.backupDir}${openwebuiCfg.stateDir}";
          in
          pkgs.writeShellScript "alanix-openwebui-cluster-restore-runtime" ''
            set -euo pipefail

            backup_dir=${lib.escapeShellArg openwebuiCfg.backupDir}
            state_dir=${lib.escapeShellArg openwebuiCfg.stateDir}
            staged_state_dir=${lib.escapeShellArg stagedStateDir}

            rm -rf "$state_dir"
            mkdir -p "$state_dir"

            if [[ -d "$staged_state_dir" ]]; then
              cp -a "$staged_state_dir"/. "$state_dir"/
            fi

            chown -R open-webui:open-webui "$backup_dir" "$state_dir"
          ''
        else
          null;

      searxngRestoreScript =
        if searxngCluster then
          let
            stagedStateDir = "${searxngCfg.backupDir}${searxngCfg.stateDir}";
          in
          pkgs.writeShellScript "alanix-searxng-cluster-restore-runtime" ''
            set -euo pipefail

            backup_dir=${lib.escapeShellArg searxngCfg.backupDir}
            state_dir=${lib.escapeShellArg searxngCfg.stateDir}
            staged_state_dir=${lib.escapeShellArg stagedStateDir}

            rm -rf "$state_dir"
            mkdir -p "$state_dir"

            if [[ -d "$staged_state_dir" ]]; then
              cp -a "$staged_state_dir"/. "$state_dir"/
            fi

            chown -R searx:searx "$backup_dir" "$state_dir"
          ''
        else
          null;

      vaultwardenBackupPrepScript =
        if vaultwardenCluster then
          pkgs.writeShellScript "alanix-vaultwarden-cluster-backup-runtime" ''
            set -euo pipefail

            backup_dir=${lib.escapeShellArg vaultwardenCfg.backupDir}
            backup_group=${lib.escapeShellArg backupRepoUserGroup}

            mkdir -p "$backup_dir"
            chown -R vaultwarden:vaultwarden "$backup_dir"
            chmod -R u=rwX,go= "$backup_dir"

            systemctl start backup-vaultwarden.service

            if [[ -d "$backup_dir" ]]; then
              chgrp -R "$backup_group" "$backup_dir"
              chmod -R u=rwX,g=rX,o= "$backup_dir"
            fi
          ''
        else
          null;

      forgejoBackupPrepScript =
        if forgejoCluster then
          let
            stagedStateDir = "${forgejoCfg.backupDir}${forgejoCfg.stateDir}";
            stagedDbPath = "${forgejoCfg.backupDir}${config.services.forgejo.database.path}";
          in
          pkgs.writeShellScript "alanix-forgejo-cluster-backup-runtime" ''
            set -euo pipefail

            backup_dir=${lib.escapeShellArg forgejoCfg.backupDir}
            backup_group=${lib.escapeShellArg backupRepoUserGroup}
            state_dir=${lib.escapeShellArg forgejoCfg.stateDir}
            db_path=${lib.escapeShellArg config.services.forgejo.database.path}
            staged_state_dir=${lib.escapeShellArg stagedStateDir}
            staged_db_path=${lib.escapeShellArg stagedDbPath}

            rm -rf "$backup_dir"
            mkdir -p "$staged_state_dir" "$(dirname "$staged_db_path")"

            rsync -a --delete "$state_dir"/ "$staged_state_dir"/
            sqlite3 "$db_path" ".backup '$staged_db_path'"

            chown -R forgejo:forgejo "$backup_dir"
            chgrp -R "$backup_group" "$backup_dir"
            chmod -R u=rwX,g=rX,o= "$backup_dir"
          ''
        else
          null;

      invidiousBackupPrepScript =
        if invidiousCluster then
          let
            invidiousStateDir = "/var/lib/invidious";
            companionStateDir = "/var/lib/invidious-companion";
            stagedInvidiousStateDir = "${invidiousCfg.backupDir}${invidiousStateDir}";
            stagedCompanionStateDir = "${invidiousCfg.backupDir}${companionStateDir}";
            stagedDatabaseDump = "${invidiousCfg.backupDir}/database/invidious.pgcustom";
          in
          pkgs.writeShellScript "alanix-invidious-cluster-backup-runtime" ''
            set -euo pipefail

            backup_dir=${lib.escapeShellArg invidiousCfg.backupDir}
            backup_group=${lib.escapeShellArg backupRepoUserGroup}
            state_dir=${lib.escapeShellArg invidiousStateDir}
            companion_dir=${lib.escapeShellArg companionStateDir}
            staged_state_dir=${lib.escapeShellArg stagedInvidiousStateDir}
            staged_companion_dir=${lib.escapeShellArg stagedCompanionStateDir}
            staged_dump=${lib.escapeShellArg stagedDatabaseDump}
            pg_user=${lib.escapeShellArg config.services.invidious.settings.db.user}
            pg_database=${lib.escapeShellArg config.services.invidious.settings.db.dbname}

            rm -rf "$backup_dir"
            mkdir -p "$staged_state_dir" "$staged_companion_dir" "$(dirname "$staged_dump")"
            chown -R invidious:invidious "$backup_dir"

            if [[ -d "$state_dir" ]]; then
              rsync -a --delete "$state_dir"/ "$staged_state_dir"/
            fi

            if [[ -d "$companion_dir" ]]; then
              rsync -a --delete "$companion_dir"/ "$staged_companion_dir"/
            fi

            runuser -u invidious -- env \
              PGHOST=/run/postgresql \
              PGUSER="$pg_user" \
              PGDATABASE="$pg_database" \
              pg_dump \
                --format=custom \
                --file="$staged_dump" \
                "$pg_database"

            chown -R invidious:invidious "$backup_dir"
            chgrp -R "$backup_group" "$backup_dir"
            chmod -R u=rwX,g=rX,o= "$backup_dir"
          ''
        else
          null;

      immichBackupPrepScript =
        if immichCluster then
          let
            stagedMediaDir = "${immichCfg.backupDir}${toString immichCfg.mediaLocation}";
            stagedDatabaseDump = "${immichCfg.backupDir}/database/immich.pgcustom";
          in
          pkgs.writeShellScript "alanix-immich-cluster-backup-runtime" ''
            set -euo pipefail

            backup_dir=${lib.escapeShellArg immichCfg.backupDir}
            backup_group=${lib.escapeShellArg backupRepoUserGroup}
            media_dir=${lib.escapeShellArg (toString immichCfg.mediaLocation)}
            staged_media_dir=${lib.escapeShellArg stagedMediaDir}
            staged_dump=${lib.escapeShellArg stagedDatabaseDump}
            pg_host=${lib.escapeShellArg config.services.immich.database.host}
            pg_user=${lib.escapeShellArg config.services.immich.database.user}
            pg_database=${lib.escapeShellArg config.services.immich.database.name}

            rm -rf "$backup_dir"
            mkdir -p "$staged_media_dir" "$(dirname "$staged_dump")"
            chown -R immich:immich "$backup_dir"

            if [[ -d "$media_dir" ]]; then
              rsync -a --delete "$media_dir"/ "$staged_media_dir"/
            fi

            runuser -u immich -- env \
              PGHOST="$pg_host" \
              PGUSER="$pg_user" \
              PGDATABASE="$pg_database" \
              pg_dump \
                --format=custom \
                --file="$staged_dump" \
                "$pg_database"

            chown -R immich:immich "$backup_dir"
            chgrp -R "$backup_group" "$backup_dir"
            chmod -R u=rwX,g=rX,o= "$backup_dir"
          ''
        else
          null;

      nextcloudBackupPrepScript =
        if nextcloudCluster then
          let
            stagedDatabaseDump = "${nextcloudCfg.backupDir}/database/nextcloud.pgcustom";
          in
          pkgs.writeShellScript "alanix-nextcloud-cluster-backup-runtime" ''
            set -euo pipefail

            backup_dir=${lib.escapeShellArg nextcloudCfg.backupDir}
            backup_group=${lib.escapeShellArg backupRepoUserGroup}
            staged_dump=${lib.escapeShellArg stagedDatabaseDump}
            pg_host=${lib.escapeShellArg config.services.nextcloud.config.dbhost}
            pg_database=${lib.escapeShellArg config.services.nextcloud.config.dbname}

            stage_dir() {
              local source_dir="$1"
              local staged_dir="$backup_dir$source_dir"

              mkdir -p "$staged_dir"

              if [[ -d "$source_dir" ]]; then
                rsync -a --delete "$source_dir"/ "$staged_dir"/
              fi
            }

            rm -rf "$backup_dir"
            mkdir -p "$backup_dir" "$(dirname "$staged_dump")"
            chown -R nextcloud:nextcloud "$backup_dir"

            ${lib.concatMapStringsSep "\n" (path: ''
              stage_dir ${lib.escapeShellArg path}
            '') nextcloudClusteredPaths}

            runuser -u postgres -- env \
              PGHOST="$pg_host" \
              pg_dump \
                --format=custom \
                "$pg_database" > "$staged_dump"

            chown -R nextcloud:nextcloud "$backup_dir"
            chgrp -R "$backup_group" "$backup_dir"
            chmod -R u=rwX,g=rX,o= "$backup_dir"
          ''
        else
          null;

      filebrowserBackupPrepScript =
        if filebrowserCluster then
          let
            stagedDatabasePath = "${filebrowserCfg.backupDir}${filebrowserCfg.database}";
          in
          pkgs.writeShellScript "alanix-filebrowser-cluster-backup-runtime" ''
            set -euo pipefail

            backup_dir=${lib.escapeShellArg filebrowserCfg.backupDir}
            backup_group=${lib.escapeShellArg backupRepoUserGroup}
            db_path=${lib.escapeShellArg filebrowserCfg.database}
            staged_db_path=${lib.escapeShellArg stagedDatabasePath}

            rm -rf "$backup_dir"
            mkdir -p "$(dirname "$staged_db_path")"

            if [[ -f "$db_path" ]]; then
              cp -a "$db_path" "$staged_db_path"
            fi

            chown -R filebrowser:filebrowser "$backup_dir"
            chgrp -R "$backup_group" "$backup_dir"
            chmod -R u=rwX,g=rX,o= "$backup_dir"
          ''
        else
          null;

      radicaleBackupPrepScript =
        if radicaleCluster then
          let
            stagedStorageDir = "${radicaleCfg.backupDir}${radicaleCfg.storageDir}";
          in
          pkgs.writeShellScript "alanix-radicale-cluster-backup-runtime" ''
            set -euo pipefail

            backup_dir=${lib.escapeShellArg radicaleCfg.backupDir}
            backup_group=${lib.escapeShellArg backupRepoUserGroup}
            storage_dir=${lib.escapeShellArg radicaleCfg.storageDir}
            staged_storage_dir=${lib.escapeShellArg stagedStorageDir}

            rm -rf "$backup_dir"
            mkdir -p "$staged_storage_dir"

            if [[ -d "$storage_dir" ]]; then
              rsync -a --delete "$storage_dir"/ "$staged_storage_dir"/
            fi

            chown -R radicale:radicale "$backup_dir"
            chgrp -R "$backup_group" "$backup_dir"
            chmod -R u=rwX,g=rX,o= "$backup_dir"
          ''
        else
          null;

      jellyfinBackupPrepScript =
        if jellyfinCluster then
          pkgs.writeShellScript "alanix-jellyfin-cluster-backup-runtime" ''
            set -euo pipefail

            backup_dir=${lib.escapeShellArg jellyfinCfg.backupDir}
            backup_group=${lib.escapeShellArg backupRepoUserGroup}
            data_dir=${lib.escapeShellArg jellyfinCfg.dataDir}

            stage_dir() {
              local source_dir="$1"
              local staged_dir="$backup_dir$source_dir"

              mkdir -p "$staged_dir"

              if [[ -d "$source_dir" ]]; then
                rsync -a --delete "$source_dir"/ "$staged_dir"/
              fi
            }

            rm -rf "$backup_dir"
            mkdir -p "$backup_dir"

            ${lib.concatMapStringsSep "\n" (path: ''
              stage_dir ${lib.escapeShellArg path}
            '') jellyfinClusteredPaths}

            shopt -s globstar nullglob
            for db_path in "$data_dir"/**/*.db "$data_dir"/*.db; do
              [[ -f "$db_path" ]] || continue
              staged_db="$backup_dir$db_path"
              mkdir -p "$(dirname "$staged_db")"
              sqlite3 "$db_path" ".backup '$staged_db'"
            done
            shopt -u globstar nullglob

            chgrp -R "$backup_group" "$backup_dir"
            chmod -R u=rwX,g=rX,o= "$backup_dir"
          ''
        else
          null;

      openwebuiBackupPrepScript =
        if openwebuiCluster then
          let
            defaultDatabaseUrl = "sqlite:///${openwebuiCfg.stateDir}/data/webui.db";
            stagedStateDir = "${openwebuiCfg.backupDir}${openwebuiCfg.stateDir}";
            environmentFile =
              if openwebuiCfg.environmentFile != null then openwebuiCfg.environmentFile else "";
          in
          pkgs.writeShellScript "alanix-openwebui-cluster-backup-runtime" ''
            set -euo pipefail

            backup_dir=${lib.escapeShellArg openwebuiCfg.backupDir}
            backup_group=${lib.escapeShellArg backupRepoUserGroup}
            state_dir=${lib.escapeShellArg openwebuiCfg.stateDir}
            staged_state_dir=${lib.escapeShellArg stagedStateDir}
            environment_file=${lib.escapeShellArg environmentFile}
            default_database_url=${lib.escapeShellArg defaultDatabaseUrl}

            database_url="$default_database_url"
            if [[ -n "$environment_file" && -f "$environment_file" ]]; then
              set -a
              source "$environment_file"
              set +a
              if [[ -n "''${DATABASE_URL:-}" ]]; then
                database_url="$DATABASE_URL"
              fi
            fi

            case "$database_url" in
              sqlite:///*)
                db_path="''${database_url#sqlite:///}"
                ;;
              *)
                echo "Open WebUI cluster mode currently requires a local sqlite DATABASE_URL." >&2
                exit 1
                ;;
            esac

            case "$db_path" in
              "$state_dir"/*)
                ;;
              *)
                echo "Open WebUI cluster mode currently requires the sqlite database to live under $state_dir." >&2
                exit 1
                ;;
            esac

            staged_db_path="$staged_state_dir''${db_path#"$state_dir"}"

            rm -rf "$backup_dir"
            mkdir -p "$staged_state_dir" "$(dirname "$staged_db_path")"
            chown -R open-webui:open-webui "$backup_dir"

            if [[ -d "$state_dir" ]]; then
              rsync -a --delete "$state_dir"/ "$staged_state_dir"/
            fi

            if [[ -f "$db_path" ]]; then
              sqlite3 "$db_path" ".backup '$staged_db_path'"
            fi

            chown -R open-webui:open-webui "$backup_dir"
            chgrp -R "$backup_group" "$backup_dir"
            chmod -R u=rwX,g=rX,o= "$backup_dir"
          ''
        else
          null;

      searxngBackupPrepScript =
        if searxngCluster then
          let
            stagedStateDir = "${searxngCfg.backupDir}${searxngCfg.stateDir}";
          in
          pkgs.writeShellScript "alanix-searxng-cluster-backup-runtime" ''
            set -euo pipefail

            backup_dir=${lib.escapeShellArg searxngCfg.backupDir}
            backup_group=${lib.escapeShellArg backupRepoUserGroup}
            state_dir=${lib.escapeShellArg searxngCfg.stateDir}
            staged_state_dir=${lib.escapeShellArg stagedStateDir}

            rm -rf "$backup_dir"
            mkdir -p "$staged_state_dir"
            chown -R searx:searx "$backup_dir"

            if [[ -d "$state_dir" ]]; then
              rsync -a --delete "$state_dir"/ "$staged_state_dir"/
            fi

            chown -R searx:searx "$backup_dir"
            chgrp -R "$backup_group" "$backup_dir"
            chmod -R u=rwX,g=rX,o= "$backup_dir"
          ''
        else
          null;

      nextcloudWireguardAddress =
        if nextcloudCfg.expose.wireguard.address != null then
          nextcloudCfg.expose.wireguard.address
        else
          config.alanix.wireguard.vpnIP;

      nextcloudTailscaleTlsName =
        if nextcloudCfg.expose.tailscale.tlsName != null then
          nextcloudCfg.expose.tailscale.tlsName
        else
          config.alanix.tailscale.address;

      nextcloudTorTargetAddress =
        normalizeLocalAddress (
          if nextcloudCfg.expose.tor.targetAddress != null then
            nextcloudCfg.expose.tor.targetAddress
          else
            nextcloudCfg.listenAddress
        );

      nextcloudTorTargetPort =
        if nextcloudCfg.expose.tor.tls then
          nextcloudCfg.expose.tor.publicPort
        else
          nextcloudCfg.port;

      nextcloudTorSecretPath =
        if nextcloudCfg.expose.tor.secretKeyBase64Secret != null then
          config.sops.secrets.${nextcloudCfg.expose.tor.secretKeyBase64Secret}.path
        else
          null;

      nextcloudCollaboraWireguardAddress =
        if nextcloudCollaboraCfg.expose.wireguard.address != null then
          nextcloudCollaboraCfg.expose.wireguard.address
        else
          config.alanix.wireguard.vpnIP;

      nextcloudCollaboraTailscaleTlsName =
        if nextcloudCollaboraCfg.expose.tailscale.tlsName != null then
          nextcloudCollaboraCfg.expose.tailscale.tlsName
        else
          config.alanix.tailscale.address;

      nextcloudCollaboraTorTargetAddress =
        normalizeLocalAddress (
          if nextcloudCollaboraCfg.expose.tor.targetAddress != null then
            nextcloudCollaboraCfg.expose.tor.targetAddress
          else
            "127.0.0.1"
        );

      nextcloudCollaboraTorTargetPort =
        if nextcloudCollaboraCfg.expose.tor.tls then
          nextcloudCollaboraCfg.expose.tor.publicPort
        else
          nextcloudCollaboraCfg.port;

      nextcloudCollaboraTorSecretPath =
        if nextcloudCollaboraCfg.expose.tor.secretKeyBase64Secret != null then
          config.sops.secrets.${nextcloudCollaboraCfg.expose.tor.secretKeyBase64Secret}.path
        else
          null;

      filebrowserWireguardAddress =
        if filebrowserCfg.expose.wireguard.address != null then
          filebrowserCfg.expose.wireguard.address
        else
          config.alanix.wireguard.vpnIP;

      filebrowserTailscaleTlsName =
        if filebrowserCfg.expose.tailscale.tlsName != null then
          filebrowserCfg.expose.tailscale.tlsName
        else
          config.alanix.tailscale.address;

      filebrowserTorTargetAddress =
        normalizeLocalAddress (
          if filebrowserCfg.expose.tor.targetAddress != null then
            filebrowserCfg.expose.tor.targetAddress
          else
            filebrowserCfg.listenAddress
        );

      filebrowserTorTargetPort =
        if filebrowserCfg.expose.tor.tls then
          filebrowserCfg.expose.tor.publicPort
        else
          filebrowserCfg.port;

      filebrowserTorSecretPath =
        if filebrowserCfg.expose.tor.secretKeyBase64Secret != null then
          config.sops.secrets.${filebrowserCfg.expose.tor.secretKeyBase64Secret}.path
        else
          null;

      radicaleWireguardAddress =
        if radicaleCfg.expose.wireguard.address != null then
          radicaleCfg.expose.wireguard.address
        else
          config.alanix.wireguard.vpnIP;

      radicaleTailscaleTlsName =
        if radicaleCfg.expose.tailscale.tlsName != null then
          radicaleCfg.expose.tailscale.tlsName
        else
          config.alanix.tailscale.address;

      radicaleTorTargetAddress =
        normalizeLocalAddress (
          if radicaleCfg.expose.tor.targetAddress != null then
            radicaleCfg.expose.tor.targetAddress
          else
            radicaleCfg.listenAddress
        );

      radicaleTorTargetPort =
        if radicaleCfg.expose.tor.tls then
          radicaleCfg.expose.tor.publicPort
        else
          radicaleCfg.port;

      radicaleTorSecretPath =
        if radicaleCfg.expose.tor.secretKeyBase64Secret != null then
          config.sops.secrets.${radicaleCfg.expose.tor.secretKeyBase64Secret}.path
        else
          null;

      vaultwardenWireguardAddress =
        if vaultwardenCfg.expose.wireguard.address != null then
          vaultwardenCfg.expose.wireguard.address
        else
          config.alanix.wireguard.vpnIP;

      vaultwardenTailscaleTlsName =
        if vaultwardenCfg.expose.tailscale.tlsName != null then
          vaultwardenCfg.expose.tailscale.tlsName
        else
          config.alanix.tailscale.address;

      vaultwardenTorTargetAddress =
        normalizeLocalAddress (
          if vaultwardenCfg.expose.tor.targetAddress != null then
            vaultwardenCfg.expose.tor.targetAddress
          else
            vaultwardenCfg.listenAddress
        );

      vaultwardenTorTargetPort =
        if vaultwardenCfg.expose.tor.tls then
          vaultwardenCfg.expose.tor.publicPort
        else
          vaultwardenCfg.port;

      vaultwardenTorSecretPath =
        if vaultwardenCfg.expose.tor.secretKeyBase64Secret != null then
          config.sops.secrets.${vaultwardenCfg.expose.tor.secretKeyBase64Secret}.path
        else
          null;

      forgejoWireguardAddress =
        if forgejoCfg.expose.wireguard.address != null then
          forgejoCfg.expose.wireguard.address
        else
          config.alanix.wireguard.vpnIP;

      forgejoTailscaleTlsName =
        if forgejoCfg.expose.tailscale.tlsName != null then
          forgejoCfg.expose.tailscale.tlsName
        else
          config.alanix.tailscale.address;

      forgejoTorTargetAddress =
        normalizeLocalAddress (
          if forgejoCfg.expose.tor.targetAddress != null then
            forgejoCfg.expose.tor.targetAddress
          else
            forgejoCfg.listenAddress
        );

      forgejoTorTargetPort =
        if forgejoCfg.expose.tor.tls then
          forgejoCfg.expose.tor.publicPort
        else
          forgejoCfg.port;

      forgejoTorSecretPath =
        if forgejoCfg.expose.tor.secretKeyBase64Secret != null then
          config.sops.secrets.${forgejoCfg.expose.tor.secretKeyBase64Secret}.path
        else
          null;

      invidiousWireguardAddress =
        if invidiousCfg.expose.wireguard.address != null then
          invidiousCfg.expose.wireguard.address
        else
          config.alanix.wireguard.vpnIP;

      invidiousTailscaleTlsName =
        if invidiousCfg.expose.tailscale.tlsName != null then
          invidiousCfg.expose.tailscale.tlsName
        else
          config.alanix.tailscale.address;

      invidiousTorTargetAddress =
        normalizeLocalAddress (
          if invidiousCfg.expose.tor.targetAddress != null then
            invidiousCfg.expose.tor.targetAddress
          else
            invidiousCfg.listenAddress
        );

      invidiousTorTargetPort =
        if invidiousCfg.expose.tor.tls then
          invidiousCfg.expose.tor.publicPort
        else
          invidiousCfg.port;

      invidiousTorSecretPath =
        if invidiousCfg.expose.tor.secretKeyBase64Secret != null then
          config.sops.secrets.${invidiousCfg.expose.tor.secretKeyBase64Secret}.path
        else
          null;

      immichWireguardAddress =
        if immichCfg.expose.wireguard.address != null then
          immichCfg.expose.wireguard.address
        else
          config.alanix.wireguard.vpnIP;

      immichTailscaleTlsName =
        if immichCfg.expose.tailscale.tlsName != null then
          immichCfg.expose.tailscale.tlsName
        else
          config.alanix.tailscale.address;

      immichTorTargetAddress =
        normalizeLocalAddress (
          if immichCfg.expose.tor.targetAddress != null then
            immichCfg.expose.tor.targetAddress
          else
            immichCfg.listenAddress
        );

      immichTorTargetPort =
        if immichCfg.expose.tor.tls then
          immichCfg.expose.tor.publicPort
        else
          immichCfg.port;

      immichTorSecretPath =
        if immichCfg.expose.tor.secretKeyBase64Secret != null then
          config.sops.secrets.${immichCfg.expose.tor.secretKeyBase64Secret}.path
        else
          null;

      jellyfinWireguardAddress =
        if jellyfinCfg.expose.wireguard.address != null then
          jellyfinCfg.expose.wireguard.address
        else
          config.alanix.wireguard.vpnIP;

      jellyfinTailscaleTlsName =
        if jellyfinCfg.expose.tailscale.tlsName != null then
          jellyfinCfg.expose.tailscale.tlsName
        else
          config.alanix.tailscale.address;

      jellyfinTorTargetAddress =
        normalizeLocalAddress (
          if jellyfinCfg.expose.tor.targetAddress != null then
            jellyfinCfg.expose.tor.targetAddress
          else
            jellyfinCfg.listenAddress
        );

      jellyfinTorTargetPort =
        if jellyfinCfg.expose.tor.tls then
          jellyfinCfg.expose.tor.publicPort
        else
          jellyfinCfg.port;

      jellyfinTorSecretPath =
        if jellyfinCfg.expose.tor.secretKeyBase64Secret != null then
          config.sops.secrets.${jellyfinCfg.expose.tor.secretKeyBase64Secret}.path
        else
          null;

      openwebuiWireguardAddress =
        if openwebuiCfg.expose.wireguard.address != null then
          openwebuiCfg.expose.wireguard.address
        else
          config.alanix.wireguard.vpnIP;

      openwebuiTailscaleTlsName =
        if openwebuiCfg.expose.tailscale.tlsName != null then
          openwebuiCfg.expose.tailscale.tlsName
        else
          config.alanix.tailscale.address;

      openwebuiTorTargetAddress =
        normalizeLocalAddress (
          if openwebuiCfg.expose.tor.targetAddress != null then
            openwebuiCfg.expose.tor.targetAddress
          else
            openwebuiCfg.listenAddress
        );

      openwebuiTorTargetPort =
        if openwebuiCfg.expose.tor.tls then
          openwebuiCfg.expose.tor.publicPort
        else
          openwebuiCfg.port;

      openwebuiTorSecretPath =
        if openwebuiCfg.expose.tor.secretKeyBase64Secret != null then
          config.sops.secrets.${openwebuiCfg.expose.tor.secretKeyBase64Secret}.path
        else
          null;

      searxngWireguardAddress =
        if searxngCfg.expose.wireguard.address != null then
          searxngCfg.expose.wireguard.address
        else
          config.alanix.wireguard.vpnIP;

      searxngTailscaleTlsName =
        if searxngCfg.expose.tailscale.tlsName != null then
          searxngCfg.expose.tailscale.tlsName
        else
          config.alanix.tailscale.address;

      searxngTorTargetAddress =
        normalizeLocalAddress (
          if searxngCfg.expose.tor.targetAddress != null then
            searxngCfg.expose.tor.targetAddress
          else
            searxngCfg.listenAddress
        );

      searxngTorTargetPort =
        if searxngCfg.expose.tor.tls then
          searxngCfg.expose.tor.publicPort
        else
          searxngCfg.port;

      searxngTorSecretPath =
        if searxngCfg.expose.tor.secretKeyBase64Secret != null then
          config.sops.secrets.${searxngCfg.expose.tor.secretKeyBase64Secret}.path
        else
          null;

      anyCaddyExposure =
        (
          nextcloudCluster
          && (
            nextcloudCfg.expose.tailscale.enable
            || nextcloudCfg.expose.wireguard.enable
            || (nextcloudCfg.expose.tor.enable && nextcloudCfg.expose.tor.tls)
            || (
              nextcloudCollaboraCfg.enable
              && (
                nextcloudCollaboraCfg.expose.tailscale.enable
                || nextcloudCollaboraCfg.expose.wireguard.enable
                || (nextcloudCollaboraCfg.expose.tor.enable && nextcloudCollaboraCfg.expose.tor.tls)
              )
            )
          )
        )
        || (
          filebrowserCluster
          && (
            filebrowserCfg.expose.tailscale.enable
            || filebrowserCfg.expose.wireguard.enable
            || (filebrowserCfg.expose.tor.enable && filebrowserCfg.expose.tor.tls)
          )
        )
        || (
          radicaleCluster
          && (
            radicaleCfg.expose.tailscale.enable
            || radicaleCfg.expose.wireguard.enable
            || (radicaleCfg.expose.tor.enable && radicaleCfg.expose.tor.tls)
          )
        )
        || (
          vaultwardenCluster
          && (
            vaultwardenCfg.expose.tailscale.enable
            || vaultwardenCfg.expose.wireguard.enable
            || (vaultwardenCfg.expose.tor.enable && vaultwardenCfg.expose.tor.tls)
          )
        )
        || (
          forgejoCluster
          && (
            forgejoCfg.expose.tailscale.enable
            || forgejoCfg.expose.wireguard.enable
            || (forgejoCfg.expose.tor.enable && forgejoCfg.expose.tor.tls)
          )
        )
        || (
          invidiousCluster
          && (
            invidiousCfg.expose.tailscale.enable
            || invidiousCfg.expose.wireguard.enable
            || (invidiousCfg.expose.tor.enable && invidiousCfg.expose.tor.tls)
          )
        )
        || (
          immichCluster
          && (
            immichCfg.expose.tailscale.enable
            || immichCfg.expose.wireguard.enable
            || (immichCfg.expose.tor.enable && immichCfg.expose.tor.tls)
          )
        )
        || (
          jellyfinCluster
          && (
            jellyfinCfg.expose.tailscale.enable
            || jellyfinCfg.expose.wireguard.enable
            || (jellyfinCfg.expose.tor.enable && jellyfinCfg.expose.tor.tls)
          )
        )
        || (
          openwebuiCluster
          && (
            openwebuiCfg.expose.tailscale.enable
            || openwebuiCfg.expose.wireguard.enable
            || (openwebuiCfg.expose.tor.enable && openwebuiCfg.expose.tor.tls)
          )
        )
        || (
          searxngCluster
          && (
            searxngCfg.expose.tailscale.enable
            || searxngCfg.expose.wireguard.enable
            || (searxngCfg.expose.tor.enable && searxngCfg.expose.tor.tls)
          )
        )
        || anyWanExposure;

      anyWanExposure =
        (nextcloudCluster && nextcloudCfg.expose.wan.enable)
        || (nextcloudCluster && nextcloudCollaboraCfg.enable && nextcloudCollaboraCfg.expose.wan.enable)
        || (filebrowserCluster && filebrowserCfg.expose.wan.enable)
        || (radicaleCluster && radicaleCfg.expose.wan.enable)
        || (vaultwardenCluster && vaultwardenCfg.expose.wan.enable)
        || (forgejoCluster && forgejoCfg.expose.wan.enable)
        || (invidiousCluster && invidiousCfg.expose.wan.enable)
        || (immichCluster && immichCfg.expose.wan.enable)
        || (jellyfinCluster && jellyfinCfg.expose.wan.enable)
        || (searxngCluster && searxngCfg.expose.wan.enable);

      anyTailscaleCaddyExposure =
        (nextcloudCluster && nextcloudCfg.expose.tailscale.enable)
        || (nextcloudCluster && nextcloudCollaboraCfg.enable && nextcloudCollaboraCfg.expose.tailscale.enable)
        || (filebrowserCluster && filebrowserCfg.expose.tailscale.enable)
        || (radicaleCluster && radicaleCfg.expose.tailscale.enable)
        || (vaultwardenCluster && vaultwardenCfg.expose.tailscale.enable)
        || (forgejoCluster && forgejoCfg.expose.tailscale.enable)
        || (invidiousCluster && invidiousCfg.expose.tailscale.enable)
        || (immichCluster && immichCfg.expose.tailscale.enable)
        || (jellyfinCluster && jellyfinCfg.expose.tailscale.enable)
        || (openwebuiCluster && openwebuiCfg.expose.tailscale.enable)
        || (searxngCluster && searxngCfg.expose.tailscale.enable);

      anyTorExposure =
        (nextcloudCluster && nextcloudCfg.expose.tor.enable)
        || (nextcloudCluster && nextcloudCollaboraCfg.enable && nextcloudCollaboraCfg.expose.tor.enable)
        || (filebrowserCluster && filebrowserCfg.expose.tor.enable)
        || (radicaleCluster && radicaleCfg.expose.tor.enable)
        || (vaultwardenCluster && vaultwardenCfg.expose.tor.enable)
        || (forgejoCluster && forgejoCfg.expose.tor.enable)
        || (invidiousCluster && invidiousCfg.expose.tor.enable)
        || (immichCluster && immichCfg.expose.tor.enable)
        || (jellyfinCluster && jellyfinCfg.expose.tor.enable)
        || (openwebuiCluster && openwebuiCfg.expose.tor.enable)
        || (searxngCluster && searxngCfg.expose.tor.enable);

      # Build a stable Tor URL from the tor exposure options.
      # Returns null when tor.enable is false or tor.hostname is not set.
      mkTorUrl =
        torCfg:
        let
          scheme = if torCfg.tls then "https" else "http";
          port = torCfg.publicPort;
          defaultPort = if torCfg.tls then 443 else 80;
          portSuffix = if port != defaultPort then ":${toString port}" else "";
        in
        if torCfg.enable && torCfg.hostname != null then
          "${scheme}://${torCfg.hostname}${portSuffix}/"
        else
          null;

      nextcloudLinksByHost = mergeLinksByHost [
        (lib.optionalAttrs (nextcloudCluster && nextcloudCfg.expose.tailscale.enable) (
          mkPeerLinksByHost {
            label = "Nextcloud";
            transport = "tailscale";
            scheme = if nextcloudCfg.expose.tailscale.tls then "https" else "http";
            port = nextcloudCfg.expose.tailscale.port;
            addressFn = peerTailscaleAddress;
          }
        ))
        (lib.optionalAttrs (nextcloudCluster && nextcloudCfg.expose.wireguard.enable) (
          mkPeerLinksByHost {
            label = "Nextcloud";
            transport = "wireguard";
            scheme = if nextcloudCfg.expose.wireguard.tls then "https" else "http";
            port = nextcloudCfg.expose.wireguard.port;
            addressFn = peerWireguardAddress;
          }
        ))
        (lib.optionalAttrs (nextcloudCluster && nextcloudCfg.expose.tor.enable && nextcloudCfg.expose.tor.hostname != null) (
          mkConstantLinksByHost [
            {
              label = "Nextcloud (tor)";
              transport = "tor";
              url = mkTorUrl nextcloudCfg.expose.tor;
            }
          ]
        ))
        (lib.optionalAttrs (nextcloudCluster && nextcloudCollaboraCfg.enable && nextcloudCollaboraCfg.expose.tailscale.enable) (
          mkPeerLinksByHost {
            label = "Collabora";
            transport = "tailscale";
            scheme = if nextcloudCollaboraCfg.expose.tailscale.tls then "https" else "http";
            port = nextcloudCollaboraCfg.expose.tailscale.port;
            addressFn = peerTailscaleAddress;
          }
        ))
        (lib.optionalAttrs (nextcloudCluster && nextcloudCollaboraCfg.enable && nextcloudCollaboraCfg.expose.wireguard.enable) (
          mkPeerLinksByHost {
            label = "Collabora";
            transport = "wireguard";
            scheme = if nextcloudCollaboraCfg.expose.wireguard.tls then "https" else "http";
            port = nextcloudCollaboraCfg.expose.wireguard.port;
            addressFn = peerWireguardAddress;
          }
        ))
        (lib.optionalAttrs (nextcloudCluster && nextcloudCollaboraCfg.enable && nextcloudCollaboraCfg.expose.tor.enable && nextcloudCollaboraCfg.expose.tor.hostname != null) (
          mkConstantLinksByHost [
            {
              label = "Collabora (tor)";
              transport = "tor";
              url = mkTorUrl nextcloudCollaboraCfg.expose.tor;
            }
          ]
        ))
      ];

      filebrowserLinksByHost = mergeLinksByHost [
        (lib.optionalAttrs (filebrowserCluster && filebrowserCfg.expose.tailscale.enable) (
          mkPeerLinksByHost {
            label = "File Browser";
            transport = "tailscale";
            scheme = if filebrowserCfg.expose.tailscale.tls then "https" else "http";
            port = filebrowserCfg.expose.tailscale.port;
            addressFn = peerTailscaleAddress;
          }
        ))
        (lib.optionalAttrs (filebrowserCluster && filebrowserCfg.expose.wireguard.enable) (
          mkPeerLinksByHost {
            label = "File Browser";
            transport = "wireguard";
            scheme = if filebrowserCfg.expose.wireguard.tls then "https" else "http";
            port = filebrowserCfg.expose.wireguard.port;
            addressFn = peerWireguardAddress;
          }
        ))
      ];

      radicaleLinksByHost = mergeLinksByHost [
        (lib.optionalAttrs (radicaleCluster && radicaleCfg.expose.tailscale.enable) (
          mkPeerLinksByHost {
            label = "Radicale";
            transport = "tailscale";
            scheme = if radicaleCfg.expose.tailscale.tls then "https" else "http";
            port = radicaleCfg.expose.tailscale.port;
            addressFn = peerTailscaleAddress;
          }
        ))
        (lib.optionalAttrs (radicaleCluster && radicaleCfg.expose.wireguard.enable) (
          mkPeerLinksByHost {
            label = "Radicale";
            transport = "wireguard";
            scheme = if radicaleCfg.expose.wireguard.tls then "https" else "http";
            port = radicaleCfg.expose.wireguard.port;
            addressFn = peerWireguardAddress;
          }
        ))
      ];

      vaultwardenLinksByHost = mergeLinksByHost [
        (lib.optionalAttrs (vaultwardenCluster && vaultwardenCfg.expose.tailscale.enable) (
          mkPeerLinksByHost {
            label = "Vaultwarden";
            transport = "tailscale";
            scheme = if vaultwardenCfg.expose.tailscale.tls then "https" else "http";
            port = vaultwardenCfg.expose.tailscale.port;
            addressFn = peerTailscaleAddress;
          }
        ))
        (lib.optionalAttrs (vaultwardenCluster && vaultwardenCfg.expose.wireguard.enable) (
          mkPeerLinksByHost {
            label = "Vaultwarden";
            transport = "wireguard";
            scheme = if vaultwardenCfg.expose.wireguard.tls then "https" else "http";
            port = vaultwardenCfg.expose.wireguard.port;
            addressFn = peerWireguardAddress;
          }
        ))
      ];

      forgejoLinksByHost = mergeLinksByHost [
        (lib.optionalAttrs (forgejoCluster && forgejoCfg.expose.tailscale.enable) (
          mkPeerLinksByHost {
            label = "Forgejo";
            transport = "tailscale";
            scheme = if forgejoCfg.expose.tailscale.tls then "https" else "http";
            port = forgejoCfg.expose.tailscale.port;
            addressFn = peerTailscaleAddress;
          }
        ))
        (lib.optionalAttrs (forgejoCluster && forgejoCfg.expose.wireguard.enable) (
          mkPeerLinksByHost {
            label = "Forgejo";
            transport = "wireguard";
            scheme = if forgejoCfg.expose.wireguard.tls then "https" else "http";
            port = forgejoCfg.expose.wireguard.port;
            addressFn = peerWireguardAddress;
          }
        ))
      ];

      invidiousLinksByHost = mergeLinksByHost [
        (lib.optionalAttrs (invidiousCluster && invidiousCfg.expose.tailscale.enable) (
          mkPeerLinksByHost {
            label = "Invidious";
            transport = "tailscale";
            scheme = if invidiousCfg.expose.tailscale.tls then "https" else "http";
            port = invidiousCfg.expose.tailscale.port;
            addressFn = peerTailscaleAddress;
          }
        ))
        (lib.optionalAttrs (invidiousCluster && invidiousCfg.expose.wireguard.enable) (
          mkPeerLinksByHost {
            label = "Invidious";
            transport = "wireguard";
            scheme = if invidiousCfg.expose.wireguard.tls then "https" else "http";
            port = invidiousCfg.expose.wireguard.port;
            addressFn = peerWireguardAddress;
          }
        ))
      ];

      immichLinksByHost = mergeLinksByHost [
        (lib.optionalAttrs (immichCluster && immichCfg.expose.tailscale.enable) (
          mkPeerLinksByHost {
            label = "Immich";
            transport = "tailscale";
            scheme = if immichCfg.expose.tailscale.tls then "https" else "http";
            port = immichCfg.expose.tailscale.port;
            addressFn = peerTailscaleAddress;
          }
        ))
        (lib.optionalAttrs (immichCluster && immichCfg.expose.wireguard.enable) (
          mkPeerLinksByHost {
            label = "Immich";
            transport = "wireguard";
            scheme = if immichCfg.expose.wireguard.tls then "https" else "http";
            port = immichCfg.expose.wireguard.port;
            addressFn = peerWireguardAddress;
          }
        ))
      ];

      jellyfinLinksByHost = mergeLinksByHost [
        (lib.optionalAttrs (jellyfinCluster && jellyfinCfg.expose.tailscale.enable) (
          mkPeerLinksByHost {
            label = "Jellyfin";
            transport = "tailscale";
            scheme = if jellyfinCfg.expose.tailscale.tls then "https" else "http";
            port = jellyfinCfg.expose.tailscale.port;
            addressFn = peerTailscaleAddress;
          }
        ))
        (lib.optionalAttrs (jellyfinCluster && jellyfinCfg.expose.wireguard.enable) (
          mkPeerLinksByHost {
            label = "Jellyfin";
            transport = "wireguard";
            scheme = if jellyfinCfg.expose.wireguard.tls then "https" else "http";
            port = jellyfinCfg.expose.wireguard.port;
            addressFn = peerWireguardAddress;
          }
        ))
      ];

      openwebuiLinksByHost = mergeLinksByHost [
        (lib.optionalAttrs (openwebuiCluster && openwebuiCfg.expose.tailscale.enable) (
          mkPeerLinksByHost {
            label = "Open WebUI";
            transport = "tailscale";
            scheme = if openwebuiCfg.expose.tailscale.tls then "https" else "http";
            port = openwebuiCfg.expose.tailscale.port;
            addressFn = peerTailscaleAddress;
          }
        ))
        (lib.optionalAttrs (openwebuiCluster && openwebuiCfg.expose.wireguard.enable) (
          mkPeerLinksByHost {
            label = "Open WebUI";
            transport = "wireguard";
            scheme = if openwebuiCfg.expose.wireguard.tls then "https" else "http";
            port = openwebuiCfg.expose.wireguard.port;
            addressFn = peerWireguardAddress;
          }
        ))
      ];

      searxngLinksByHost = mergeLinksByHost [
        (lib.optionalAttrs (searxngCluster && searxngCfg.expose.tailscale.enable) (
          mkPeerLinksByHost {
            label = "SearXNG";
            transport = "tailscale";
            scheme = if searxngCfg.expose.tailscale.tls then "https" else "http";
            port = searxngCfg.expose.tailscale.port;
            addressFn = peerTailscaleAddress;
          }
        ))
        (lib.optionalAttrs (searxngCluster && searxngCfg.expose.wireguard.enable) (
          mkPeerLinksByHost {
            label = "SearXNG";
            transport = "wireguard";
            scheme = if searxngCfg.expose.wireguard.tls then "https" else "http";
            port = searxngCfg.expose.wireguard.port;
            addressFn = peerWireguardAddress;
          }
        ))
      ];

      controllerConfig = {
        cluster = {
          name = cfg.name;
          transport = cfg.transport;
          leaderKey = "/alanix/clusters/${cfg.name}/leader";
          hostname = hostname;
          priority = cfg.priority;
          bootstrapHost = lib.head cfg.priority;
          activeTarget = "alanix-cluster-active.target";
          etcd = {
            leaseTtl = cfg.etcd.leaseTtl;
            renewEvery = cfg.etcd.renewEvery;
            acquisitionStep = cfg.etcd.acquisitionStep;
          };
          backup = {
            repoUser = cfg.backup.repoUser;
            repoBaseDir = cfg.backup.repoBaseDir;
            passwordFile = config.sops.secrets.${cfg.backup.passwordSecret}.path;
          };
          endpoints =
            map
              (peer:
                if peer == hostname then
                  "http://127.0.0.1:2379"
                else
                  "http://${hostTransportAddress peer}:2379")
              cfg.voters;
        };
        dashboard = {
          listenAddress = dashboardCfg.listenAddress;
          port = dashboardCfg.port;
          recentEvents = dashboardCfg.recentEvents;
          links = dashboardLinks;
        };
        services =
          (lib.optionalAttrs nextcloudCluster {
            nextcloud = {
              name = "nextcloud";
              backupInterval = nextcloudCfg.cluster.backupInterval;
              maxBackupAge = nextcloudCfg.cluster.maxBackupAge;
              activeUnits =
                [
                  "phpfpm-nextcloud.service"
                  "nextcloud-cron.timer"
                ]
                ++ lib.optionals nextcloudCollaboraCfg.enable [ "coolwsd.service" ]
                ++ lib.optionals (anyCaddyExposure || anyTorExposure) [ "alanix-cluster-exposure.service" ];
              backupPaths = [ nextcloudCfg.backupDir ];
              preBackupCommand = [ nextcloudBackupPrepScript ];
              postRestoreCommand = [ nextcloudRestoreScript ];
              remoteTargets =
                map
                  (peer: {
                    host = peer;
                    address = hostTransportAddress peer;
                    repoPath = "${cfg.backup.repoBaseDir}/${cfg.name}/nextcloud/from-${hostname}/repo";
                    manifestPath = "${cfg.backup.repoBaseDir}/${cfg.name}/nextcloud/from-${hostname}/manifest.json";
                  })
                  (lib.filter (peer: peer != hostname) cfg.members);
              localRepoGlob = "${cfg.backup.repoBaseDir}/${cfg.name}/nextcloud/from-*/repo";
              localManifestGlob = "${cfg.backup.repoBaseDir}/${cfg.name}/nextcloud/from-*/manifest.json";
              linksByHost = nextcloudLinksByHost;
              torUrl = mkTorUrl nextcloudCfg.expose.tor;
              tor = {
                enabled = nextcloudCfg.expose.tor.enable;
                tls = nextcloudCfg.expose.tor.tls;
                publicPort = nextcloudCfg.expose.tor.publicPort;
                stateDirName = "nextcloud";
              };
            };
          })
          // (lib.optionalAttrs filebrowserCluster {
            filebrowser = {
              name = "filebrowser";
              label = "File Browser";
              backupInterval = filebrowserCfg.cluster.backupInterval;
              maxBackupAge = filebrowserCfg.cluster.maxBackupAge;
              activeUnits =
                [ "filebrowser.service" ]
                ++ lib.optionals (anyCaddyExposure || anyTorExposure) [ "alanix-cluster-exposure.service" ];
              backupPaths = [ filebrowserCfg.backupDir ];
              preBackupCommand = [ filebrowserBackupPrepScript ];
              postRestoreCommand = [ filebrowserRestoreScript ];
              remoteTargets =
                map
                  (peer: {
                    host = peer;
                    address = hostTransportAddress peer;
                    repoPath = "${cfg.backup.repoBaseDir}/${cfg.name}/filebrowser/from-${hostname}/repo";
                    manifestPath = "${cfg.backup.repoBaseDir}/${cfg.name}/filebrowser/from-${hostname}/manifest.json";
                  })
                  (lib.filter (peer: peer != hostname) cfg.members);
              localRepoGlob = "${cfg.backup.repoBaseDir}/${cfg.name}/filebrowser/from-*/repo";
              localManifestGlob = "${cfg.backup.repoBaseDir}/${cfg.name}/filebrowser/from-*/manifest.json";
              linksByHost = filebrowserLinksByHost;
              torUrl = mkTorUrl filebrowserCfg.expose.tor;
              tor = {
                enabled = filebrowserCfg.expose.tor.enable;
                tls = filebrowserCfg.expose.tor.tls;
                publicPort = filebrowserCfg.expose.tor.publicPort;
                stateDirName = "filebrowser";
              };
            };
          })
          // (lib.optionalAttrs radicaleCluster {
            radicale = {
              name = "radicale";
              label = "Radicale";
              backupInterval = radicaleCfg.cluster.backupInterval;
              maxBackupAge = radicaleCfg.cluster.maxBackupAge;
              activeUnits =
                [ "radicale.service" ]
                ++ lib.optionals (anyCaddyExposure || anyTorExposure) [ "alanix-cluster-exposure.service" ];
              backupPaths = [ radicaleCfg.backupDir ];
              preBackupCommand = [ radicaleBackupPrepScript ];
              postRestoreCommand = [ radicaleRestoreScript ];
              remoteTargets =
                map
                  (peer: {
                    host = peer;
                    address = hostTransportAddress peer;
                    repoPath = "${cfg.backup.repoBaseDir}/${cfg.name}/radicale/from-${hostname}/repo";
                    manifestPath = "${cfg.backup.repoBaseDir}/${cfg.name}/radicale/from-${hostname}/manifest.json";
                  })
                  (lib.filter (peer: peer != hostname) cfg.members);
              localRepoGlob = "${cfg.backup.repoBaseDir}/${cfg.name}/radicale/from-*/repo";
              localManifestGlob = "${cfg.backup.repoBaseDir}/${cfg.name}/radicale/from-*/manifest.json";
              linksByHost = radicaleLinksByHost;
              torUrl = mkTorUrl radicaleCfg.expose.tor;
              tor = {
                enabled = radicaleCfg.expose.tor.enable;
                tls = radicaleCfg.expose.tor.tls;
                publicPort = radicaleCfg.expose.tor.publicPort;
                stateDirName = "radicale";
              };
            };
          })
          // 
          (lib.optionalAttrs vaultwardenCluster {
            vaultwarden = {
              name = "vaultwarden";
              backupInterval = vaultwardenCfg.cluster.backupInterval;
              maxBackupAge = vaultwardenCfg.cluster.maxBackupAge;
              activeUnits =
                [ "vaultwarden.service" ]
                ++ lib.optionals (anyCaddyExposure || anyTorExposure) [ "alanix-cluster-exposure.service" ];
              backupPaths = [ vaultwardenCfg.backupDir ];
              preBackupCommand = [ vaultwardenBackupPrepScript ];
              postRestoreCommand = [ vaultwardenRestoreScript ];
              remoteTargets =
                map
                  (peer: {
                    host = peer;
                    address = hostTransportAddress peer;
                    repoPath = "${cfg.backup.repoBaseDir}/${cfg.name}/vaultwarden/from-${hostname}/repo";
                    manifestPath = "${cfg.backup.repoBaseDir}/${cfg.name}/vaultwarden/from-${hostname}/manifest.json";
                  })
                  (lib.filter (peer: peer != hostname) cfg.members);
              localRepoGlob = "${cfg.backup.repoBaseDir}/${cfg.name}/vaultwarden/from-*/repo";
              localManifestGlob = "${cfg.backup.repoBaseDir}/${cfg.name}/vaultwarden/from-*/manifest.json";
              linksByHost = vaultwardenLinksByHost;
              torUrl = mkTorUrl vaultwardenCfg.expose.tor;
              tor = {
                enabled = vaultwardenCfg.expose.tor.enable;
                tls = vaultwardenCfg.expose.tor.tls;
                publicPort = vaultwardenCfg.expose.tor.publicPort;
                stateDirName = "vaultwarden";
              };
            };
          })
          // (lib.optionalAttrs forgejoCluster {
            forgejo = {
              name = "forgejo";
              backupInterval = forgejoCfg.cluster.backupInterval;
              maxBackupAge = forgejoCfg.cluster.maxBackupAge;
              activeUnits =
                [ "forgejo.service" ]
                ++ lib.optionals (anyCaddyExposure || anyTorExposure) [ "alanix-cluster-exposure.service" ];
              backupPaths = [ forgejoCfg.backupDir ];
              preBackupCommand = [ forgejoBackupPrepScript ];
              postRestoreCommand = [ forgejoRestoreScript ];
              remoteTargets =
                map
                  (peer: {
                    host = peer;
                    address = hostTransportAddress peer;
                    repoPath = "${cfg.backup.repoBaseDir}/${cfg.name}/forgejo/from-${hostname}/repo";
                    manifestPath = "${cfg.backup.repoBaseDir}/${cfg.name}/forgejo/from-${hostname}/manifest.json";
                  })
                  (lib.filter (peer: peer != hostname) cfg.members);
              localRepoGlob = "${cfg.backup.repoBaseDir}/${cfg.name}/forgejo/from-*/repo";
              localManifestGlob = "${cfg.backup.repoBaseDir}/${cfg.name}/forgejo/from-*/manifest.json";
              linksByHost = forgejoLinksByHost;
              torUrl = mkTorUrl forgejoCfg.expose.tor;
              tor = {
                enabled = forgejoCfg.expose.tor.enable;
                tls = forgejoCfg.expose.tor.tls;
                publicPort = forgejoCfg.expose.tor.publicPort;
                stateDirName = "forgejo";
              };
            };
          })
          // (lib.optionalAttrs invidiousCluster {
            invidious = {
              name = "invidious";
              backupInterval = invidiousCfg.cluster.backupInterval;
              maxBackupAge = invidiousCfg.cluster.maxBackupAge;
              activeUnits =
                [ "invidious.service" ]
                ++ lib.optionals invidiousCfg.companion.enable [ "invidious-companion.service" ]
                ++ lib.optionals (anyCaddyExposure || anyTorExposure) [ "alanix-cluster-exposure.service" ];
              backupPaths = [ invidiousCfg.backupDir ];
              preBackupCommand = [ invidiousBackupPrepScript ];
              postRestoreCommand = [ invidiousRestoreScript ];
              remoteTargets =
                map
                  (peer: {
                    host = peer;
                    address = hostTransportAddress peer;
                    repoPath = "${cfg.backup.repoBaseDir}/${cfg.name}/invidious/from-${hostname}/repo";
                    manifestPath = "${cfg.backup.repoBaseDir}/${cfg.name}/invidious/from-${hostname}/manifest.json";
                  })
                  (lib.filter (peer: peer != hostname) cfg.members);
              localRepoGlob = "${cfg.backup.repoBaseDir}/${cfg.name}/invidious/from-*/repo";
              localManifestGlob = "${cfg.backup.repoBaseDir}/${cfg.name}/invidious/from-*/manifest.json";
              linksByHost = invidiousLinksByHost;
              torUrl = mkTorUrl invidiousCfg.expose.tor;
              tor = {
                enabled = invidiousCfg.expose.tor.enable;
                tls = invidiousCfg.expose.tor.tls;
                publicPort = invidiousCfg.expose.tor.publicPort;
                stateDirName = "invidious";
              };
            };
          })
          // (lib.optionalAttrs immichCluster {
            immich = {
              name = "immich";
              backupInterval = immichCfg.cluster.backupInterval;
              maxBackupAge = immichCfg.cluster.maxBackupAge;
              activeUnits =
                [ "immich-server.service" ]
                ++ lib.optionals immichCfg.machineLearning.enable [ "immich-machine-learning.service" ]
                ++ lib.optionals (anyCaddyExposure || anyTorExposure) [ "alanix-cluster-exposure.service" ];
              backupPaths = [ immichCfg.backupDir ];
              preBackupCommand = [ immichBackupPrepScript ];
              postRestoreCommand = [ immichRestoreScript ];
              remoteTargets =
                map
                  (peer: {
                    host = peer;
                    address = hostTransportAddress peer;
                    repoPath = "${cfg.backup.repoBaseDir}/${cfg.name}/immich/from-${hostname}/repo";
                    manifestPath = "${cfg.backup.repoBaseDir}/${cfg.name}/immich/from-${hostname}/manifest.json";
                  })
                  (lib.filter (peer: peer != hostname) cfg.members);
              localRepoGlob = "${cfg.backup.repoBaseDir}/${cfg.name}/immich/from-*/repo";
              localManifestGlob = "${cfg.backup.repoBaseDir}/${cfg.name}/immich/from-*/manifest.json";
              linksByHost = immichLinksByHost;
              torUrl = mkTorUrl immichCfg.expose.tor;
              tor = {
                enabled = immichCfg.expose.tor.enable;
                tls = immichCfg.expose.tor.tls;
                publicPort = immichCfg.expose.tor.publicPort;
                stateDirName = "immich";
              };
            };
          })
          // (lib.optionalAttrs jellyfinCluster {
            jellyfin = {
              name = "jellyfin";
              backupInterval = jellyfinCfg.cluster.backupInterval;
              maxBackupAge = jellyfinCfg.cluster.maxBackupAge;
              activeUnits =
                [ "jellyfin.service" ]
                ++ lib.optionals (anyCaddyExposure || anyTorExposure) [ "alanix-cluster-exposure.service" ];
              backupPaths = [ jellyfinCfg.backupDir ];
              preBackupCommand = [ jellyfinBackupPrepScript ];
              postRestoreCommand = [ jellyfinRestoreScript ];
              remoteTargets =
                map
                  (peer: {
                    host = peer;
                    address = hostTransportAddress peer;
                    repoPath = "${cfg.backup.repoBaseDir}/${cfg.name}/jellyfin/from-${hostname}/repo";
                    manifestPath = "${cfg.backup.repoBaseDir}/${cfg.name}/jellyfin/from-${hostname}/manifest.json";
                  })
                  (lib.filter (peer: peer != hostname) cfg.members);
              localRepoGlob = "${cfg.backup.repoBaseDir}/${cfg.name}/jellyfin/from-*/repo";
              localManifestGlob = "${cfg.backup.repoBaseDir}/${cfg.name}/jellyfin/from-*/manifest.json";
              linksByHost = jellyfinLinksByHost;
              torUrl = mkTorUrl jellyfinCfg.expose.tor;
              tor = {
                enabled = jellyfinCfg.expose.tor.enable;
                tls = jellyfinCfg.expose.tor.tls;
                publicPort = jellyfinCfg.expose.tor.publicPort;
                stateDirName = "jellyfin";
              };
            };
          })
          // (lib.optionalAttrs openwebuiCluster {
            openwebui = {
              name = "openwebui";
              backupInterval = openwebuiCfg.cluster.backupInterval;
              maxBackupAge = openwebuiCfg.cluster.maxBackupAge;
              activeUnits =
                [ "open-webui.service" ]
                ++ lib.optionals (anyCaddyExposure || anyTorExposure) [ "alanix-cluster-exposure.service" ];
              backupPaths = [ openwebuiCfg.backupDir ];
              preBackupCommand = [ openwebuiBackupPrepScript ];
              postRestoreCommand = [ openwebuiRestoreScript ];
              remoteTargets =
                map
                  (peer: {
                    host = peer;
                    address = hostTransportAddress peer;
                    repoPath = "${cfg.backup.repoBaseDir}/${cfg.name}/openwebui/from-${hostname}/repo";
                    manifestPath = "${cfg.backup.repoBaseDir}/${cfg.name}/openwebui/from-${hostname}/manifest.json";
                  })
                  (lib.filter (peer: peer != hostname) cfg.members);
              localRepoGlob = "${cfg.backup.repoBaseDir}/${cfg.name}/openwebui/from-*/repo";
              localManifestGlob = "${cfg.backup.repoBaseDir}/${cfg.name}/openwebui/from-*/manifest.json";
              linksByHost = openwebuiLinksByHost;
              torUrl = mkTorUrl openwebuiCfg.expose.tor;
              tor = {
                enabled = openwebuiCfg.expose.tor.enable;
                tls = openwebuiCfg.expose.tor.tls;
                publicPort = openwebuiCfg.expose.tor.publicPort;
                stateDirName = "openwebui";
              };
            };
          })
          // (lib.optionalAttrs searxngCluster {
            searxng = {
              name = "searxng";
              label = "SearXNG";
              recoveryMode = "declarative";
              recoveryDescription = "declarative secret";
              activeUnits =
                [ "searx.service" ]
                ++ lib.optionals (anyCaddyExposure || anyTorExposure) [ "alanix-cluster-exposure.service" ];
              remoteTargets = [ ];
              linksByHost = searxngLinksByHost;
              torUrl = mkTorUrl searxngCfg.expose.tor;
              tor = {
                enabled = searxngCfg.expose.tor.enable;
                tls = searxngCfg.expose.tor.tls;
                publicPort = searxngCfg.expose.tor.publicPort;
                stateDirName = "searxng";
              };
            };
          });
      };

      controllerConfigFile = pkgs.writeText "alanix-cluster-controller.json" (builtins.toJSON controllerConfig);

      exposureScript = pkgs.writeShellScript "alanix-cluster-exposure" ''
        set -euo pipefail

        action="''${1:-start}"
        runtime_dir=/run/alanix-cluster
        caddy_file="$runtime_dir/caddy/cluster.caddy"
        tor_state_dir=/var/lib/tor/alanix-cluster
        tor_file="$tor_state_dir/cluster.conf"
        tor_hostname_dir=/var/lib/alanix-cluster/tor-hostnames

        mkdir -p "$runtime_dir/caddy" "$tor_state_dir" "$tor_hostname_dir"

        if [[ "$action" == "start" ]]; then
          : > "$caddy_file"
          : > "$tor_file"

          ${lib.optionalString anyTailscaleCaddyExposure ''
            ts_ip="$(${config.services.tailscale.package}/bin/tailscale ip -4 | head -n1)"
            if [[ -z "$ts_ip" ]]; then
              echo "failed to determine Tailscale IPv4 address" >&2
              exit 1
            fi
          ''}

          ${lib.optionalString (nextcloudCluster && nextcloudCfg.expose.tailscale.enable) ''
            cat >> "$caddy_file" <<EOF
            ${if nextcloudCfg.expose.tailscale.tls then "https" else "http"}://${nextcloudTailscaleTlsName}:${toString nextcloudCfg.expose.tailscale.port} {
              bind $ts_ip
              ${lib.optionalString nextcloudCfg.expose.tailscale.tls "tls internal"}
              reverse_proxy ${normalizeLocalAddress nextcloudCfg.listenAddress}:${toString nextcloudCfg.port}
            }

            EOF
          ''}

          ${lib.optionalString (nextcloudCluster && nextcloudCfg.expose.wireguard.enable) ''
            cat >> "$caddy_file" <<EOF
            ${if nextcloudCfg.expose.wireguard.tls then "https" else "http"}://${nextcloudWireguardAddress}:${toString nextcloudCfg.expose.wireguard.port} {
              bind ${nextcloudWireguardAddress}
              ${lib.optionalString nextcloudCfg.expose.wireguard.tls "tls internal"}
              reverse_proxy ${normalizeLocalAddress nextcloudCfg.listenAddress}:${toString nextcloudCfg.port}
            }

            EOF
          ''}

          ${lib.optionalString (nextcloudCluster && nextcloudCfg.expose.tor.enable && nextcloudCfg.expose.tor.tls) ''
            cat >> "$caddy_file" <<EOF
            https://${nextcloudCfg.expose.tor.tlsName}:${toString nextcloudCfg.expose.tor.publicPort} {
              bind ${nextcloudTorTargetAddress}
              tls internal
              reverse_proxy ${normalizeLocalAddress nextcloudCfg.listenAddress}:${toString nextcloudCfg.port}
            }

            EOF
          ''}

          ${lib.optionalString (nextcloudCluster && nextcloudCfg.expose.tor.enable) ''
            rm -rf "$tor_state_dir/nextcloud"
            mkdir -p "$tor_state_dir/nextcloud"
            chown tor:tor "$tor_state_dir/nextcloud"
            chmod 0700 "$tor_state_dir/nextcloud"
          ''}

          ${lib.optionalString (nextcloudCluster && nextcloudCfg.expose.tor.enable && nextcloudTorSecretPath != null) ''
            base64 --decode ${lib.escapeShellArg nextcloudTorSecretPath} > "$tor_state_dir/nextcloud/hs_ed25519_secret_key"
            chown tor:tor "$tor_state_dir/nextcloud/hs_ed25519_secret_key"
            chmod 0600 "$tor_state_dir/nextcloud/hs_ed25519_secret_key"
          ''}

          ${lib.optionalString (nextcloudCluster && nextcloudCfg.expose.tor.enable) ''
            cat >> "$tor_file" <<EOF
            HiddenServiceDir $tor_state_dir/nextcloud
            HiddenServiceVersion 3
            HiddenServicePort ${toString nextcloudCfg.expose.tor.publicPort} ${nextcloudTorTargetAddress}:${toString nextcloudTorTargetPort}

            EOF
          ''}

          ${lib.optionalString (nextcloudCluster && nextcloudCollaboraCfg.enable && nextcloudCollaboraCfg.expose.tailscale.enable) ''
            cat >> "$caddy_file" <<EOF
            ${if nextcloudCollaboraCfg.expose.tailscale.tls then "https" else "http"}://${nextcloudCollaboraTailscaleTlsName}:${toString nextcloudCollaboraCfg.expose.tailscale.port} {
              bind $ts_ip
              ${lib.optionalString nextcloudCollaboraCfg.expose.tailscale.tls "tls internal"}
              reverse_proxy 127.0.0.1:${toString nextcloudCollaboraCfg.port}
            }

            EOF
          ''}

          ${lib.optionalString (nextcloudCluster && nextcloudCollaboraCfg.enable && nextcloudCollaboraCfg.expose.wireguard.enable) ''
            cat >> "$caddy_file" <<EOF
            ${if nextcloudCollaboraCfg.expose.wireguard.tls then "https" else "http"}://${nextcloudCollaboraWireguardAddress}:${toString nextcloudCollaboraCfg.expose.wireguard.port} {
              bind ${nextcloudCollaboraWireguardAddress}
              ${lib.optionalString nextcloudCollaboraCfg.expose.wireguard.tls "tls internal"}
              reverse_proxy 127.0.0.1:${toString nextcloudCollaboraCfg.port}
            }

            EOF
          ''}

          ${lib.optionalString (nextcloudCluster && nextcloudCollaboraCfg.enable && nextcloudCollaboraCfg.expose.tor.enable && nextcloudCollaboraCfg.expose.tor.tls) ''
            cat >> "$caddy_file" <<EOF
            https://${nextcloudCollaboraCfg.expose.tor.tlsName}:${toString nextcloudCollaboraCfg.expose.tor.publicPort} {
              bind ${nextcloudCollaboraTorTargetAddress}
              tls internal
              reverse_proxy 127.0.0.1:${toString nextcloudCollaboraCfg.port}
            }

            EOF
          ''}

          ${lib.optionalString (nextcloudCluster && nextcloudCollaboraCfg.enable && nextcloudCollaboraCfg.expose.tor.enable) ''
            rm -rf "$tor_state_dir/nextcloud-collabora"
            mkdir -p "$tor_state_dir/nextcloud-collabora"
            chown tor:tor "$tor_state_dir/nextcloud-collabora"
            chmod 0700 "$tor_state_dir/nextcloud-collabora"
          ''}

          ${lib.optionalString (nextcloudCluster && nextcloudCollaboraCfg.enable && nextcloudCollaboraCfg.expose.tor.enable && nextcloudCollaboraTorSecretPath != null) ''
            base64 --decode ${lib.escapeShellArg nextcloudCollaboraTorSecretPath} > "$tor_state_dir/nextcloud-collabora/hs_ed25519_secret_key"
            chown tor:tor "$tor_state_dir/nextcloud-collabora/hs_ed25519_secret_key"
            chmod 0600 "$tor_state_dir/nextcloud-collabora/hs_ed25519_secret_key"
          ''}

          ${lib.optionalString (nextcloudCluster && nextcloudCollaboraCfg.enable && nextcloudCollaboraCfg.expose.tor.enable) ''
            cat >> "$tor_file" <<EOF
            HiddenServiceDir $tor_state_dir/nextcloud-collabora
            HiddenServiceVersion 3
            HiddenServicePort ${toString nextcloudCollaboraCfg.expose.tor.publicPort} ${nextcloudCollaboraTorTargetAddress}:${toString nextcloudCollaboraTorTargetPort}

            EOF
          ''}

          ${lib.optionalString (filebrowserCluster && filebrowserCfg.expose.tailscale.enable) ''
            cat >> "$caddy_file" <<EOF
            ${if filebrowserCfg.expose.tailscale.tls then "https" else "http"}://${filebrowserTailscaleTlsName}:${toString filebrowserCfg.expose.tailscale.port} {
              bind $ts_ip
              ${lib.optionalString filebrowserCfg.expose.tailscale.tls "tls internal"}
              reverse_proxy ${normalizeLocalAddress filebrowserCfg.listenAddress}:${toString filebrowserCfg.port}
            }

            EOF
          ''}

          ${lib.optionalString (filebrowserCluster && filebrowserCfg.expose.wireguard.enable) ''
            cat >> "$caddy_file" <<EOF
            ${if filebrowserCfg.expose.wireguard.tls then "https" else "http"}://${filebrowserWireguardAddress}:${toString filebrowserCfg.expose.wireguard.port} {
              bind ${filebrowserWireguardAddress}
              ${lib.optionalString filebrowserCfg.expose.wireguard.tls "tls internal"}
              reverse_proxy ${normalizeLocalAddress filebrowserCfg.listenAddress}:${toString filebrowserCfg.port}
            }

            EOF
          ''}

          ${lib.optionalString (filebrowserCluster && filebrowserCfg.expose.tor.enable && filebrowserCfg.expose.tor.tls) ''
            cat >> "$caddy_file" <<EOF
            https://${filebrowserCfg.expose.tor.tlsName}:${toString filebrowserCfg.expose.tor.publicPort} {
              bind ${filebrowserTorTargetAddress}
              tls internal
              reverse_proxy ${normalizeLocalAddress filebrowserCfg.listenAddress}:${toString filebrowserCfg.port}
            }

            EOF
          ''}

          ${lib.optionalString (filebrowserCluster && filebrowserCfg.expose.tor.enable) ''
            rm -rf "$tor_state_dir/filebrowser"
            mkdir -p "$tor_state_dir/filebrowser"
            chown tor:tor "$tor_state_dir/filebrowser"
            chmod 0700 "$tor_state_dir/filebrowser"
          ''}

          ${lib.optionalString (filebrowserCluster && filebrowserCfg.expose.tor.enable && filebrowserTorSecretPath != null) ''
            base64 --decode ${lib.escapeShellArg filebrowserTorSecretPath} > "$tor_state_dir/filebrowser/hs_ed25519_secret_key"
            chown tor:tor "$tor_state_dir/filebrowser/hs_ed25519_secret_key"
            chmod 0600 "$tor_state_dir/filebrowser/hs_ed25519_secret_key"
          ''}

          ${lib.optionalString (filebrowserCluster && filebrowserCfg.expose.tor.enable) ''
            cat >> "$tor_file" <<EOF
            HiddenServiceDir $tor_state_dir/filebrowser
            HiddenServiceVersion 3
            HiddenServicePort ${toString filebrowserCfg.expose.tor.publicPort} ${filebrowserTorTargetAddress}:${toString filebrowserTorTargetPort}

            EOF
          ''}

          ${lib.optionalString (radicaleCluster && radicaleCfg.expose.tailscale.enable) ''
            cat >> "$caddy_file" <<EOF
            ${if radicaleCfg.expose.tailscale.tls then "https" else "http"}://${radicaleTailscaleTlsName}:${toString radicaleCfg.expose.tailscale.port} {
              bind $ts_ip
              ${lib.optionalString radicaleCfg.expose.tailscale.tls "tls internal"}
              reverse_proxy ${normalizeLocalAddress radicaleCfg.listenAddress}:${toString radicaleCfg.port}
            }

            EOF
          ''}

          ${lib.optionalString (radicaleCluster && radicaleCfg.expose.wireguard.enable) ''
            cat >> "$caddy_file" <<EOF
            ${if radicaleCfg.expose.wireguard.tls then "https" else "http"}://${radicaleWireguardAddress}:${toString radicaleCfg.expose.wireguard.port} {
              bind ${radicaleWireguardAddress}
              ${lib.optionalString radicaleCfg.expose.wireguard.tls "tls internal"}
              reverse_proxy ${normalizeLocalAddress radicaleCfg.listenAddress}:${toString radicaleCfg.port}
            }

            EOF
          ''}

          ${lib.optionalString (radicaleCluster && radicaleCfg.expose.tor.enable && radicaleCfg.expose.tor.tls) ''
            cat >> "$caddy_file" <<EOF
            https://${radicaleCfg.expose.tor.tlsName}:${toString radicaleCfg.expose.tor.publicPort} {
              bind ${radicaleTorTargetAddress}
              tls internal
              reverse_proxy ${normalizeLocalAddress radicaleCfg.listenAddress}:${toString radicaleCfg.port}
            }

            EOF
          ''}

          ${lib.optionalString (radicaleCluster && radicaleCfg.expose.tor.enable) ''
            rm -rf "$tor_state_dir/radicale"
            mkdir -p "$tor_state_dir/radicale"
            chown tor:tor "$tor_state_dir/radicale"
            chmod 0700 "$tor_state_dir/radicale"
          ''}

          ${lib.optionalString (radicaleCluster && radicaleCfg.expose.tor.enable && radicaleTorSecretPath != null) ''
            base64 --decode ${lib.escapeShellArg radicaleTorSecretPath} > "$tor_state_dir/radicale/hs_ed25519_secret_key"
            chown tor:tor "$tor_state_dir/radicale/hs_ed25519_secret_key"
            chmod 0600 "$tor_state_dir/radicale/hs_ed25519_secret_key"
          ''}

          ${lib.optionalString (radicaleCluster && radicaleCfg.expose.tor.enable) ''
            cat >> "$tor_file" <<EOF
            HiddenServiceDir $tor_state_dir/radicale
            HiddenServiceVersion 3
            HiddenServicePort ${toString radicaleCfg.expose.tor.publicPort} ${radicaleTorTargetAddress}:${toString radicaleTorTargetPort}

            EOF
          ''}

          ${lib.optionalString (vaultwardenCluster && vaultwardenCfg.expose.tailscale.enable) ''
            cat >> "$caddy_file" <<EOF
            ${if vaultwardenCfg.expose.tailscale.tls then "https" else "http"}://${vaultwardenTailscaleTlsName}:${toString vaultwardenCfg.expose.tailscale.port} {
              bind $ts_ip
              ${lib.optionalString vaultwardenCfg.expose.tailscale.tls "tls internal"}
              reverse_proxy ${normalizeLocalAddress vaultwardenCfg.listenAddress}:${toString vaultwardenCfg.port}
            }

            EOF
          ''}

          ${lib.optionalString (vaultwardenCluster && vaultwardenCfg.expose.wireguard.enable) ''
            cat >> "$caddy_file" <<EOF
            ${if vaultwardenCfg.expose.wireguard.tls then "https" else "http"}://${vaultwardenWireguardAddress}:${toString vaultwardenCfg.expose.wireguard.port} {
              bind ${vaultwardenWireguardAddress}
              ${lib.optionalString vaultwardenCfg.expose.wireguard.tls "tls internal"}
              reverse_proxy ${normalizeLocalAddress vaultwardenCfg.listenAddress}:${toString vaultwardenCfg.port}
            }

            EOF
          ''}

          ${lib.optionalString (vaultwardenCluster && vaultwardenCfg.expose.tor.enable && vaultwardenCfg.expose.tor.tls) ''
            cat >> "$caddy_file" <<EOF
            https://${vaultwardenCfg.expose.tor.tlsName}:${toString vaultwardenCfg.expose.tor.publicPort} {
              bind ${vaultwardenTorTargetAddress}
              tls internal
              reverse_proxy ${normalizeLocalAddress vaultwardenCfg.listenAddress}:${toString vaultwardenCfg.port}
            }

            EOF
          ''}

          ${lib.optionalString (vaultwardenCluster && vaultwardenCfg.expose.tor.enable) ''
            rm -rf "$tor_state_dir/vaultwarden"
            mkdir -p "$tor_state_dir/vaultwarden"
            chown tor:tor "$tor_state_dir/vaultwarden"
            chmod 0700 "$tor_state_dir/vaultwarden"
          ''}

          ${lib.optionalString (vaultwardenCluster && vaultwardenCfg.expose.tor.enable && vaultwardenTorSecretPath != null) ''
            base64 --decode ${lib.escapeShellArg vaultwardenTorSecretPath} > "$tor_state_dir/vaultwarden/hs_ed25519_secret_key"
            chown tor:tor "$tor_state_dir/vaultwarden/hs_ed25519_secret_key"
            chmod 0600 "$tor_state_dir/vaultwarden/hs_ed25519_secret_key"
          ''}

          ${lib.optionalString (vaultwardenCluster && vaultwardenCfg.expose.tor.enable) ''
            cat >> "$tor_file" <<EOF
            HiddenServiceDir $tor_state_dir/vaultwarden
            HiddenServiceVersion 3
            HiddenServicePort ${toString vaultwardenCfg.expose.tor.publicPort} ${vaultwardenTorTargetAddress}:${toString vaultwardenTorTargetPort}

            EOF
          ''}

          ${lib.optionalString (forgejoCluster && forgejoCfg.expose.tailscale.enable) ''
            cat >> "$caddy_file" <<EOF
            ${if forgejoCfg.expose.tailscale.tls then "https" else "http"}://${forgejoTailscaleTlsName}:${toString forgejoCfg.expose.tailscale.port} {
              bind $ts_ip
              ${lib.optionalString forgejoCfg.expose.tailscale.tls "tls internal"}
              reverse_proxy ${normalizeLocalAddress forgejoCfg.listenAddress}:${toString forgejoCfg.port}
            }

            EOF
          ''}

          ${lib.optionalString (forgejoCluster && forgejoCfg.expose.wireguard.enable) ''
            cat >> "$caddy_file" <<EOF
            ${if forgejoCfg.expose.wireguard.tls then "https" else "http"}://${forgejoWireguardAddress}:${toString forgejoCfg.expose.wireguard.port} {
              bind ${forgejoWireguardAddress}
              ${lib.optionalString forgejoCfg.expose.wireguard.tls "tls internal"}
              reverse_proxy ${normalizeLocalAddress forgejoCfg.listenAddress}:${toString forgejoCfg.port}
            }

            EOF
          ''}

          ${lib.optionalString (forgejoCluster && forgejoCfg.expose.tor.enable && forgejoCfg.expose.tor.tls) ''
            cat >> "$caddy_file" <<EOF
            https://${forgejoCfg.expose.tor.tlsName}:${toString forgejoCfg.expose.tor.publicPort} {
              bind ${forgejoTorTargetAddress}
              tls internal
              reverse_proxy ${normalizeLocalAddress forgejoCfg.listenAddress}:${toString forgejoCfg.port}
            }

            EOF
          ''}

          ${lib.optionalString (forgejoCluster && forgejoCfg.expose.tor.enable) ''
            rm -rf "$tor_state_dir/forgejo"
            mkdir -p "$tor_state_dir/forgejo"
            chown tor:tor "$tor_state_dir/forgejo"
            chmod 0700 "$tor_state_dir/forgejo"
          ''}

          ${lib.optionalString (forgejoCluster && forgejoCfg.expose.tor.enable && forgejoTorSecretPath != null) ''
            base64 --decode ${lib.escapeShellArg forgejoTorSecretPath} > "$tor_state_dir/forgejo/hs_ed25519_secret_key"
            chown tor:tor "$tor_state_dir/forgejo/hs_ed25519_secret_key"
            chmod 0600 "$tor_state_dir/forgejo/hs_ed25519_secret_key"
          ''}

          ${lib.optionalString (forgejoCluster && forgejoCfg.expose.tor.enable) ''
            cat >> "$tor_file" <<EOF
            HiddenServiceDir $tor_state_dir/forgejo
            HiddenServiceVersion 3
            HiddenServicePort ${toString forgejoCfg.expose.tor.publicPort} ${forgejoTorTargetAddress}:${toString forgejoTorTargetPort}

            EOF
          ''}

          ${lib.optionalString (invidiousCluster && invidiousCfg.expose.tailscale.enable) ''
            cat >> "$caddy_file" <<EOF
            ${if invidiousCfg.expose.tailscale.tls then "https" else "http"}://${invidiousTailscaleTlsName}:${toString invidiousCfg.expose.tailscale.port} {
              bind $ts_ip
              ${lib.optionalString invidiousCfg.expose.tailscale.tls "tls internal"}
              reverse_proxy ${normalizeLocalAddress invidiousCfg.listenAddress}:${toString invidiousCfg.port}
            }

            EOF
          ''}

          ${lib.optionalString (invidiousCluster && invidiousCfg.expose.wireguard.enable) ''
            cat >> "$caddy_file" <<EOF
            ${if invidiousCfg.expose.wireguard.tls then "https" else "http"}://${invidiousWireguardAddress}:${toString invidiousCfg.expose.wireguard.port} {
              bind ${invidiousWireguardAddress}
              ${lib.optionalString invidiousCfg.expose.wireguard.tls "tls internal"}
              reverse_proxy ${normalizeLocalAddress invidiousCfg.listenAddress}:${toString invidiousCfg.port}
            }

            EOF
          ''}

          ${lib.optionalString (invidiousCluster && invidiousCfg.expose.tor.enable && invidiousCfg.expose.tor.tls) ''
            cat >> "$caddy_file" <<EOF
            https://${invidiousCfg.expose.tor.tlsName}:${toString invidiousCfg.expose.tor.publicPort} {
              bind ${invidiousTorTargetAddress}
              tls internal
              reverse_proxy ${normalizeLocalAddress invidiousCfg.listenAddress}:${toString invidiousCfg.port}
            }

            EOF
          ''}

          ${lib.optionalString (invidiousCluster && invidiousCfg.expose.tor.enable) ''
            rm -rf "$tor_state_dir/invidious"
            mkdir -p "$tor_state_dir/invidious"
            chown tor:tor "$tor_state_dir/invidious"
            chmod 0700 "$tor_state_dir/invidious"
          ''}

          ${lib.optionalString (invidiousCluster && invidiousCfg.expose.tor.enable && invidiousTorSecretPath != null) ''
            base64 --decode ${lib.escapeShellArg invidiousTorSecretPath} > "$tor_state_dir/invidious/hs_ed25519_secret_key"
            chown tor:tor "$tor_state_dir/invidious/hs_ed25519_secret_key"
            chmod 0600 "$tor_state_dir/invidious/hs_ed25519_secret_key"
          ''}

          ${lib.optionalString (invidiousCluster && invidiousCfg.expose.tor.enable) ''
            cat >> "$tor_file" <<EOF
            HiddenServiceDir $tor_state_dir/invidious
            HiddenServiceVersion 3
            HiddenServicePort ${toString invidiousCfg.expose.tor.publicPort} ${invidiousTorTargetAddress}:${toString invidiousTorTargetPort}

            EOF
          ''}

          ${lib.optionalString (immichCluster && immichCfg.expose.tailscale.enable) ''
            cat >> "$caddy_file" <<EOF
            ${if immichCfg.expose.tailscale.tls then "https" else "http"}://${immichTailscaleTlsName}:${toString immichCfg.expose.tailscale.port} {
              bind $ts_ip
              ${lib.optionalString immichCfg.expose.tailscale.tls "tls internal"}
              reverse_proxy ${normalizeLocalAddress immichCfg.listenAddress}:${toString immichCfg.port}
            }

            EOF
          ''}

          ${lib.optionalString (immichCluster && immichCfg.expose.wireguard.enable) ''
            cat >> "$caddy_file" <<EOF
            ${if immichCfg.expose.wireguard.tls then "https" else "http"}://${immichWireguardAddress}:${toString immichCfg.expose.wireguard.port} {
              bind ${immichWireguardAddress}
              ${lib.optionalString immichCfg.expose.wireguard.tls "tls internal"}
              reverse_proxy ${normalizeLocalAddress immichCfg.listenAddress}:${toString immichCfg.port}
            }

            EOF
          ''}

          ${lib.optionalString (immichCluster && immichCfg.expose.tor.enable && immichCfg.expose.tor.tls) ''
            cat >> "$caddy_file" <<EOF
            https://${immichCfg.expose.tor.tlsName}:${toString immichCfg.expose.tor.publicPort} {
              bind ${immichTorTargetAddress}
              tls internal
              reverse_proxy ${normalizeLocalAddress immichCfg.listenAddress}:${toString immichCfg.port}
            }

            EOF
          ''}

          ${lib.optionalString (immichCluster && immichCfg.expose.tor.enable) ''
            rm -rf "$tor_state_dir/immich"
            mkdir -p "$tor_state_dir/immich"
            chown tor:tor "$tor_state_dir/immich"
            chmod 0700 "$tor_state_dir/immich"
          ''}

          ${lib.optionalString (immichCluster && immichCfg.expose.tor.enable && immichTorSecretPath != null) ''
            base64 --decode ${lib.escapeShellArg immichTorSecretPath} > "$tor_state_dir/immich/hs_ed25519_secret_key"
            chown tor:tor "$tor_state_dir/immich/hs_ed25519_secret_key"
            chmod 0600 "$tor_state_dir/immich/hs_ed25519_secret_key"
          ''}

          ${lib.optionalString (immichCluster && immichCfg.expose.tor.enable) ''
            cat >> "$tor_file" <<EOF
            HiddenServiceDir $tor_state_dir/immich
            HiddenServiceVersion 3
            HiddenServicePort ${toString immichCfg.expose.tor.publicPort} ${immichTorTargetAddress}:${toString immichTorTargetPort}

            EOF
          ''}

          ${lib.optionalString (jellyfinCluster && jellyfinCfg.expose.tailscale.enable) ''
            cat >> "$caddy_file" <<EOF
            ${if jellyfinCfg.expose.tailscale.tls then "https" else "http"}://${jellyfinTailscaleTlsName}:${toString jellyfinCfg.expose.tailscale.port} {
              bind $ts_ip
              ${lib.optionalString jellyfinCfg.expose.tailscale.tls "tls internal"}
              reverse_proxy ${normalizeLocalAddress jellyfinCfg.listenAddress}:${toString jellyfinCfg.port}
            }

            EOF
          ''}

          ${lib.optionalString (jellyfinCluster && jellyfinCfg.expose.wireguard.enable) ''
            cat >> "$caddy_file" <<EOF
            ${if jellyfinCfg.expose.wireguard.tls then "https" else "http"}://${jellyfinWireguardAddress}:${toString jellyfinCfg.expose.wireguard.port} {
              bind ${jellyfinWireguardAddress}
              ${lib.optionalString jellyfinCfg.expose.wireguard.tls "tls internal"}
              reverse_proxy ${normalizeLocalAddress jellyfinCfg.listenAddress}:${toString jellyfinCfg.port}
            }

            EOF
          ''}

          ${lib.optionalString (jellyfinCluster && jellyfinCfg.expose.tor.enable && jellyfinCfg.expose.tor.tls) ''
            cat >> "$caddy_file" <<EOF
            https://${jellyfinCfg.expose.tor.tlsName}:${toString jellyfinCfg.expose.tor.publicPort} {
              bind ${jellyfinTorTargetAddress}
              tls internal
              reverse_proxy ${normalizeLocalAddress jellyfinCfg.listenAddress}:${toString jellyfinCfg.port}
            }

            EOF
          ''}

          ${lib.optionalString (jellyfinCluster && jellyfinCfg.expose.tor.enable) ''
            rm -rf "$tor_state_dir/jellyfin"
            mkdir -p "$tor_state_dir/jellyfin"
            chown tor:tor "$tor_state_dir/jellyfin"
            chmod 0700 "$tor_state_dir/jellyfin"
          ''}

          ${lib.optionalString (jellyfinCluster && jellyfinCfg.expose.tor.enable && jellyfinTorSecretPath != null) ''
            base64 --decode ${lib.escapeShellArg jellyfinTorSecretPath} > "$tor_state_dir/jellyfin/hs_ed25519_secret_key"
            chown tor:tor "$tor_state_dir/jellyfin/hs_ed25519_secret_key"
            chmod 0600 "$tor_state_dir/jellyfin/hs_ed25519_secret_key"
          ''}

          ${lib.optionalString (jellyfinCluster && jellyfinCfg.expose.tor.enable) ''
            cat >> "$tor_file" <<EOF
            HiddenServiceDir $tor_state_dir/jellyfin
            HiddenServiceVersion 3
            HiddenServicePort ${toString jellyfinCfg.expose.tor.publicPort} ${jellyfinTorTargetAddress}:${toString jellyfinTorTargetPort}

            EOF
          ''}

          ${lib.optionalString (openwebuiCluster && openwebuiCfg.expose.tailscale.enable) ''
            cat >> "$caddy_file" <<EOF
            ${if openwebuiCfg.expose.tailscale.tls then "https" else "http"}://${openwebuiTailscaleTlsName}:${toString openwebuiCfg.expose.tailscale.port} {
              bind $ts_ip
              ${lib.optionalString openwebuiCfg.expose.tailscale.tls "tls internal"}
              reverse_proxy ${normalizeLocalAddress openwebuiCfg.listenAddress}:${toString openwebuiCfg.port}
            }

            EOF
          ''}

          ${lib.optionalString (openwebuiCluster && openwebuiCfg.expose.wireguard.enable) ''
            cat >> "$caddy_file" <<EOF
            ${if openwebuiCfg.expose.wireguard.tls then "https" else "http"}://${openwebuiWireguardAddress}:${toString openwebuiCfg.expose.wireguard.port} {
              bind ${openwebuiWireguardAddress}
              ${lib.optionalString openwebuiCfg.expose.wireguard.tls "tls internal"}
              reverse_proxy ${normalizeLocalAddress openwebuiCfg.listenAddress}:${toString openwebuiCfg.port}
            }

            EOF
          ''}

          ${lib.optionalString (openwebuiCluster && openwebuiCfg.expose.tor.enable && openwebuiCfg.expose.tor.tls) ''
            cat >> "$caddy_file" <<EOF
            https://${openwebuiCfg.expose.tor.tlsName}:${toString openwebuiCfg.expose.tor.publicPort} {
              bind ${openwebuiTorTargetAddress}
              tls internal
              reverse_proxy ${normalizeLocalAddress openwebuiCfg.listenAddress}:${toString openwebuiCfg.port}
            }

            EOF
          ''}

          ${lib.optionalString (openwebuiCluster && openwebuiCfg.expose.tor.enable) ''
            rm -rf "$tor_state_dir/openwebui"
            mkdir -p "$tor_state_dir/openwebui"
            chown tor:tor "$tor_state_dir/openwebui"
            chmod 0700 "$tor_state_dir/openwebui"
          ''}

          ${lib.optionalString (openwebuiCluster && openwebuiCfg.expose.tor.enable && openwebuiTorSecretPath != null) ''
            base64 --decode ${lib.escapeShellArg openwebuiTorSecretPath} > "$tor_state_dir/openwebui/hs_ed25519_secret_key"
            chown tor:tor "$tor_state_dir/openwebui/hs_ed25519_secret_key"
            chmod 0600 "$tor_state_dir/openwebui/hs_ed25519_secret_key"
          ''}

          ${lib.optionalString (openwebuiCluster && openwebuiCfg.expose.tor.enable) ''
            cat >> "$tor_file" <<EOF
            HiddenServiceDir $tor_state_dir/openwebui
            HiddenServiceVersion 3
            HiddenServicePort ${toString openwebuiCfg.expose.tor.publicPort} ${openwebuiTorTargetAddress}:${toString openwebuiTorTargetPort}

            EOF
          ''}

          ${lib.optionalString (searxngCluster && searxngCfg.expose.tailscale.enable) ''
            cat >> "$caddy_file" <<EOF
            ${if searxngCfg.expose.tailscale.tls then "https" else "http"}://${searxngTailscaleTlsName}:${toString searxngCfg.expose.tailscale.port} {
              bind $ts_ip
              ${lib.optionalString searxngCfg.expose.tailscale.tls "tls internal"}
              reverse_proxy ${normalizeLocalAddress searxngCfg.listenAddress}:${toString searxngCfg.port}
            }

            EOF
          ''}

          ${lib.optionalString (searxngCluster && searxngCfg.expose.wireguard.enable) ''
            cat >> "$caddy_file" <<EOF
            ${if searxngCfg.expose.wireguard.tls then "https" else "http"}://${searxngWireguardAddress}:${toString searxngCfg.expose.wireguard.port} {
              bind ${searxngWireguardAddress}
              ${lib.optionalString searxngCfg.expose.wireguard.tls "tls internal"}
              reverse_proxy ${normalizeLocalAddress searxngCfg.listenAddress}:${toString searxngCfg.port}
            }

            EOF
          ''}

          ${lib.optionalString (searxngCluster && searxngCfg.expose.tor.enable && searxngCfg.expose.tor.tls) ''
            cat >> "$caddy_file" <<EOF
            https://${searxngCfg.expose.tor.tlsName}:${toString searxngCfg.expose.tor.publicPort} {
              bind ${searxngTorTargetAddress}
              tls internal
              reverse_proxy ${normalizeLocalAddress searxngCfg.listenAddress}:${toString searxngCfg.port}
            }

            EOF
          ''}

          ${lib.optionalString (searxngCluster && searxngCfg.expose.tor.enable) ''
            rm -rf "$tor_state_dir/searxng"
            mkdir -p "$tor_state_dir/searxng"
            chown tor:tor "$tor_state_dir/searxng"
            chmod 0700 "$tor_state_dir/searxng"
          ''}

          ${lib.optionalString (searxngCluster && searxngCfg.expose.tor.enable && searxngTorSecretPath != null) ''
            base64 --decode ${lib.escapeShellArg searxngTorSecretPath} > "$tor_state_dir/searxng/hs_ed25519_secret_key"
            chown tor:tor "$tor_state_dir/searxng/hs_ed25519_secret_key"
            chmod 0600 "$tor_state_dir/searxng/hs_ed25519_secret_key"
          ''}

          ${lib.optionalString (searxngCluster && searxngCfg.expose.tor.enable) ''
            cat >> "$tor_file" <<EOF
            HiddenServiceDir $tor_state_dir/searxng
            HiddenServiceVersion 3
            HiddenServicePort ${toString searxngCfg.expose.tor.publicPort} ${searxngTorTargetAddress}:${toString searxngTorTargetPort}

            EOF
          ''}

          ${lib.optionalString (filebrowserCluster && filebrowserCfg.expose.wan.enable) ''
            cat >> "$caddy_file" <<EOF
            ${filebrowserCfg.expose.wan.domain} {
              reverse_proxy ${normalizeLocalAddress filebrowserCfg.listenAddress}:${toString filebrowserCfg.port}
            }

            EOF
          ''}

          ${lib.optionalString (radicaleCluster && radicaleCfg.expose.wan.enable) ''
            cat >> "$caddy_file" <<EOF
            ${radicaleCfg.expose.wan.domain} {
              reverse_proxy ${normalizeLocalAddress radicaleCfg.listenAddress}:${toString radicaleCfg.port}
            }

            EOF
          ''}

          ${lib.optionalString (vaultwardenCluster && vaultwardenCfg.expose.wan.enable) ''
            cat >> "$caddy_file" <<EOF
            ${vaultwardenCfg.expose.wan.domain} {
              reverse_proxy ${normalizeLocalAddress vaultwardenCfg.listenAddress}:${toString vaultwardenCfg.port}
            }

            EOF
          ''}

          ${lib.optionalString (forgejoCluster && forgejoCfg.expose.wan.enable) ''
            cat >> "$caddy_file" <<EOF
            ${forgejoCfg.expose.wan.domain} {
              reverse_proxy ${normalizeLocalAddress forgejoCfg.listenAddress}:${toString forgejoCfg.port}
            }

            EOF
          ''}

          ${lib.optionalString (invidiousCluster && invidiousCfg.expose.wan.enable) ''
            cat >> "$caddy_file" <<EOF
            ${invidiousCfg.expose.wan.domain} {
              reverse_proxy ${normalizeLocalAddress invidiousCfg.listenAddress}:${toString invidiousCfg.port}
            }

            EOF
          ''}

          ${lib.optionalString (immichCluster && immichCfg.expose.wan.enable) ''
            cat >> "$caddy_file" <<EOF
            ${immichCfg.expose.wan.domain} {
              reverse_proxy ${normalizeLocalAddress immichCfg.listenAddress}:${toString immichCfg.port}
            }

            EOF
          ''}

          ${lib.optionalString (jellyfinCluster && jellyfinCfg.expose.wan.enable) ''
            cat >> "$caddy_file" <<EOF
            ${jellyfinCfg.expose.wan.domain} {
              reverse_proxy ${normalizeLocalAddress jellyfinCfg.listenAddress}:${toString jellyfinCfg.port}
            }

            EOF
          ''}

          ${lib.optionalString (nextcloudCluster && nextcloudCfg.expose.wan.enable) ''
            cat >> "$caddy_file" <<EOF
            ${nextcloudCfg.expose.wan.domain} {
              reverse_proxy ${normalizeLocalAddress nextcloudCfg.listenAddress}:${toString nextcloudCfg.port}
            }

            EOF
          ''}

          ${lib.optionalString (nextcloudCluster && nextcloudCollaboraCfg.enable && nextcloudCollaboraCfg.expose.wan.enable) ''
            cat >> "$caddy_file" <<EOF
            ${nextcloudCollaboraCfg.expose.wan.domain} {
              reverse_proxy 127.0.0.1:${toString nextcloudCollaboraCfg.port}
            }

            EOF
          ''}

          ${lib.optionalString (searxngCluster && searxngCfg.expose.wan.enable) ''
            cat >> "$caddy_file" <<EOF
            ${searxngCfg.expose.wan.domain} {
              reverse_proxy ${normalizeLocalAddress searxngCfg.listenAddress}:${toString searxngCfg.port}
            }

            EOF
          ''}

          ${lib.optionalString anyCaddyExposure ''
            systemctl start caddy.service
            systemctl reload caddy.service
          ''}

          ${lib.optionalString anyTorExposure ''
            systemctl start tor.service
            systemctl reload tor.service

            publish_tor_hostname() {
              local service_name="$1"
              local source="$tor_state_dir/$service_name/hostname"
              local target="$tor_hostname_dir/$service_name"
              local attempts=20

              while [[ "$attempts" -gt 0 ]]; do
                if [[ -s "$source" ]]; then
                  install -m0644 -o root -g root "$source" "$target"
                  return 0
                fi
                sleep 1
                attempts=$((attempts - 1))
              done

              return 0
            }

            ${lib.optionalString (nextcloudCluster && nextcloudCfg.expose.tor.enable) ''
              publish_tor_hostname nextcloud
            ''}
            ${lib.optionalString (nextcloudCluster && nextcloudCollaboraCfg.enable && nextcloudCollaboraCfg.expose.tor.enable) ''
              publish_tor_hostname nextcloud-collabora
            ''}
            ${lib.optionalString (filebrowserCluster && filebrowserCfg.expose.tor.enable) ''
              publish_tor_hostname filebrowser
            ''}
            ${lib.optionalString (radicaleCluster && radicaleCfg.expose.tor.enable) ''
              publish_tor_hostname radicale
            ''}
            ${lib.optionalString (vaultwardenCluster && vaultwardenCfg.expose.tor.enable) ''
              publish_tor_hostname vaultwarden
            ''}
            ${lib.optionalString (forgejoCluster && forgejoCfg.expose.tor.enable) ''
              publish_tor_hostname forgejo
            ''}
            ${lib.optionalString (invidiousCluster && invidiousCfg.expose.tor.enable) ''
              publish_tor_hostname invidious
            ''}
            ${lib.optionalString (immichCluster && immichCfg.expose.tor.enable) ''
              publish_tor_hostname immich
            ''}
            ${lib.optionalString (jellyfinCluster && jellyfinCfg.expose.tor.enable) ''
              publish_tor_hostname jellyfin
            ''}
            ${lib.optionalString (openwebuiCluster && openwebuiCfg.expose.tor.enable) ''
              publish_tor_hostname openwebui
            ''}
            ${lib.optionalString (searxngCluster && searxngCfg.expose.tor.enable) ''
              publish_tor_hostname searxng
            ''}
          ''}
        else
          : > "$caddy_file"
          : > "$tor_file"
          rm -rf "$tor_state_dir/vaultwarden"
          rm -rf "$tor_state_dir/forgejo"
          rm -rf "$tor_state_dir/invidious"
          rm -rf "$tor_state_dir/immich"
          rm -rf "$tor_state_dir/jellyfin"
          rm -rf "$tor_state_dir/filebrowser"
          rm -rf "$tor_state_dir/radicale"
          rm -rf "$tor_state_dir/nextcloud"
          rm -rf "$tor_state_dir/nextcloud-collabora"
          rm -rf "$tor_state_dir/openwebui"
          rm -rf "$tor_state_dir/searxng"

          ${lib.optionalString anyCaddyExposure ''
            systemctl reload caddy.service || true
          ''}

          ${lib.optionalString anyTorExposure ''
            systemctl reload tor.service || true
          ''}
        fi
      '';
    in
    lib.mkMerge [
      {
        assertions =
          [
            {
              assertion = builtins.elem hostname cfg.members;
              message = "alanix.cluster.enable requires the current host to be listed in alanix.cluster.members.";
            }
            {
              assertion = cfg.members == lib.unique cfg.members;
              message = "alanix.cluster.members must not contain duplicates.";
            }
            {
              assertion = cfg.voters == lib.unique cfg.voters;
              message = "alanix.cluster.voters must not contain duplicates.";
            }
            {
              assertion = cfg.priority == lib.unique cfg.priority;
              message = "alanix.cluster.priority must not contain duplicates.";
            }
            {
              assertion = lib.all (host: builtins.elem host cfg.members) cfg.voters;
              message = "alanix.cluster.voters must be a subset of alanix.cluster.members.";
            }
            {
              assertion = lib.all (host: builtins.elem host cfg.members) cfg.priority;
              message = "alanix.cluster.priority must be a subset of alanix.cluster.members.";
            }
            {
              assertion = builtins.length cfg.voters == 3;
              message = "alanix.cluster.voters must contain exactly three hosts in v1.";
            }
            {
              assertion = cfg.transport == "tailscale" -> config.alanix.tailscale.enable;
              message = "alanix.cluster.transport = \"tailscale\" requires alanix.tailscale.enable = true.";
            }
            {
              assertion = cfg.transport == "wireguard" -> config.alanix.wireguard.enable;
              message = "alanix.cluster.transport = \"wireguard\" requires alanix.wireguard.enable = true.";
            }
            {
              assertion = cfg.transport != "tailscale" || config.alanix.tailscale.address != null;
              message = "alanix.cluster.transport = \"tailscale\" requires alanix.tailscale.address to be set.";
            }
            {
              assertion = cfg.transport != "wireguard" || config.alanix.wireguard.vpnIP != null;
              message = "alanix.cluster.transport = \"wireguard\" requires alanix.wireguard.vpnIP to be set.";
            }
            {
              assertion = cfg.etcd.bootstrapGeneration >= 1;
              message = "alanix.cluster.etcd.bootstrapGeneration must be at least 1.";
            }
            {
              assertion = lib.hasAttrByPath [ "sops" "secrets" cfg.backup.passwordSecret ] config;
              message = "alanix.cluster.backup.passwordSecret must reference a declared sops secret.";
            }
            {
              assertion = lib.hasAttrByPath [ "users" "users" cfg.backup.repoUser ] config;
              message = "alanix.cluster.backup.repoUser must reference a declared local user.";
            }
          ]
          ++ map
            (peer: {
              assertion = hostTransportAddress peer != null;
              message = "Cluster member `${peer}` is missing an entry in alanix.cluster.addresses.";
            })
            cfg.members
          ++ lib.optionals vaultwardenCluster [
            {
              assertion = config.services.vaultwarden.dbBackend == "sqlite";
              message = "Vaultwarden cluster mode currently requires the sqlite backend.";
            }
            {
              assertion = config.systemd.services ? backup-vaultwarden;
              message = "Vaultwarden cluster mode requires backup-vaultwarden.service to exist.";
            }
          ]
          ++ lib.optionals forgejoCluster [
            {
              assertion = config.services.forgejo.database.type == "sqlite3";
              message = "Forgejo cluster mode currently requires the sqlite3 backend.";
            }
          ]
          ++ lib.optionals invidiousCluster [
            {
              assertion = config.services.invidious.database.createLocally;
              message = "Invidious cluster mode currently requires a locally managed PostgreSQL database.";
            }
            {
              assertion = config.services.invidious.database.host == null;
              message = "Invidious cluster mode currently requires PostgreSQL on the local host.";
            }
          ]
          ++ lib.optionals immichCluster [
            {
              assertion = config.services.immich.database.enable;
              message = "Immich cluster mode currently requires a locally managed PostgreSQL database.";
            }
            {
              assertion = lib.hasPrefix "/" config.services.immich.database.host;
              message = "Immich cluster mode currently requires PostgreSQL on the local host via unix socket.";
            }
            {
              assertion = config.services.immich.database.user == config.services.immich.user;
              message = "Immich cluster mode currently requires services.immich.database.user to match services.immich.user.";
            }
          ]
          ++ lib.optionals nextcloudCluster [
            {
              assertion = config.services.nextcloud.database.createLocally;
              message = "Nextcloud cluster mode currently requires a locally managed PostgreSQL database.";
            }
            {
              assertion = config.services.nextcloud.config.dbtype == "pgsql";
              message = "Nextcloud cluster mode currently requires PostgreSQL.";
            }
            {
              assertion = lib.hasPrefix "/" config.services.nextcloud.config.dbhost;
              message = "Nextcloud cluster mode currently requires PostgreSQL on the local host via unix socket.";
            }
            {
              assertion = lib.hasPrefix "/" nextcloudCfg.stateDir;
              message = "Nextcloud cluster mode requires alanix.nextcloud.stateDir to be an absolute path.";
            }
            {
              assertion = nextcloudCfg.dataDir == null || lib.hasPrefix "/" nextcloudCfg.dataDir;
              message = "Nextcloud cluster mode requires alanix.nextcloud.dataDir to be null or an absolute path.";
            }
            {
              assertion = lib.hasPrefix "/" nextcloudCfg.backupDir;
              message = "Nextcloud cluster mode requires alanix.nextcloud.backupDir to be an absolute path.";
            }
          ]
          ++ lib.optionals filebrowserCluster [
            {
              assertion = lib.hasPrefix "/" filebrowserCfg.root;
              message = "File Browser cluster mode requires alanix.filebrowser.root to be an absolute path.";
            }
            {
              assertion = lib.hasPrefix "/" filebrowserCfg.database;
              message = "File Browser cluster mode requires alanix.filebrowser.database to be an absolute path.";
            }
            {
              assertion = lib.hasPrefix "/" filebrowserCfg.backupDir;
              message = "File Browser cluster mode requires alanix.filebrowser.backupDir to be an absolute path.";
            }
          ]
          ++ lib.optionals radicaleCluster [
            {
              assertion = lib.hasPrefix "/" radicaleCfg.storageDir;
              message = "Radicale cluster mode requires alanix.radicale.storageDir to be an absolute path.";
            }
            {
              assertion = lib.hasPrefix "/" radicaleCfg.backupDir;
              message = "Radicale cluster mode requires alanix.radicale.backupDir to be an absolute path.";
            }
          ]
          ++ lib.optionals jellyfinCluster [
            {
              assertion = lib.hasPrefix "/" jellyfinCfg.dataDir;
              message = "Jellyfin cluster mode requires alanix.jellyfin.dataDir to be an absolute path.";
            }
            {
              assertion = lib.hasPrefix "/" jellyfinCfg.backupDir;
              message = "Jellyfin cluster mode requires alanix.jellyfin.backupDir to be an absolute path.";
            }
          ]
          ++ lib.optionals openwebuiCluster [
            {
              assertion = lib.hasPrefix "/" openwebuiCfg.stateDir;
              message = "Open WebUI cluster mode requires alanix.openwebui.stateDir to be an absolute path.";
            }
          ]
          ++ lib.optionals searxngCluster [
            {
              assertion = lib.hasPrefix "/" searxngCfg.stateDir;
              message = "SearXNG cluster mode requires alanix.searxng.stateDir to be an absolute path.";
            }
          ]
          ++ serviceExposure.mkAssertions {
            inherit config;
            optionPrefix = "alanix.cluster.dashboard.expose";
            endpoint = dashboardEndpoint;
            exposeCfg = dashboardCfg.expose;
          };

        systemd.targets."alanix-cluster-active" = {
          description = "Alanix cluster active target";
        };

        system.activationScripts.alanixClusterTor = lib.mkIf anyTorExposure {
          deps = [ "users" ];
          text = ''
            mkdir -p /var/lib/tor/alanix-cluster
            chown root:tor /var/lib/tor/alanix-cluster
            chmod 0750 /var/lib/tor/alanix-cluster
            if [ ! -e /var/lib/tor/alanix-cluster/cluster.conf ]; then
              touch /var/lib/tor/alanix-cluster/cluster.conf
            fi
            chown root:tor /var/lib/tor/alanix-cluster/cluster.conf
            chmod 0640 /var/lib/tor/alanix-cluster/cluster.conf
          '';
        };

        systemd.services."alanix-cluster-controller" = {
          description = "Alanix cluster controller";
          wantedBy = [ "multi-user.target" ];
          after =
            [ "network-online.target" "sops-nix.service" ]
            ++ lib.optional (cfg.transport == "tailscale") "tailscaled.service"
            ++ lib.optionals (invidiousCluster || immichCluster || nextcloudCluster) [ "postgresql.service" ]
            ++ lib.optional isVoter "etcd.service";
          wants =
            [ "network-online.target" "sops-nix.service" ]
            ++ lib.optional (cfg.transport == "tailscale") "tailscaled.service"
            ++ lib.optionals (invidiousCluster || immichCluster || nextcloudCluster) [ "postgresql.service" ]
            ++ lib.optional isVoter "etcd.service";
          path = with pkgs; [
            coreutils
            etcd
            jq
            openssh
            python3
            restic
            rsync
            sqlite
            systemd
            util-linux
          ] ++ lib.optionals (invidiousCluster || immichCluster || nextcloudCluster) [ config.services.postgresql.package ];
          serviceConfig = {
            Type = "simple";
            Restart = "always";
            RestartSec = "5s";
            ExecStart = "${pkgs.python3}/bin/python3 ${./controller.py} ${controllerConfigFile}";
          };
          environment = {
            PYTHONUNBUFFERED = "1";
          };
        };

        systemd.services."alanix-cluster-dashboard" = lib.mkIf dashboardCfg.enable {
          description = "Alanix cluster dashboard";
          wantedBy = [ "multi-user.target" ];
          after =
            [ "network-online.target" "sops-nix.service" ]
            ++ lib.optional (cfg.transport == "tailscale") "tailscaled.service";
          wants =
            [ "network-online.target" "sops-nix.service" ]
            ++ lib.optional (cfg.transport == "tailscale") "tailscaled.service";
          path = with pkgs; [
            coreutils
            etcd
            python3
            systemd
          ];
          serviceConfig = {
            Type = "simple";
            Restart = "always";
            RestartSec = "5s";
            ExecStart = "${pkgs.python3}/bin/python3 ${./dashboard.py} ${controllerConfigFile}";
          };
          environment = {
            PYTHONUNBUFFERED = "1";
          };
        };

        systemd.tmpfiles.rules =
          [
            "d ${cfg.backup.repoBaseDir} 0700 ${cfg.backup.repoUser} users - -"
          ]
          ++ lib.optionals nextcloudCluster [
            "d ${nextcloudCfg.backupDir} 0750 nextcloud ${backupRepoUserGroup} - -"
          ]
          ++ lib.optionals filebrowserCluster [
            "d ${filebrowserCfg.backupDir} 0750 filebrowser ${backupRepoUserGroup} - -"
          ]
          ++ lib.optionals radicaleCluster [
            "d ${radicaleCfg.backupDir} 0750 radicale ${backupRepoUserGroup} - -"
          ]
          ++ lib.optionals forgejoCluster [
            "d ${forgejoCfg.backupDir} 0750 forgejo ${backupRepoUserGroup} - -"
          ]
          ++ lib.optionals invidiousCluster [
            "d ${invidiousCfg.backupDir} 0750 invidious ${backupRepoUserGroup} - -"
          ]
          ++ lib.optionals immichCluster [
            "d ${immichCfg.backupDir} 0750 immich ${backupRepoUserGroup} - -"
          ]
          ++ lib.optionals jellyfinCluster [
            "d ${jellyfinCfg.backupDir} 0750 jellyfin ${backupRepoUserGroup} - -"
          ]
          ++ lib.optionals openwebuiCluster [
            "d ${openwebuiCfg.backupDir} 0750 open-webui ${backupRepoUserGroup} - -"
          ]
          ++ lib.optionals anyCaddyExposure [
            "d /run/alanix-cluster 0755 root root - -"
            "d /run/alanix-cluster/caddy 0755 root root - -"
            "f /run/alanix-cluster/caddy/cluster.caddy 0644 root root - -"
          ]
          ++ lib.optionals anyTorExposure [
            "d /var/lib/tor/alanix-cluster 0750 root tor - -"
            "f /var/lib/tor/alanix-cluster/cluster.conf 0640 root tor - -"
            "d /var/lib/alanix-cluster 0755 root root - -"
            "d /var/lib/alanix-cluster/tor-hostnames 0755 root root - -"
          ];
      }

      (lib.mkIf isVoter {
        services.etcd = {
          enable = true;
          name = hostname;
          # Bind once on all interfaces; localhost access still works via 127.0.0.1.
          listenClientUrls = [ "http://0.0.0.0:2379" ];
          advertiseClientUrls = [ "http://${localTransportAddress}:2379" ];
          listenPeerUrls = [ "http://0.0.0.0:2380" ];
          initialAdvertisePeerUrls = [ "http://${localTransportAddress}:2380" ];
          initialCluster = map (peer: "${peer}=http://${hostTransportAddress peer}:2380") cfg.voters;
          initialClusterState = "new";
          initialClusterToken = "alanix-${cfg.name}";
          extraConf = {
            HEARTBEAT_INTERVAL = toString (parseDurationMs cfg.etcd.heartbeatInterval);
            ELECTION_TIMEOUT = toString (parseDurationMs cfg.etcd.electionTimeout);
          };
        };

        systemd.services.etcd.preStart = lib.mkBefore ''
          set -euo pipefail

          generation_file=/var/lib/etcd/.alanix-bootstrap-generation
          desired_generation=${lib.escapeShellArg (toString cfg.etcd.bootstrapGeneration)}
          current_generation=""

          if [ -f "$generation_file" ]; then
            current_generation="$(cat "$generation_file" 2>/dev/null || true)"
          fi

          if [ "$current_generation" != "$desired_generation" ]; then
            echo "alanix-cluster: resetting /var/lib/etcd for bootstrap generation $desired_generation"
            rm -rf /var/lib/etcd
            install -d -o etcd -g etcd -m 0700 /var/lib/etcd
            printf '%s\n' "$desired_generation" > "$generation_file"
            chown etcd:etcd "$generation_file"
            chmod 0600 "$generation_file"
          fi
        '';

        systemd.services.etcd.serviceConfig.UnsetEnvironment = [
          "ETCD_CLIENT_CERT_AUTH"
          "ETCD_DISCOVERY"
          "ETCD_PEER_CLIENT_CERT_AUTH"
        ];

        systemd.services.etcd.serviceConfig.PermissionsStartOnly = true;

        systemd.services.etcd.after =
          [ "network-online.target" ]
          ++ lib.optional (cfg.transport == "tailscale") "tailscaled.service";

        systemd.services.etcd.wants =
          [ "network-online.target" ]
          ++ lib.optional (cfg.transport == "tailscale") "tailscaled.service";

      })

      (lib.mkIf (isVoter && cfg.transport == "wireguard") {
        networking.firewall.interfaces.wg0.allowedTCPPorts = [
          2379
          2380
        ];
      })

      (lib.mkIf dashboardCfg.enable (
        serviceExposure.mkConfig {
          serviceName = "cluster-dashboard";
          serviceDescription = "Cluster Dashboard";
          inherit config;
          endpoint = dashboardEndpoint;
          exposeCfg = dashboardCfg.expose;
        }
      ))

      (lib.mkIf anyCaddyExposure {
        services.caddy.enable = true;
        services.caddy.extraConfig = lib.mkAfter ''
          import /run/alanix-cluster/caddy/cluster.caddy
        '';
      })

      (lib.mkIf anyWanExposure {
        networking.firewall.allowedTCPPorts = [ 80 443 ];
      })

      (lib.mkIf ddnsCfg.enable {
        systemd.services.alanix-cluster-ddns = {
          description = "Alanix cluster leader DDNS (Cloudflare)";
          wantedBy = [ "alanix-cluster-active.target" ];
          partOf = [ "alanix-cluster-active.target" ];
          after = [
            "alanix-cluster-active.target"
            "network-online.target"
            "sops-nix.service"
          ];
          wants = [ "network-online.target" ];
          environment = {
            DOMAINS = lib.concatStringsSep " " ddnsCfg.domains;
            IP4_PROVIDER = "cloudflare.trace";
            IP6_PROVIDER = "none";
            UPDATE_CRON = "@every 5m";
            UPDATE_ON_START = "true";
            DELETE_ON_STOP = "false";
            TTL = "1";
          };
          serviceConfig = {
            ExecStart = "${pkgs.cloudflare-ddns}/bin/ddns";
            EnvironmentFile = ddnsCfg.credentialsFile;
            Restart = "on-failure";
            RestartSec = 10;
          };
        };
      })

      (lib.mkIf anyTorExposure {
        services.tor.enable = true;
        services.tor.settings."%include" = "/var/lib/tor/alanix-cluster/cluster.conf";
      })

      (lib.mkIf (anyCaddyExposure || anyTorExposure) {
        systemd.services."alanix-cluster-exposure" = {
          description = "Alanix cluster runtime exposure manager";
          wantedBy = [ "alanix-cluster-active.target" ];
          partOf = [ "alanix-cluster-active.target" ];
          after =
            lib.optionals nextcloudCluster [ "phpfpm-nextcloud.service" ]
            ++ lib.optionals (nextcloudCluster && nextcloudCollaboraCfg.enable) [ "coolwsd.service" ]
            ++
            lib.optionals filebrowserCluster [ "filebrowser.service" ]
            ++
            lib.optionals radicaleCluster [ "radicale.service" ]
            ++
            lib.optionals vaultwardenCluster [ "vaultwarden.service" ]
            ++ lib.optionals forgejoCluster [ "forgejo.service" ]
            ++ lib.optionals invidiousCluster [ "invidious.service" ]
            ++ lib.optionals immichCluster [ "immich-server.service" ]
            ++ lib.optionals jellyfinCluster [ "jellyfin.service" ]
            ++ lib.optionals openwebuiCluster [ "open-webui.service" ]
            ++ lib.optionals searxngCluster [ "searx.service" ];
          wants =
            lib.optionals nextcloudCluster [ "phpfpm-nextcloud.service" ]
            ++ lib.optionals (nextcloudCluster && nextcloudCollaboraCfg.enable) [ "coolwsd.service" ]
            ++
            lib.optionals filebrowserCluster [ "filebrowser.service" ]
            ++
            lib.optionals radicaleCluster [ "radicale.service" ]
            ++
            lib.optionals vaultwardenCluster [ "vaultwarden.service" ]
            ++ lib.optionals forgejoCluster [ "forgejo.service" ]
            ++ lib.optionals invidiousCluster [ "invidious.service" ]
            ++ lib.optionals immichCluster [ "immich-server.service" ]
            ++ lib.optionals jellyfinCluster [ "jellyfin.service" ]
            ++ lib.optionals openwebuiCluster [ "open-webui.service" ]
            ++ lib.optionals searxngCluster [ "searx.service" ];
          path =
            [ pkgs.coreutils pkgs.systemd ]
            ++ lib.optionals anyCaddyExposure [ config.services.caddy.package ]
            ++ lib.optionals (cfg.transport == "tailscale") [ config.services.tailscale.package ];
          script = "${exposureScript} start";
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            SuccessExitStatus = [ "SIGTERM" ];
            ExecStop = "${exposureScript} stop";
          };
        };
      })

      (lib.mkIf nextcloudCluster {
        systemd.services.nextcloud-setup = {
          wantedBy = lib.mkForce [ "alanix-cluster-active.target" ];
          partOf = [ "alanix-cluster-active.target" ];
        };

        systemd.services.phpfpm-nextcloud = {
          wantedBy = lib.mkForce [ "alanix-cluster-active.target" ];
          partOf = [ "alanix-cluster-active.target" ];
        };

        systemd.timers.nextcloud-cron = {
          wantedBy = lib.mkForce [ "alanix-cluster-active.target" ];
          partOf = [ "alanix-cluster-active.target" ];
        };

        systemd.services.nextcloud-cron.partOf = [ "alanix-cluster-active.target" ];

        systemd.services.nextcloud-reconcile = {
          wantedBy = lib.mkForce [ "alanix-cluster-active.target" ];
          partOf = [ "alanix-cluster-active.target" ];
        };

        systemd.services.coolwsd = lib.mkIf nextcloudCollaboraCfg.enable {
          wantedBy = lib.mkForce [ "alanix-cluster-active.target" ];
          partOf = [ "alanix-cluster-active.target" ];
        };
      })

      (lib.mkIf filebrowserCluster {
        systemd.services.filebrowser = {
          wantedBy = lib.mkForce [ "alanix-cluster-active.target" ];
          partOf = [ "alanix-cluster-active.target" ];
        };
      })

      (lib.mkIf radicaleCluster {
        systemd.services.radicale = {
          wantedBy = lib.mkForce [ "alanix-cluster-active.target" ];
          partOf = [ "alanix-cluster-active.target" ];
        };
      })

      (lib.mkIf vaultwardenCluster {
        systemd.services.vaultwarden = {
          wantedBy = lib.mkForce [ "alanix-cluster-active.target" ];
          partOf = [ "alanix-cluster-active.target" ];
        };

        systemd.services.backup-vaultwarden.wantedBy = lib.mkForce [ ];
        systemd.timers.backup-vaultwarden.wantedBy = lib.mkForce [ ];
      })

      (lib.mkIf forgejoCluster {
        systemd.services.forgejo = {
          wantedBy = lib.mkForce [ "alanix-cluster-active.target" ];
          partOf = [ "alanix-cluster-active.target" ];
        };
      })

      (lib.mkIf invidiousCluster {
        systemd.services.invidious = {
          wantedBy = lib.mkForce [ "alanix-cluster-active.target" ];
          partOf = [ "alanix-cluster-active.target" ];
        };

        systemd.services.invidious-companion = lib.mkIf invidiousCfg.companion.enable {
          wantedBy = lib.mkForce [ "alanix-cluster-active.target" ];
          partOf = [ "alanix-cluster-active.target" ];
        };
      })

      (lib.mkIf immichCluster {
        systemd.services.immich-server = {
          wantedBy = lib.mkForce [ "alanix-cluster-active.target" ];
          partOf = [ "alanix-cluster-active.target" ];
        };

        systemd.services.immich-machine-learning = lib.mkIf immichCfg.machineLearning.enable {
          wantedBy = lib.mkForce [ "alanix-cluster-active.target" ];
          partOf = [ "alanix-cluster-active.target" ];
        };
      })

      (lib.mkIf jellyfinCluster {
        systemd.services.jellyfin = {
          wantedBy = lib.mkForce [ "alanix-cluster-active.target" ];
          partOf = [ "alanix-cluster-active.target" ];
        };
      })

      (lib.mkIf openwebuiCluster {
        systemd.services.open-webui = {
          wantedBy = lib.mkForce [ "alanix-cluster-active.target" ];
          partOf = [ "alanix-cluster-active.target" ];
        };
      })

      (lib.mkIf searxngCluster {
        systemd.services.searx = {
          wantedBy = lib.mkForce [ "alanix-cluster-active.target" ];
          partOf = [ "alanix-cluster-active.target" ];
        };
      })
    ]
  );
}
