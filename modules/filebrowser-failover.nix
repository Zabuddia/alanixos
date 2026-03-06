{ config, lib, pkgs, hostname, ... }:
let
  cfg = config.alanix.filebrowserFailover;

  localNodeName = cfg.nodeName;
  nodes = cfg.nodes;
  localNode = nodes.${localNodeName} or null;
  localPriority = if localNode == null then 0 else localNode.priority;

  orderedNodeNames =
    lib.sort (a: b: nodes.${a}.priority < nodes.${b}.priority) (builtins.attrNames nodes);

  higherNodeNames =
    lib.filter (name: nodes.${name}.priority < localPriority) orderedNodeNames;

  lowerNodeNames =
    lib.filter (name: nodes.${name}.priority > localPriority) orderedNodeNames;

  remoteNodeNames = lib.filter (name: name != localNodeName) orderedNodeNames;

  mkNodeTuple = name: "${name}|${nodes.${name}.vpnIP}|${nodes.${name}.sshTarget}";

  higherNodeTuples = map mkNodeTuple higherNodeNames;
  lowerNodeTuples = map mkNodeTuple lowerNodeNames;
  remoteNodeTuples = map mkNodeTuple remoteNodeNames;

  syncPathsEscaped = lib.concatStringsSep " " (map lib.escapeShellArg cfg.sync.paths);
