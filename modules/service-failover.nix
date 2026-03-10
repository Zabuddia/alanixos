{ config, lib, pkgs, hostname, ... }:
let
  cfg = config.alanix.serviceFailover;
  enabledInstances = lib.filterAttrs (_: inst: inst.enable) cfg.instances;

  mkNodeTuple = nodes: name: "${name}|${nodes.${name}.vpnIP}|${nodes.${name}.sshTarget}";

  mkInstance = name: inst:
    let
      localNodeName = inst.nodeName;
      nodes = inst.nodes;
      localNode = nodes.${localNodeName} or null;
      localPriority = if localNode == null then 0 else localNode.priority;

      orderedNodeNames =
        lib.sort (a: b: nodes.${a}.priority < nodes.${b}.priority) (builtins.attrNames nodes);

      higherNodeNames = lib.filter (n: nodes.${n}.priority < localPriority) orderedNodeNames;
      lowerNodeNames = lib.filter (n: nodes.${n}.priority > localPriority) orderedNodeNames;
      remoteNodeNames = lib.filter (n: n != localNodeName) orderedNodeNames;

      higherNodeTuples = map (mkNodeTuple nodes) higherNodeNames;
      lowerNodeTuples = map (mkNodeTuple nodes) lowerNodeNames;
      remoteNodeTuples = map (mkNodeTuple nodes) remoteNodeNames;

      serviceUnits =
        [ inst.serviceUnit ]
        ++ lib.optional (inst.edgeUnit != null) inst.edgeUnit;
      serviceUnitsEscaped = lib.concatStringsSep " " (map lib.escapeShellArg serviceUnits);
      unitChecksExpr = lib.concatStringsSep " && "
        ([ "test -f '$ACTIVE_MARKER'" ] ++ map (u: "systemctl -q is-active ${u}") serviceUnits);

      syncPathsEscaped = lib.concatStringsSep " " (map lib.escapeShellArg inst.sync.paths);
    in
    {
      inherit name inst higherNodeTuples lowerNodeTuples remoteNodeTuples serviceUnitsEscaped unitChecksExpr syncPathsEscaped;
    };

  instances = lib.mapAttrs mkInstance enabledInstances;

  syncFirewallOpen = lib.any
    (v: v.inst.sync.enable && v.inst.sync.openFirewallOnWg)
    (builtins.attrValues instances);

  rootAuthorizedSyncKeys = lib.unique (
    lib.flatten (lib.mapAttrsToList (_: v:
      lib.optional (v.inst.sync.enable && v.inst.sync.authorizedPublicKey != null)
        "from=\"${v.inst.sync.allowedFromCIDR}\" ${v.inst.sync.authorizedPublicKey}"
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
        description = "Sync ${v.name} data from currently active node";
        after = [ "network-online.target" "sops-install-secrets.service" ];
        wants = [ "network-online.target" "sops-install-secrets.service" ];
        serviceConfig = {
          Type = "oneshot";
          User = "root";
          Group = "root";
        };
        path = [ pkgs.rsync pkgs.openssh pkgs.coreutils pkgs.iputils pkgs.netcat-openbsd ];
        script = ''
          set -euo pipefail

          STATE_DIR=${lib.escapeShellArg v.inst.stateDir}
          ACTIVE_MARKER=${lib.escapeShellArg v.inst.activeMarkerPath}
          FALLBACK_PORT=${if v.inst.activeDetectionFallbackPort == null then "\"\"" else toString v.inst.activeDetectionFallbackPort}
          KNOWN_HOSTS="$STATE_DIR/known_hosts"
          SSH_KEY=${lib.escapeShellArg config.sops.secrets.${v.inst.sync.sshKeySecret}.path}
          SYNC_PATHS=(${v.syncPathsEscaped})

          REMOTE_NODES=()
          ${lib.concatStringsSep "\n" (map (tuple: ''REMOTE_NODES+=(${lib.escapeShellArg tuple})'') v.remoteNodeTuples)}

          [ -f "$ACTIVE_MARKER" ] && exit 0

          ssh_cmd() {
            ssh -i "$SSH_KEY" \
              -o IdentitiesOnly=yes \
              -o BatchMode=yes \
              -o ConnectTimeout=8 \
              -o StrictHostKeyChecking=accept-new \
              -o UserKnownHostsFile="$KNOWN_HOSTS" \
              "$@"
          }

          node_is_active() {
            local ip="$1"
            local target="$2"
            if ssh_cmd "$target" "true" >/dev/null 2>&1; then
              ssh_cmd "$target" "${v.unitChecksExpr}" >/dev/null 2>&1
              return $?
            fi

            if [ -n "$FALLBACK_PORT" ]; then
              ping -q -c1 -W2 "$ip" >/dev/null 2>&1 && nc -z -w2 "$ip" "$FALLBACK_PORT" >/dev/null 2>&1
              return $?
            fi

            return 1
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

          for node in "''${REMOTE_NODES[@]}"; do
            IFS='|' read -r _name ip ssh_target <<< "$node"
            if node_is_active "$ip" "$ssh_target"; then
              sync_from_target "$ssh_target"
              exit 0
            fi
          done

          echo "No active remote node detected for ${v.name} sync; skipping" >&2
          exit 0
        '';
      };
    }
  ) instances));

  syncTimers = builtins.listToAttrs (lib.flatten (lib.mapAttrsToList (_: v:
    lib.optional v.inst.sync.enable {
      name = "${v.name}-sync";
      value = {
        description = "Periodic ${v.name} sync";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "30s";
          OnUnitActiveSec = v.inst.sync.interval;
          Unit = "${v.name}-sync.service";
        };
      };
    }
  ) instances));

  roleServices = builtins.listToAttrs (lib.mapAttrsToList (_: v: {
    name = "${v.name}-role-controller";
    value = {
      description = "${v.name} role controller (auto failover + failback)";
      after = [ "network-online.target" ] ++ lib.optional v.inst.sync.enable "sops-install-secrets.service";
      wants = [ "network-online.target" ] ++ lib.optional v.inst.sync.enable "sops-install-secrets.service";
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        Group = "root";
      };
      path = [ pkgs.iputils pkgs.netcat-openbsd pkgs.systemd pkgs.coreutils pkgs.openssh pkgs.rsync ];
      script = ''
        set -euo pipefail

        STATE_DIR=${lib.escapeShellArg v.inst.stateDir}
        ACTIVE_MARKER=${lib.escapeShellArg v.inst.activeMarkerPath}
        FAIL_FILE="$STATE_DIR/fail-count"
        UNHEALTHY_FAIL_FILE="$STATE_DIR/higher-unhealthy-count"
        FALLBACK_PORT=${if v.inst.activeDetectionFallbackPort == null then "\"\"" else toString v.inst.activeDetectionFallbackPort}
        KNOWN_HOSTS="$STATE_DIR/known_hosts"

        SERVICE_UNITS=(${v.serviceUnitsEscaped})
        SERVICE_UNIT=${lib.escapeShellArg v.inst.serviceUnit}

        HIGHER_NODES=()
        ${lib.concatStringsSep "\n" (map (tuple: ''HIGHER_NODES+=(${lib.escapeShellArg tuple})'') v.higherNodeTuples)}

        LOWER_NODES=()
        ${lib.concatStringsSep "\n" (map (tuple: ''LOWER_NODES+=(${lib.escapeShellArg tuple})'') v.lowerNodeTuples)}

        mkdir -p "$STATE_DIR"

        ${if v.inst.sync.enable then ''
          SSH_KEY=${lib.escapeShellArg config.sops.secrets.${v.inst.sync.sshKeySecret}.path}
          SYNC_PATHS=(${v.syncPathsEscaped})

          ssh_cmd() {
            ssh -i "$SSH_KEY" \
              -o IdentitiesOnly=yes \
              -o BatchMode=yes \
              -o ConnectTimeout=8 \
              -o StrictHostKeyChecking=accept-new \
              -o UserKnownHostsFile="$KNOWN_HOSTS" \
              "$@"
          }

          node_reachable() {
            local ip="$1"
            local _target="$2"
            ping -q -c1 -W2 "$ip" >/dev/null 2>&1
          }

          node_is_active() {
            local ip="$1"
            local target="$2"
            if ssh_cmd "$target" "true" >/dev/null 2>&1; then
              ssh_cmd "$target" "${v.unitChecksExpr}" >/dev/null 2>&1
              return $?
            fi

            if [ -n "$FALLBACK_PORT" ]; then
              ping -q -c1 -W2 "$ip" >/dev/null 2>&1 && nc -z -w2 "$ip" "$FALLBACK_PORT" >/dev/null 2>&1
              return $?
            fi

            return 1
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

          # Return codes:
          # 0 = synced from an active lower-priority node
          # 1 = no active lower-priority node found (safe to continue)
          # 2 = active lower-priority node found but sync failed (block takeover)
          maybe_sync_from_active_lower() {
            for node in "''${LOWER_NODES[@]}"; do
              IFS='|' read -r _name ip ssh_target <<< "$node"
              if node_is_active "$ip" "$ssh_target"; then
                if sync_from_target "$ssh_target"; then
                  return 0
                fi
                echo "${v.name} failover: sync from active lower-priority node failed: $ssh_target" >&2
                return 2
              fi
            done
            return 1
          }
        '' else ''
          node_reachable() {
            local ip="$1"
            local _target="$2"
            ping -q -c1 -W2 "$ip" >/dev/null 2>&1
          }

          node_is_active() {
            local ip="$1"
            local _target="$2"
            if [ -n "$FALLBACK_PORT" ]; then
              ping -q -c1 -W2 "$ip" >/dev/null 2>&1 && nc -z -w2 "$ip" "$FALLBACK_PORT" >/dev/null 2>&1
              return $?
            fi
            return 1
          }

          maybe_sync_from_active_lower() {
            return 0
          }
        ''}

        stop_local() {
          for unit in "''${SERVICE_UNITS[@]}"; do
            systemctl stop "$unit" || true
          done
          rm -f "$ACTIVE_MARKER"
        }

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

        higher_healthy=0
        higher_reachable=0
        for node in "''${HIGHER_NODES[@]}"; do
          IFS='|' read -r _name ip ssh_target <<< "$node"
          if node_reachable "$ip" "$ssh_target"; then
            higher_reachable=1
          fi
          if node_is_active "$ip" "$ssh_target"; then
            higher_healthy=1
            break
          fi
        done

        if [ "$higher_healthy" -eq 1 ]; then
          echo 0 > "$FAIL_FILE"
          echo 0 > "$UNHEALTHY_FAIL_FILE"
          if [ -f "$ACTIVE_MARKER" ] || local_is_serving; then
            stop_local
          fi
          exit 0
        fi

        unreachable_count=0
        if [ -f "$FAIL_FILE" ]; then
          unreachable_count="$(cat "$FAIL_FILE" || echo 0)"
        fi

        if [ "$higher_reachable" -eq 1 ]; then
          echo 0 > "$FAIL_FILE"
          echo 0 > "$UNHEALTHY_FAIL_FILE"
          if [ -f "$ACTIVE_MARKER" ] || local_is_serving; then
            stop_local
          fi
          exit 0
        else
          echo 0 > "$UNHEALTHY_FAIL_FILE"
          unreachable_count=$((unreachable_count + 1))
          echo "$unreachable_count" > "$FAIL_FILE"

          if [ "$unreachable_count" -lt ${toString v.inst.failureThreshold} ]; then
            exit 0
          fi
        fi

        safe_sync_before_start() {
          local sync_result=0
          if maybe_sync_from_active_lower; then
            sync_result=0
          else
            sync_result=$?
          fi

          if [ "$sync_result" -eq 2 ]; then
            echo "${v.name} failover: sync from current active node failed; continuing takeover to avoid prolonged standby" >&2
            return 0
          fi

          return 0
        }

        if [ -f "$ACTIVE_MARKER" ]; then
          if ! local_is_serving; then
            safe_sync_before_start
            start_local
          fi
          exit 0
        fi

        safe_sync_before_start
        start_local
      '';
    };
  }) instances);

  roleTimers = builtins.listToAttrs (lib.mapAttrsToList (_: v: {
    name = "${v.name}-role-controller";
    value = {
      description = "${v.name} role control loop";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "20s";
        OnUnitActiveSec = v.inst.checkInterval;
        Unit = "${v.name}-role-controller.service";
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
            description = "Optional fallback TCP port check when SSH active check fails.";
          };

          checkInterval = lib.mkOption {
            type = lib.types.str;
            default = "15s";
          };

          failureThreshold = lib.mkOption {
            type = lib.types.ints.positive;
            default = 4;
            description = "Consecutive unreachable checks before local promotion.";
          };

          higherUnhealthyThreshold = lib.mkOption {
            type = lib.types.ints.positive;
            default = 20;
            description = "Consecutive unhealthy checks before promoting while higher-priority node is reachable.";
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

                vpnIP = lib.mkOption {
                  type = lib.types.str;
                };

                sshTarget = lib.mkOption {
                  type = lib.types.str;
                  default = "root@${config.vpnIP}";
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

            allowedFromCIDR = lib.mkOption {
              type = lib.types.str;
              default = "10.100.0.0/24";
            };

            openFirewallOnWg = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Open SSH on wg0 to allow sync/control traffic.";
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
      pkgs.netcat-openbsd
    ];

    networking.firewall.interfaces.wg0.allowedTCPPorts =
      lib.mkIf syncFirewallOpen [ 22 ];

    users.users.root.openssh.authorizedKeys.keys =
      lib.mkIf (rootAuthorizedSyncKeys != []) rootAuthorizedSyncKeys;

    alanix.dnsUpdaters = dnsUpdaterDefs;

    systemd.services = syncServices // roleServices;
    systemd.timers = syncTimers // roleTimers;
  };
}
