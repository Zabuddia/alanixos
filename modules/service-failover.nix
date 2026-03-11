{ config, lib, pkgs, hostname, ... }:
let
  cluster = config.alanix.cluster;
  etcdCfg = cluster.controlPlane.etcd;
  cfg = config.alanix.serviceFailover;
  enabledInstances = lib.filterAttrs (_: inst: inst.enable) cfg.instances;

  sortNodeNames = nodes:
    lib.sort
      (a: b:
        let
          aPriority = nodes.${a}.priority;
          bPriority = nodes.${b}.priority;
        in
        if aPriority == bPriority then a < b else aPriority < bPriority)
      (builtins.attrNames nodes);

  indexOf = needle: list:
    let
      go = idx: xs:
        if xs == [] then 0
        else if builtins.head xs == needle then idx
        else go (idx + 1) (builtins.tail xs);
    in
    go 0 list;

  mkInstance = name: inst:
    let
      localNodeName = inst.nodeName;
      nodes = inst.nodes;
      localNode = nodes.${localNodeName} or null;
      orderedNodeNames = sortNodeNames nodes;
      localPriority = if localNode == null then 0 else localNode.priority;
      localRank = if localNode == null then 0 else indexOf localNodeName orderedNodeNames;
      localClusterAddress = if localNode == null then "" else localNode.clusterAddress;
      localSshTarget = if localNode == null then "" else localNode.sshTarget;
      serviceUnits =
        [ inst.serviceUnit ]
        ++ lib.optional (inst.edgeUnit != null) inst.edgeUnit;
      serviceUnitsEscaped = lib.concatStringsSep " " (map lib.escapeShellArg serviceUnits);
      syncPathsEscaped = lib.concatStringsSep " " (map lib.escapeShellArg inst.sync.paths);
    in
    {
      inherit
        name
        inst
        localNodeName
        localPriority
        localRank
        localClusterAddress
        localSshTarget
        serviceUnitsEscaped
        syncPathsEscaped
        ;
      leaderInfoKey = "/alanix/failover/${name}/leader";
      lockName = "/alanix/failover/${name}/lock";
      campaignDelaySeconds = inst.campaignDelayStepSeconds * localRank;
    };

  instances = lib.mapAttrs mkInstance enabledInstances;

  syncFirewallOpen = lib.any
    (v: v.inst.sync.enable && v.inst.sync.openFirewallOnClusterInterface)
    (builtins.attrValues instances);

  syncFirewallInterfaces = lib.unique (
    lib.flatten (lib.mapAttrsToList (_: v:
      lib.optional (v.inst.sync.enable && v.inst.sync.openFirewallOnClusterInterface)
        v.inst.sync.firewallInterface
    ) instances)
  );

  rootAuthorizedSyncKeys = lib.unique (
    lib.flatten (lib.mapAttrsToList (_: v:
      lib.optional (v.inst.sync.enable && v.inst.sync.authorizedPublicKey != null)
        "from=\"${lib.concatStringsSep "," v.inst.sync.authorizedSourcePatterns}\" ${v.inst.sync.authorizedPublicKey}"
    ) instances)
  );

  dnsUpdaterDefs = builtins.listToAttrs (lib.flatten (lib.mapAttrsToList (_: v:
    lib.optional v.inst.dns.enable {
      name = v.inst.dns.jobName;
      value = {
        enable = true;
        provider = v.inst.dns.provider;
        zone = v.inst.dns.zone;
        records = [ v.inst.dns.record ];
        tokenSecret = v.inst.dns.tokenSecret;
        interval = v.inst.dns.interval;
        startupDelay = "45s";
        proxied = v.inst.dns.proxied;
        ttl = v.inst.dns.ttl;
        runOnlyWhenPathExists = v.inst.activeMarkerPath;
      };
    }
  ) instances));

  syncServices = builtins.listToAttrs (lib.flatten (lib.mapAttrsToList (_: v:
    lib.optional v.inst.sync.enable {
      name = "${v.name}-sync";
      value = {
        description = "Sync ${v.name} standby data from the current etcd-elected leader";
        after = [ "network-online.target" "etcd.service" "sops-install-secrets.service" ];
        wants = [ "network-online.target" "etcd.service" "sops-install-secrets.service" ];
        path = [
          config.services.etcd.package
          pkgs.coreutils
          pkgs.openssh
          pkgs.rsync
        ];
        serviceConfig = {
          Type = "oneshot";
          User = "root";
          Group = "root";
          ExecStart = pkgs.writeShellScript "alanix-${v.name}-sync" ''
            set -euo pipefail

            STATE_DIR=${lib.escapeShellArg v.inst.stateDir}
            ACTIVE_MARKER=${lib.escapeShellArg v.inst.activeMarkerPath}
            KNOWN_HOSTS="$STATE_DIR/known_hosts"
            ETCD_ENDPOINT=${lib.escapeShellArg "http://127.0.0.1:${toString etcdCfg.clientPort}"}
            LEADER_INFO_KEY=${lib.escapeShellArg v.leaderInfoKey}
            LOCAL_NODE_NAME=${lib.escapeShellArg v.localNodeName}
            LEADER_INFO_STALE_SECONDS=${toString v.inst.leaderInfoStaleSeconds}
            SSH_KEY=${lib.escapeShellArg config.sops.secrets.${v.inst.sync.sshKeySecret}.path}
            SYNC_PATHS=(${v.syncPathsEscaped})

            mkdir -p "$STATE_DIR"

            etcdctl_quick() {
              etcdctl --endpoints "$ETCD_ENDPOINT" --dial-timeout=3s --command-timeout=8s "$@"
            }

            wait_for_local_etcd() {
              local tries=0
              while [ "$tries" -lt 12 ]; do
                if etcdctl_quick endpoint health >/dev/null 2>&1; then
                  return 0
                fi
                tries=$((tries + 1))
                sleep 5
              done
              return 1
            }

            read_leader_value() {
              etcdctl_quick get "$LEADER_INFO_KEY" --print-value-only 2>/dev/null || true
            }

            leader_value_is_fresh() {
              local value="$1"
              local leader_name leader_priority leader_address leader_target leader_timestamp now age

              [ -n "$value" ] || return 1
              IFS='|' read -r leader_name leader_priority leader_address leader_target leader_timestamp <<< "$value"
              [ -n "$leader_timestamp" ] || return 1
              case "$leader_timestamp" in
                ""|*[!0-9]*) return 1 ;;
              esac

              now="$(date +%s)"
              age=$((now - leader_timestamp))
              if [ "$age" -lt 0 ]; then
                age=0
              fi

              [ "$age" -le "$LEADER_INFO_STALE_SECONDS" ]
            }

            ssh_cmd() {
              ssh -i "$SSH_KEY" \
                -o IdentitiesOnly=yes \
                -o BatchMode=yes \
                -o ConnectTimeout=8 \
                -o StrictHostKeyChecking=accept-new \
                -o UserKnownHostsFile="$KNOWN_HOSTS" \
                "$@"
            }

            sync_from_target() {
              local target="$1"
              local rsync_ssh
              rsync_ssh="ssh -i $SSH_KEY -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$KNOWN_HOSTS"

              for p in "''${SYNC_PATHS[@]}"; do
                mkdir -p "$p"
                rsync -aHAX --delete -e "$rsync_ssh" "$target:$p/" "$p/"
              done
            }

            [ -f "$ACTIVE_MARKER" ] && exit 0
            wait_for_local_etcd || exit 0

            leader_value="$(read_leader_value)"
            if ! leader_value_is_fresh "$leader_value"; then
              echo "No fresh leader metadata found for ${v.name} sync; skipping" >&2
              exit 0
            fi

            IFS='|' read -r leader_name _leader_priority _leader_address leader_target _leader_timestamp <<< "$leader_value"
            [ "$leader_name" = "$LOCAL_NODE_NAME" ] && exit 0

            if ssh_cmd "$leader_target" "true" >/dev/null 2>&1; then
              sync_from_target "$leader_target"
              exit 0
            fi

            echo "Leader ${v.name} sync target is unreachable: $leader_target" >&2
            exit 0
          '';
        };
      };
    }
  ) instances));

  syncTimers = builtins.listToAttrs (lib.flatten (lib.mapAttrsToList (_: v:
    lib.optional v.inst.sync.enable {
      name = "${v.name}-sync";
      value = {
        description = "Periodic ${v.name} standby sync";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "45s";
          OnUnitActiveSec = v.inst.sync.interval;
          Unit = "${v.name}-sync.service";
        };
      };
    }
  ) instances));

  roleServices = builtins.listToAttrs (lib.mapAttrsToList (_: v: {
    name = "${v.name}-role-controller";
    value = {
      description = "${v.name} role controller (etcd leader lock, automatic failover, manual failback)";
      after = [ "network-online.target" "etcd.service" ] ++ lib.optional v.inst.sync.enable "sops-install-secrets.service";
      wants = [ "network-online.target" "etcd.service" ] ++ lib.optional v.inst.sync.enable "sops-install-secrets.service";
      requires = [ "etcd.service" ];
      path = [
        config.services.etcd.package
        pkgs.coreutils
        pkgs.openssh
        pkgs.rsync
        pkgs.systemd
      ];
      serviceConfig = {
        Type = "simple";
        User = "root";
        Group = "root";
        Restart = "always";
        RestartSec = "5s";
        ExecStart = pkgs.writeShellScript "alanix-${v.name}-role-controller" ''
          set -euo pipefail

          STATE_DIR=${lib.escapeShellArg v.inst.stateDir}
          ACTIVE_MARKER=${lib.escapeShellArg v.inst.activeMarkerPath}
          KNOWN_HOSTS="$STATE_DIR/known_hosts"
          ETCD_ENDPOINT=${lib.escapeShellArg "http://127.0.0.1:${toString etcdCfg.clientPort}"}
          LEADER_INFO_KEY=${lib.escapeShellArg v.leaderInfoKey}
          LOCK_NAME=${lib.escapeShellArg v.lockName}
          CHECK_INTERVAL=${lib.escapeShellArg v.inst.checkInterval}
          LOCK_TTL_SECONDS=${toString v.inst.lockTtlSeconds}
          LEADER_INFO_STALE_SECONDS=${toString v.inst.leaderInfoStaleSeconds}
          FAILURE_THRESHOLD=${toString v.inst.failureThreshold}
          CAMPAIGN_DELAY_SECONDS=${toString v.campaignDelaySeconds}

          SERVICE_UNITS=(${v.serviceUnitsEscaped})
          SERVICE_UNIT=${lib.escapeShellArg v.inst.serviceUnit}
          LOCAL_NODE_NAME=${lib.escapeShellArg v.localNodeName}
          LOCAL_LEADER_PREFIX=${lib.escapeShellArg "${v.localNodeName}|${toString v.localPriority}|${v.localClusterAddress}|${v.localSshTarget}"}

          ${lib.optionalString v.inst.sync.enable ''
            SSH_KEY=${lib.escapeShellArg config.sops.secrets.${v.inst.sync.sshKeySecret}.path}
            SYNC_PATHS=(${v.syncPathsEscaped})
          ''}

          mkdir -p "$STATE_DIR"

          LOCK_PID=""

          etcdctl_quick() {
            etcdctl --endpoints "$ETCD_ENDPOINT" --dial-timeout=3s --command-timeout=8s "$@"
          }

          read_leader_value() {
            etcdctl_quick get "$LEADER_INFO_KEY" --print-value-only 2>/dev/null || true
          }

          parse_leader_value() {
            local value="$1"
            leader_name=""
            leader_priority=""
            leader_address=""
            leader_target=""
            leader_timestamp=""
            IFS='|' read -r leader_name leader_priority leader_address leader_target leader_timestamp <<< "$value"
          }

          leader_value_is_fresh() {
            local value="$1"
            local now age

            [ -n "$value" ] || return 1
            parse_leader_value "$value"
            [ -n "$leader_timestamp" ] || return 1
            case "$leader_timestamp" in
              ""|*[!0-9]*) return 1 ;;
            esac

            now="$(date +%s)"
            age=$((now - leader_timestamp))
            if [ "$age" -lt 0 ]; then
              age=0
            fi

            [ "$age" -le "$LEADER_INFO_STALE_SECONDS" ]
          }

          fresh_remote_leader_present() {
            local value
            value="$(read_leader_value)"
            if ! leader_value_is_fresh "$value"; then
              return 1
            fi
            [ "$leader_name" != "$LOCAL_NODE_NAME" ]
          }

          stop_local() {
            for unit in "''${SERVICE_UNITS[@]}"; do
              systemctl stop "$unit" || true
            done
            rm -f "$ACTIVE_MARKER"
          }

          wait_for_local_etcd() {
            until etcdctl_quick endpoint health >/dev/null 2>&1; do
              stop_local
              sleep "$CHECK_INTERVAL"
            done
          }

          release_lock() {
            if [ -n "$LOCK_PID" ]; then
              kill "$LOCK_PID" >/dev/null 2>&1 || true
              wait "$LOCK_PID" >/dev/null 2>&1 || true
              LOCK_PID=""
            fi
          }

          delete_local_leader_info() {
            local value
            value="$(read_leader_value)"
            if leader_value_is_fresh "$value" && [ "$leader_name" = "$LOCAL_NODE_NAME" ]; then
              etcdctl_quick del "$LEADER_INFO_KEY" >/dev/null 2>&1 || true
            fi
          }

          cleanup_local() {
            stop_local
            delete_local_leader_info
            release_lock
          }

          trap 'cleanup_local' EXIT INT TERM

          start_local() {
            touch "$ACTIVE_MARKER"

            systemctl start "$SERVICE_UNIT"
            if ! systemctl -q is-active "$SERVICE_UNIT"; then
              rm -f "$ACTIVE_MARKER"
              return 1
            fi

            for unit in "''${SERVICE_UNITS[@]}"; do
              if [ "$unit" != "$SERVICE_UNIT" ]; then
                systemctl start "$unit"
                if ! systemctl -q is-active "$unit"; then
                  rm -f "$ACTIVE_MARKER"
                  return 1
                fi
              fi
            done

            ${lib.optionalString v.inst.dns.enable ''
              systemctl start alanix-dns-updater-${v.inst.dns.jobName}.service || true
            ''}
          }

          local_is_serving() {
            for unit in "''${SERVICE_UNITS[@]}"; do
              systemctl -q is-active "$unit" || return 1
            done
            return 0
          }

          publish_leader_info() {
            local now
            now="$(date +%s)"
            etcdctl_quick put "$LEADER_INFO_KEY" "$LOCAL_LEADER_PREFIX|$now" >/dev/null
          }

          ${if v.inst.sync.enable then ''
            ssh_cmd() {
              ssh -i "$SSH_KEY" \
                -o IdentitiesOnly=yes \
                -o BatchMode=yes \
                -o ConnectTimeout=8 \
                -o StrictHostKeyChecking=accept-new \
                -o UserKnownHostsFile="$KNOWN_HOSTS" \
                "$@"
            }

            sync_from_target() {
              local target="$1"
              local rsync_ssh
              rsync_ssh="ssh -i $SSH_KEY -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$KNOWN_HOSTS"

              for p in "''${SYNC_PATHS[@]}"; do
                mkdir -p "$p"
                rsync -aHAX --delete -e "$rsync_ssh" "$target:$p/" "$p/"
              done
            }

            maybe_sync_from_previous_leader() {
              local value="$1"

              if ! leader_value_is_fresh "$value"; then
                return 0
              fi

              if [ "$leader_name" = "$LOCAL_NODE_NAME" ]; then
                return 0
              fi

              if ssh_cmd "$leader_target" "true" >/dev/null 2>&1; then
                sync_from_target "$leader_target" || echo "${v.name} failover: best-effort pre-start sync from $leader_target failed" >&2
              fi
            }
          '' else ''
            maybe_sync_from_previous_leader() {
              return 0
            }
          ''}

          wait_for_lock_acquisition() {
            local lock_output="$STATE_DIR/lock.out"

            : > "$lock_output"
            etcdctl --endpoints "$ETCD_ENDPOINT" --dial-timeout=3s lock "$LOCK_NAME" --ttl="$LOCK_TTL_SECONDS" >"$lock_output" 2>&1 &
            LOCK_PID=$!

            while true; do
              if ! kill -0 "$LOCK_PID" >/dev/null 2>&1; then
                wait "$LOCK_PID" >/dev/null 2>&1 || true
                LOCK_PID=""
                return 1
              fi

              if [ -s "$lock_output" ]; then
                return 0
              fi

              if fresh_remote_leader_present; then
                release_lock
                return 1
              fi

              sleep 1
            done
          }

          maybe_delay_for_preference() {
            local remaining="$CAMPAIGN_DELAY_SECONDS"

            while [ "$remaining" -gt 0 ]; do
              if fresh_remote_leader_present; then
                return 1
              fi
              sleep 1
              remaining=$((remaining - 1))
            done

            return 0
          }

          while true; do
            wait_for_local_etcd

            if fresh_remote_leader_present; then
              stop_local
              sleep "$CHECK_INTERVAL"
              continue
            fi

            if ! maybe_delay_for_preference; then
              stop_local
              sleep "$CHECK_INTERVAL"
              continue
            fi

            previous_leader_value="$(read_leader_value)"

            if ! wait_for_lock_acquisition; then
              sleep "$CHECK_INTERVAL"
              continue
            fi

            maybe_sync_from_previous_leader "$previous_leader_value"

            if ! start_local; then
              cleanup_local
              sleep "$CHECK_INTERVAL"
              continue
            fi

            etcd_failures=0
            service_failures=0

            while true; do
              if ! kill -0 "$LOCK_PID" >/dev/null 2>&1; then
                echo "${v.name} failover: leadership lock process exited" >&2
                break
              fi

              if etcdctl_quick endpoint health >/dev/null 2>&1; then
                etcd_failures=0
              else
                etcd_failures=$((etcd_failures + 1))
                if [ "$etcd_failures" -ge "$FAILURE_THRESHOLD" ]; then
                  echo "${v.name} failover: local etcd unhealthy, relinquishing leadership" >&2
                  break
                fi
              fi

              if local_is_serving; then
                service_failures=0
              else
                service_failures=$((service_failures + 1))
                if [ "$service_failures" -ge "$FAILURE_THRESHOLD" ]; then
                  echo "${v.name} failover: local service failed health checks" >&2
                  break
                fi
              fi

              if publish_leader_info; then
                etcd_failures=0
              else
                etcd_failures=$((etcd_failures + 1))
                if [ "$etcd_failures" -ge "$FAILURE_THRESHOLD" ]; then
                  echo "${v.name} failover: unable to publish leader metadata" >&2
                  break
                fi
              fi

              sleep "$CHECK_INTERVAL"
            done

            cleanup_local
            sleep "$CHECK_INTERVAL"
          done
        '';
      };
    };
  }) instances);