in
{
  imports = [ ./dns-updaters.nix ];

  options.alanix.filebrowserFailover = {
    enable = lib.mkEnableOption "File Browser failover controller";

    nodeName = lib.mkOption {
      type = lib.types.str;
      default = hostname;
      description = "Local node name; must match a key in alanix.filebrowserFailover.nodes.";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/alanix-filebrowser-failover";
    };

    activeMarkerPath = lib.mkOption {
      type = lib.types.str;
      default = "/run/alanix-filebrowser-failover/active";
      description = "Ephemeral marker file indicating this node currently owns the active role.";
    };

    serviceHealthPort = lib.mkOption {
      type = lib.types.port;
      default = 443;
      description = "Port used to check whether a remote node is actively serving filebrowser.";
    };

    checkInterval = lib.mkOption {
      type = lib.types.str;
      default = "15s";
    };

    failureThreshold = lib.mkOption {
      type = lib.types.ints.positive;
      default = 4;
      description = "Consecutive failed checks before local promotion.";
    };

    higherUnhealthyThreshold = lib.mkOption {
      type = lib.types.ints.positive;
      default = 20;
      description = ''
        Consecutive checks to wait before promoting when a higher-priority node
        is reachable but not serving filebrowser.
      '';
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
      description = "All nodes participating in filebrowser failover.";
    };

    sync = {
      enable = lib.mkEnableOption "Periodic standby sync via rsync over SSH";

      interval = lib.mkOption {
        type = lib.types.str;
        default = "2min";
      };

      paths = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "/var/lib/filebrowser"
          "/srv/filebrowser"
        ];
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

  config = lib.mkIf cfg.enable {
    assertions =
      [
        {
          assertion = cfg.nodes != {};
          message = "alanix.filebrowserFailover.nodes must not be empty.";
        }
        {
          assertion = builtins.hasAttr localNodeName cfg.nodes;
          message = "alanix.filebrowserFailover.nodeName '${localNodeName}' is not present in alanix.filebrowserFailover.nodes.";
        }
        {
          assertion = config.alanix.filebrowser.enable;
          message = "alanix.filebrowserFailover requires alanix.filebrowser.enable = true.";
        }
        {
          assertion = config.alanix.filebrowser.reverseProxy.enable;
          message = "alanix.filebrowserFailover requires alanix.filebrowser.reverseProxy.enable = true.";
        }
      ]
      ++ lib.optional cfg.sync.enable {
        assertion = cfg.sync.sshKeySecret != null;
        message = "alanix.filebrowserFailover.sync.sshKeySecret must be set when sync is enabled.";
      }
      ++ lib.optional cfg.dns.enable {
        assertion = cfg.dns.tokenSecret != null;
        message = "alanix.filebrowserFailover.dns.tokenSecret must be set when dns is enabled.";
      };

    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0700 root root - -"
      "d ${builtins.dirOf cfg.activeMarkerPath} 0755 root root - -"
    ];

    environment.systemPackages = [
      pkgs.rsync
      pkgs.netcat-openbsd
    ];

    networking.firewall.interfaces.wg0.allowedTCPPorts =
      lib.mkIf (cfg.sync.enable && cfg.sync.openFirewallOnWg) [ 22 ];

    users.users.root.openssh.authorizedKeys.keys =
      lib.mkIf (cfg.sync.enable && cfg.sync.authorizedPublicKey != null) [
        "from=\"${cfg.sync.allowedFromCIDR}\" ${cfg.sync.authorizedPublicKey}"
      ];

    alanix.dnsUpdaters.filebrowser-failover = lib.mkIf cfg.dns.enable {
      enable = true;
      provider = cfg.dns.provider;
      zone = cfg.dns.zone;
      records = [ cfg.dns.record ];
      tokenSecret = cfg.dns.tokenSecret;
      interval = cfg.dns.interval;
      startupDelay = "45s";
      proxied = cfg.dns.proxied;
      ttl = cfg.dns.ttl;
      runOnlyWhenPathExists = cfg.activeMarkerPath;
    };

    systemd.services.filebrowser-sync = lib.mkIf cfg.sync.enable {
      description = "Sync filebrowser data from currently active node";
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

        STATE_DIR=${lib.escapeShellArg cfg.stateDir}
        ACTIVE_MARKER=${lib.escapeShellArg cfg.activeMarkerPath}
        HEALTH_PORT=${toString cfg.serviceHealthPort}
        KNOWN_HOSTS="$STATE_DIR/known_hosts"
        SSH_KEY=${lib.escapeShellArg config.sops.secrets.${cfg.sync.sshKeySecret}.path}
        SYNC_PATHS=(${syncPathsEscaped})

        REMOTE_NODES=()
        ${lib.concatStringsSep "\n" (map (tuple: ''REMOTE_NODES+=(${lib.escapeShellArg tuple})'') remoteNodeTuples)}

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
          if ssh_cmd "$target" \
            "test -f '$ACTIVE_MARKER' && systemctl -q is-active filebrowser.service && systemctl -q is-active caddy.service" \
            >/dev/null 2>&1; then
            return 0
          fi

          # Fallback: treat an openly serving node on expected health port as active.
          ping -q -c1 -W2 "$ip" >/dev/null 2>&1 && nc -z -w2 "$ip" "$HEALTH_PORT" >/dev/null 2>&1
        }

        sync_from_target() {
          local target="$1"
          local rsync_ssh
          rsync_ssh="ssh -i $SSH_KEY -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$KNOWN_HOSTS"

          for p in "''${SYNC_PATHS[@]}"; do
            mkdir -p "$p"
            rsync -aHAX --numeric-ids --delete -e "$rsync_ssh" "$target:$p/" "$p/"
          done
        }

        for node in "''${REMOTE_NODES[@]}"; do
          IFS='|' read -r _name ip ssh_target <<< "$node"
          if node_is_active "$ip" "$ssh_target"; then
            sync_from_target "$ssh_target"
            exit 0
          fi
        done

        echo "No active remote node detected for filebrowser sync" >&2
        exit 1
      '';
    };

    systemd.timers.filebrowser-sync = lib.mkIf cfg.sync.enable {
      description = "Periodic filebrowser sync";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "30s";
        OnUnitActiveSec = cfg.sync.interval;
        Unit = "filebrowser-sync.service";
      };
    };

    systemd.services.filebrowser-role-controller = {
      description = "Filebrowser role controller (auto failover + failback)";
      after = [ "network-online.target" ] ++ lib.optional cfg.sync.enable "sops-install-secrets.service";
      wants = [ "network-online.target" ] ++ lib.optional cfg.sync.enable "sops-install-secrets.service";
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        Group = "root";
      };
      path = [ pkgs.iputils pkgs.netcat-openbsd pkgs.systemd pkgs.coreutils pkgs.openssh pkgs.rsync ];
      script = ''
        set -euo pipefail

        STATE_DIR=${lib.escapeShellArg cfg.stateDir}
        ACTIVE_MARKER=${lib.escapeShellArg cfg.activeMarkerPath}
        FAIL_FILE="$STATE_DIR/fail-count"
        UNHEALTHY_FAIL_FILE="$STATE_DIR/higher-unhealthy-count"
        KNOWN_HOSTS="$STATE_DIR/known_hosts"
        HEALTH_PORT=${toString cfg.serviceHealthPort}

        HIGHER_NODES=()
        ${lib.concatStringsSep "\n" (map (tuple: ''HIGHER_NODES+=(${lib.escapeShellArg tuple})'') higherNodeTuples)}

        LOWER_NODES=()
        ${lib.concatStringsSep "\n" (map (tuple: ''LOWER_NODES+=(${lib.escapeShellArg tuple})'') lowerNodeTuples)}

        mkdir -p "$STATE_DIR"

        ${if cfg.sync.enable then ''
          SSH_KEY=${lib.escapeShellArg config.sops.secrets.${cfg.sync.sshKeySecret}.path}
          SYNC_PATHS=(${syncPathsEscaped})

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
            if ssh_cmd "$target" \
              "test -f '$ACTIVE_MARKER' && systemctl -q is-active filebrowser.service && systemctl -q is-active caddy.service" \
              >/dev/null 2>&1; then
              return 0
            fi

            # Fallback: if SSH control checks are unavailable, use service health over WG.
            ping -q -c1 -W2 "$ip" >/dev/null 2>&1 && nc -z -w2 "$ip" "$HEALTH_PORT" >/dev/null 2>&1
          }

          sync_from_target() {
            local target="$1"
            local rsync_ssh
            rsync_ssh="ssh -i $SSH_KEY -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$KNOWN_HOSTS"

            for p in "''${SYNC_PATHS[@]}"; do
              mkdir -p "$p"
              rsync -aHAX --numeric-ids --delete -e "$rsync_ssh" "$target:$p/" "$p/"
            done
          }

          maybe_sync_from_active_lower() {
            for node in "''${LOWER_NODES[@]}"; do
              IFS='|' read -r _name ip ssh_target <<< "$node"
              if node_is_active "$ip" "$ssh_target"; then
                sync_from_target "$ssh_target" || true
                return 0
              fi
            done
            return 0
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
            ping -q -c1 -W2 "$ip" >/dev/null 2>&1 && nc -z -w2 "$ip" "$HEALTH_PORT" >/dev/null 2>&1
          }

          maybe_sync_from_active_lower() {
            return 0
          }
        ''}

        stop_local() {
          systemctl stop filebrowser.service || true
          systemctl stop caddy.service || true
          rm -f "$ACTIVE_MARKER"
        }

        start_local() {
          systemctl start filebrowser.service
          systemctl start caddy.service
          touch "$ACTIVE_MARKER"
          ${lib.optionalString cfg.dns.enable ''
            systemctl start alanix-dns-updater-filebrowser-failover.service || true
          ''}
        }

        local_is_serving() {
          systemctl -q is-active filebrowser.service && systemctl -q is-active caddy.service
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

        unhealthy_count=0
        if [ -f "$UNHEALTHY_FAIL_FILE" ]; then
          unhealthy_count="$(cat "$UNHEALTHY_FAIL_FILE" || echo 0)"
        fi

        if [ "$higher_reachable" -eq 1 ]; then
          echo 0 > "$FAIL_FILE"
          unhealthy_count=$((unhealthy_count + 1))
          echo "$unhealthy_count" > "$UNHEALTHY_FAIL_FILE"

          if [ "$unhealthy_count" -lt ${toString cfg.higherUnhealthyThreshold} ]; then
            exit 0
          fi
        else
          echo 0 > "$UNHEALTHY_FAIL_FILE"
          unreachable_count=$((unreachable_count + 1))
          echo "$unreachable_count" > "$FAIL_FILE"

          if [ "$unreachable_count" -lt ${toString cfg.failureThreshold} ]; then
            exit 0
          fi
        fi

        if [ -f "$ACTIVE_MARKER" ]; then
          if ! systemctl -q is-active filebrowser.service || ! systemctl -q is-active caddy.service; then
            maybe_sync_from_active_lower
            start_local
          fi
          exit 0
        fi

        maybe_sync_from_active_lower
        start_local
      '';
    };

    systemd.timers.filebrowser-role-controller = {
      description = "Filebrowser role control loop";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "20s";
        OnUnitActiveSec = cfg.checkInterval;
        Unit = "filebrowser-role-controller.service";
      };
    };
  };
}
