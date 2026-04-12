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
  };

  config = lib.mkIf cfg.enable (
    let
      hostTransportAddress = hostName: cfg.addresses.${hostName} or null;
      localTransportAddress = hostTransportAddress hostname;
      isVoter = builtins.elem hostname cfg.voters;

      vaultwardenCfg = config.alanix.vaultwarden;
      forgejoCfg = config.alanix.forgejo;
      vaultwardenCluster = vaultwardenCfg.enable && vaultwardenCfg.cluster.enable;
      forgejoCluster = forgejoCfg.enable && forgejoCfg.cluster.enable;
      dashboardCfg = cfg.dashboard;
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

      backupRepoUserGroup =
        if lib.hasAttrByPath [ "users" "users" cfg.backup.repoUser ] config then
          config.users.users.${cfg.backup.repoUser}.group
        else
          null;

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

      anyTlsExposure =
        (
          vaultwardenCluster
          && (
            (vaultwardenCfg.expose.tailscale.enable && vaultwardenCfg.expose.tailscale.tls)
            || (vaultwardenCfg.expose.wireguard.enable && vaultwardenCfg.expose.wireguard.tls)
            || (vaultwardenCfg.expose.tor.enable && vaultwardenCfg.expose.tor.tls)
          )
        )
        || (
          forgejoCluster
          && (
            (forgejoCfg.expose.tailscale.enable && forgejoCfg.expose.tailscale.tls)
            || (forgejoCfg.expose.wireguard.enable && forgejoCfg.expose.wireguard.tls)
            || (forgejoCfg.expose.tor.enable && forgejoCfg.expose.tor.tls)
          )
        );

      anyTorExposure =
        (vaultwardenCluster && vaultwardenCfg.expose.tor.enable)
        || (forgejoCluster && forgejoCfg.expose.tor.enable);

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
        (lib.optionalAttrs vaultwardenCluster (
          mkPeerConfigLinksByHost {
            label = "Vaultwarden (canonical)";
            urlFn = peer:
              let
                hostCfg = peerHostCfg peer;
              in
              if hostCfg != null then hostCfg.config.alanix.vaultwarden.rootUrl else null;
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
        (lib.optionalAttrs forgejoCluster (
          mkPeerConfigLinksByHost {
            label = "Forgejo (canonical)";
            urlFn = peer:
              let
                hostCfg = peerHostCfg peer;
              in
              if hostCfg != null then hostCfg.config.alanix.forgejo.rootUrl else null;
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
          (lib.optionalAttrs vaultwardenCluster {
            vaultwarden = {
              name = "vaultwarden";
              backupInterval = vaultwardenCfg.cluster.backupInterval;
              maxBackupAge = vaultwardenCfg.cluster.maxBackupAge;
              activeUnits =
                [ "vaultwarden.service" ]
                ++ lib.optionals (anyTlsExposure || anyTorExposure) [ "alanix-cluster-exposure.service" ];
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
            };
          })
          // (lib.optionalAttrs forgejoCluster {
            forgejo = {
              name = "forgejo";
              backupInterval = forgejoCfg.cluster.backupInterval;
              maxBackupAge = forgejoCfg.cluster.maxBackupAge;
              activeUnits =
                [ "forgejo.service" ]
                ++ lib.optionals (anyTlsExposure || anyTorExposure) [ "alanix-cluster-exposure.service" ];
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

        mkdir -p "$runtime_dir/caddy" "$tor_state_dir"

        if [[ "$action" == "start" ]]; then
          : > "$caddy_file"
          : > "$tor_file"

          ${lib.optionalString (cfg.transport == "tailscale" && anyTlsExposure && (
            (vaultwardenCluster && vaultwardenCfg.expose.tailscale.enable && vaultwardenCfg.expose.tailscale.tls)
            || (forgejoCluster && forgejoCfg.expose.tailscale.enable && forgejoCfg.expose.tailscale.tls)
          )) ''
            ts_ip="$(${config.services.tailscale.package}/bin/tailscale ip -4 | head -n1)"
            if [[ -z "$ts_ip" ]]; then
              echo "failed to determine Tailscale IPv4 address" >&2
              exit 1
            fi
          ''}

          ${lib.optionalString (vaultwardenCluster && vaultwardenCfg.expose.tailscale.enable && vaultwardenCfg.expose.tailscale.tls) ''
            cat >> "$caddy_file" <<EOF
            https://${vaultwardenTailscaleTlsName}:${toString vaultwardenCfg.expose.tailscale.port} {
              bind $ts_ip
              tls internal
              reverse_proxy ${normalizeLocalAddress vaultwardenCfg.listenAddress}:${toString vaultwardenCfg.port}
            }

            EOF
          ''}

          ${lib.optionalString (vaultwardenCluster && vaultwardenCfg.expose.wireguard.enable && vaultwardenCfg.expose.wireguard.tls) ''
            cat >> "$caddy_file" <<EOF
            https://${vaultwardenWireguardAddress}:${toString vaultwardenCfg.expose.wireguard.port} {
              bind ${vaultwardenWireguardAddress}
              tls internal
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

          ${lib.optionalString (forgejoCluster && forgejoCfg.expose.tailscale.enable && forgejoCfg.expose.tailscale.tls) ''
            cat >> "$caddy_file" <<EOF
            https://${forgejoTailscaleTlsName}:${toString forgejoCfg.expose.tailscale.port} {
              bind $ts_ip
              tls internal
              reverse_proxy ${normalizeLocalAddress forgejoCfg.listenAddress}:${toString forgejoCfg.port}
            }

            EOF
          ''}

          ${lib.optionalString (forgejoCluster && forgejoCfg.expose.wireguard.enable && forgejoCfg.expose.wireguard.tls) ''
            cat >> "$caddy_file" <<EOF
            https://${forgejoWireguardAddress}:${toString forgejoCfg.expose.wireguard.port} {
              bind ${forgejoWireguardAddress}
              tls internal
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

          ${lib.optionalString anyTlsExposure ''
            systemctl start caddy.service
            systemctl reload caddy.service
          ''}

          ${lib.optionalString anyTorExposure ''
            systemctl start tor.service
            systemctl reload tor.service
          ''}
        else
          : > "$caddy_file"
          : > "$tor_file"
          rm -rf "$tor_state_dir/vaultwarden"
          rm -rf "$tor_state_dir/forgejo"

          ${lib.optionalString anyTlsExposure ''
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
          ++ serviceExposure.mkAssertions {
            inherit config;
            optionPrefix = "alanix.cluster.dashboard.expose";
            endpoint = dashboardEndpoint;
            exposeCfg = dashboardCfg.expose;
          };

        systemd.targets."alanix-cluster-active" = {
          description = "Alanix cluster active target";
        };

        system.activationScripts.alanixClusterTor = lib.mkIf anyTorExposure ''
          mkdir -p /var/lib/tor/alanix-cluster
          chown root:tor /var/lib/tor/alanix-cluster
          chmod 0750 /var/lib/tor/alanix-cluster
          if [ ! -e /var/lib/tor/alanix-cluster/cluster.conf ]; then
            touch /var/lib/tor/alanix-cluster/cluster.conf
          fi
          chown root:tor /var/lib/tor/alanix-cluster/cluster.conf
          chmod 0640 /var/lib/tor/alanix-cluster/cluster.conf
        '';

        systemd.services."alanix-cluster-controller" = {
          description = "Alanix cluster controller";
          wantedBy = [ "multi-user.target" ];
          after =
            [ "network-online.target" "sops-nix.service" ]
            ++ lib.optional (cfg.transport == "tailscale") "tailscaled.service"
            ++ lib.optional isVoter "etcd.service";
          wants =
            [ "network-online.target" "sops-nix.service" ]
            ++ lib.optional (cfg.transport == "tailscale") "tailscaled.service"
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
          ];
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
          ++ lib.optionals forgejoCluster [
            "d ${forgejoCfg.backupDir} 0750 forgejo ${backupRepoUserGroup} - -"
          ]
          ++ lib.optionals anyTlsExposure [
            "d /run/alanix-cluster 0755 root root - -"
            "d /run/alanix-cluster/caddy 0755 root root - -"
            "f /run/alanix-cluster/caddy/cluster.caddy 0644 root root - -"
          ]
          ++ lib.optionals anyTorExposure [
            "d /var/lib/tor/alanix-cluster 0750 root tor - -"
            "f /var/lib/tor/alanix-cluster/cluster.conf 0640 root tor - -"
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

      (lib.mkIf anyTlsExposure {
        services.caddy.enable = true;
        services.caddy.extraConfig = lib.mkAfter ''
          import /run/alanix-cluster/caddy/cluster.caddy
        '';
      })

      (lib.mkIf anyTorExposure {
        services.tor.enable = true;
        services.tor.settings."%include" = "/var/lib/tor/alanix-cluster/cluster.conf";
      })

      (lib.mkIf (anyTlsExposure || anyTorExposure) {
        systemd.services."alanix-cluster-exposure" = {
          description = "Alanix cluster runtime exposure manager";
          wantedBy = [ "alanix-cluster-active.target" ];
          partOf = [ "alanix-cluster-active.target" ];
          after =
            lib.optionals vaultwardenCluster [ "vaultwarden.service" ]
            ++ lib.optionals forgejoCluster [ "forgejo.service" ];
          wants =
            lib.optionals vaultwardenCluster [ "vaultwarden.service" ]
            ++ lib.optionals forgejoCluster [ "forgejo.service" ];
          path =
            [ pkgs.coreutils pkgs.systemd ]
            ++ lib.optionals anyTlsExposure [ config.services.caddy.package ]
            ++ lib.optionals (cfg.transport == "tailscale") [ config.services.tailscale.package ];
          script = "${exposureScript} start";
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStop = "${exposureScript} stop";
          };
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
    ]
  );
}