in
{
  imports = [ ./dns-updaters.nix ];

  options.alanix.serviceFailover = {
    instances = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({ name, config, ... }: {
        options = {
          enable = lib.mkEnableOption "Failover controller for ${name}";

          nodeName = lib.mkOption {
            type = lib.types.str;
            default = hostname;
            description = "Local node name; must match a key in nodes.";
          };

          serviceUnit = lib.mkOption {
            type = lib.types.str;
            default = "${name}.service";
            description = "Primary service unit controlled by this role controller.";
          };

          edgeUnit = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Optional second service unit to start/stop with the primary unit.";
          };

          stateDir = lib.mkOption {
            type = lib.types.str;
            default = "/var/lib/alanix-${name}-failover";
          };

          activeMarkerPath = lib.mkOption {
            type = lib.types.str;
            default = "/run/alanix-${name}-failover/active";
            description = "Ephemeral marker file indicating this node currently owns active role.";
          };

          activeDetectionFallbackPort = lib.mkOption {
            type = lib.types.nullOr lib.types.port;
            default = null;
            description = "Legacy no-op option kept for compatibility with older failover definitions.";
          };

          checkInterval = lib.mkOption {
            type = lib.types.str;
            default = "15s";
            description = "Leadership controller loop interval.";
          };

          failureThreshold = lib.mkOption {
            type = lib.types.ints.positive;
            default = 4;
            description = "Consecutive unhealthy leadership checks before a local active node relinquishes control.";
          };

          higherUnhealthyThreshold = lib.mkOption {
            type = lib.types.ints.positive;
            default = 20;
            description = "Legacy no-op option kept for compatibility with older role-controller settings.";
          };

          campaignDelayStepSeconds = lib.mkOption {
            type = lib.types.ints.unsigned;
            default = 20;
            description = ''
              Extra delay, in seconds, added per priority rank before this node
              campaigns for leadership. Lower-priority nodes wait longer, so the
              preferred node wins initial placement without automatic failback.
            '';
          };

          leaderInfoStaleSeconds = lib.mkOption {
            type = lib.types.ints.positive;
            default = 45;
            description = "How old leader metadata may be before standbys ignore it and begin campaigning.";
          };

          lockTtlSeconds = lib.mkOption {
            type = lib.types.ints.positive;
            default = 30;
            description = "etcd lock session TTL for this failover instance.";
          };

          requireServiceEnableOptionPath = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [];
            description = "Optional config path that must evaluate to true when this failover instance is enabled.";
          };

          nodes = lib.mkOption {
            type = lib.types.attrsOf (lib.types.submodule ({ config, ... }: {
              options = {
                priority = lib.mkOption {
                  type = lib.types.int;
                  description = "Lower value means preferred active node.";
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
            description = "All nodes participating in this failover service.";
          };

          sync = {
            enable = lib.mkEnableOption "Periodic standby sync via rsync over SSH";

            interval = lib.mkOption {
              type = lib.types.str;
              default = "2min";
            };

            paths = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ "/var/lib/${name}" ];
            };

            sshKeySecret = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "sops secret containing SSH private key used for rsync/control.";
            };

            authorizedPublicKey = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Public key allowed for root SSH from cluster peers.";
            };

            authorizedSourcePatterns = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "SSH source patterns allowed to use the sync key for root access.";
            };

            firewallInterface = lib.mkOption {
              type = lib.types.str;
              default = "tailscale0";
              description = "Firewall interface used for private cluster sync/control traffic.";
            };

            openFirewallOnClusterInterface = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Open SSH on the private cluster interface to allow sync/control traffic.";
            };
          };

          dns = {
            enable = lib.mkEnableOption "DNS update while this node is active";

            jobName = lib.mkOption {
              type = lib.types.str;
              default = "${name}-failover";
              description = "alanix.dnsUpdaters job name used for this service failover record.";
            };

            provider = lib.mkOption {
              type = lib.types.enum [ "cloudflare" ];
              default = "cloudflare";
              description = "DNS provider backend for active record updates.";
            };

            interval = lib.mkOption {
              type = lib.types.str;
              default = "2min";
            };

            zone = lib.mkOption {
              type = lib.types.str;
            };

            record = lib.mkOption {
              type = lib.types.str;
            };

            tokenSecret = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
            };

            proxied = lib.mkOption {
              type = lib.types.bool;
              default = false;
            };

            ttl = lib.mkOption {
              type = lib.types.ints.unsigned;
              default = 60;
            };
          };
        };
      }));
      default = {};
      description = "Declarative failover instances keyed by service name.";
    };
  };

  config = lib.mkIf (enabledInstances != {}) {
    assertions =
      lib.flatten (lib.mapAttrsToList (name: v:
        let
          path = v.inst.requireServiceEnableOptionPath;
          serviceEnabled = if path == [] then true else lib.attrByPath path false config;
        in
        [
          {
            assertion = v.inst.nodes != {};
            message = "alanix.serviceFailover.instances.${name}.nodes must not be empty.";
          }
          {
            assertion = builtins.hasAttr v.inst.nodeName v.inst.nodes;
            message = "alanix.serviceFailover.instances.${name}.nodeName '${v.inst.nodeName}' is not present in nodes.";
          }
          {
            assertion = path == [] || serviceEnabled;
            message = "alanix.serviceFailover.instances.${name} requires ${lib.concatStringsSep "." path} = true.";
          }
        ]
        ++ lib.optional v.inst.sync.enable {
          assertion = v.inst.sync.sshKeySecret != null;
          message = "alanix.serviceFailover.instances.${name}.sync.sshKeySecret must be set when sync is enabled.";
        }
        ++ lib.optional v.inst.sync.enable {
          assertion = v.inst.sync.authorizedPublicKey != null;
          message = "alanix.serviceFailover.instances.${name}.sync.authorizedPublicKey must be set when sync is enabled.";
        }
        ++ lib.optional v.inst.sync.enable {
          assertion = v.inst.sync.authorizedSourcePatterns != [ ];
          message = "alanix.serviceFailover.instances.${name}.sync.authorizedSourcePatterns must not be empty when sync is enabled.";
        }
        ++ lib.optional v.inst.dns.enable {
          assertion = v.inst.dns.tokenSecret != null;
          message = "alanix.serviceFailover.instances.${name}.dns.tokenSecret must be set when dns is enabled.";
        }
      ) instances);

    systemd.tmpfiles.rules = lib.flatten (lib.mapAttrsToList (_: v: [
      "d ${v.inst.stateDir} 0700 root root - -"
      "d ${builtins.dirOf v.inst.activeMarkerPath} 0755 root root - -"
    ]) instances);

    environment.systemPackages = [
      pkgs.rsync
      (pkgs.writeShellApplication {
        name = "alanix-failover-status";
        runtimeInputs = [ config.services.etcd.package pkgs.coreutils ];
        text = ''
          endpoint="http://127.0.0.1:${toString etcdCfg.clientPort}"

          if ! etcdctl --endpoints "$endpoint" --dial-timeout=3s --command-timeout=8s endpoint health >/dev/null 2>&1; then
            echo "Local etcd endpoint is not healthy at $endpoint" >&2
            exit 1
          fi

          prefix="/alanix/failover/"
          while IFS= read -r key; do
            value="$(etcdctl --endpoints "$endpoint" --dial-timeout=3s --command-timeout=8s get "$key" --print-value-only 2>/dev/null || true)"
            [ -n "$value" ] || continue
            printf '%s -> %s\n' "$key" "$value"
          done < <(etcdctl --endpoints "$endpoint" --dial-timeout=3s --command-timeout=8s get "$prefix" --prefix --keys-only --print-value-only 2>/dev/null | sort -u)
        '';
      })
    ];

    networking.firewall.interfaces =
      lib.mkIf syncFirewallOpen
        (builtins.listToAttrs (map
          (iface: {
            name = iface;
            value.allowedTCPPorts = [ 22 ];
          })
          syncFirewallInterfaces));

    users.users.root.openssh.authorizedKeys.keys =
      lib.mkIf (rootAuthorizedSyncKeys != []) rootAuthorizedSyncKeys;

    alanix.dnsUpdaters = dnsUpdaterDefs;

    systemd.services = syncServices // roleServices;
    systemd.timers = syncTimers;
  };
}
