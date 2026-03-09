{ config, lib, pkgs, ... }:
let
  cfg = config.alanix.dashboard;
  serviceAccess = import ./_service-access.nix { inherit lib; };
  hasSopsSecrets = lib.hasAttrByPath [ "sops" "secrets" ] config;
  torSecretKeyPath =
    if cfg.torAccess.secretKeySecret == null then
      null
    else
      config.sops.secrets.${cfg.torAccess.secretKeySecret}.path;
  adminPasswordFile =
    if hasSopsSecrets && builtins.hasAttr cfg.adminPasswordSecret config.sops.secrets then
      config.sops.secrets.${cfg.adminPasswordSecret}.path
    else
      null;

  blackboxConfig = pkgs.writeText "blackbox.yml" ''
    modules:
      http_2xx:
        prober: http
        timeout: 10s
        http:
          preferred_ip_protocol: ip4
  '';

  clusterOverviewDashboard = {
    id = null;
    uid = "alanix-cluster-overview";
    title = "Alanix Cluster Overview";
    timezone = "browser";
    schemaVersion = 39;
    version = 1;
    editable = false;
    refresh = "30s";
    time = {
      from = "now-6h";
      to = "now";
    };
    templating.list = [ ];
    panels = [
      {
        id = 1;
        type = "timeseries";
        title = "CPU Usage %";
        datasource = {
          type = "prometheus";
          uid = "prometheus";
        };
        gridPos = {
          h = 8;
          w = 12;
          x = 0;
          y = 0;
        };
        targets = [
          {
            refId = "A";
            expr = "100 - (avg by(instance) (rate(node_cpu_seconds_total{mode=\"idle\"}[5m])) * 100)";
            legendFormat = "{{instance}}";
          }
        ];
        fieldConfig = {
          defaults = {
            unit = "percent";
            min = 0;
            max = 100;
          };
          overrides = [ ];
        };
      }
      {
        id = 2;
        type = "timeseries";
        title = "RAM Usage %";
        datasource = {
          type = "prometheus";
          uid = "prometheus";
        };
        gridPos = {
          h = 8;
          w = 12;
          x = 12;
          y = 0;
        };
        targets = [
          {
            refId = "A";
            expr = "(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100";
            legendFormat = "{{instance}}";
          }
        ];
        fieldConfig = {
          defaults = {
            unit = "percent";
            min = 0;
            max = 100;
          };
          overrides = [ ];
        };
      }
      {
        id = 3;
        type = "timeseries";
        title = "Disk Usage / %";
        datasource = {
          type = "prometheus";
          uid = "prometheus";
        };
        gridPos = {
          h = 8;
          w = 12;
          x = 0;
          y = 8;
        };
        targets = [
          {
            refId = "A";
            expr = "(1 - (node_filesystem_avail_bytes{mountpoint=\"/\",fstype!~\"tmpfs|overlay|squashfs\"} / node_filesystem_size_bytes{mountpoint=\"/\",fstype!~\"tmpfs|overlay|squashfs\"})) * 100";
            legendFormat = "{{instance}}";
          }
        ];
        fieldConfig = {
          defaults = {
            unit = "percent";
            min = 0;
            max = 100;
          };
          overrides = [ ];
        };
      }
      {
        id = 4;
        type = "timeseries";
        title = "Network RX bytes/s";
        datasource = {
          type = "prometheus";
          uid = "prometheus";
        };
        gridPos = {
          h = 8;
          w = 12;
          x = 12;
          y = 8;
        };
        targets = [
          {
            refId = "A";
            expr = "sum by(instance) (rate(node_network_receive_bytes_total{device!=\"lo\"}[5m]))";
            legendFormat = "{{instance}}";
          }
        ];
        fieldConfig = {
          defaults.unit = "Bps";
          overrides = [ ];
        };
      }
      {
        id = 5;
        type = "timeseries";
        title = "Network TX bytes/s";
        datasource = {
          type = "prometheus";
          uid = "prometheus";
        };
        gridPos = {
          h = 8;
          w = 12;
          x = 0;
          y = 16;
        };
        targets = [
          {
            refId = "A";
            expr = "sum by(instance) (rate(node_network_transmit_bytes_total{device!=\"lo\"}[5m]))";
            legendFormat = "{{instance}}";
          }
        ];
        fieldConfig = {
          defaults.unit = "Bps";
          overrides = [ ];
        };
      }
      {
        id = 6;
        type = "timeseries";
        title = "Temperatures (C)";
        datasource = {
          type = "prometheus";
          uid = "prometheus";
        };
        gridPos = {
          h = 8;
          w = 12;
          x = 12;
          y = 16;
        };
        targets = [
          {
            refId = "A";
            expr = "node_hwmon_temp_celsius";
            legendFormat = "{{instance}} {{chip}} {{sensor}}";
          }
        ];
        fieldConfig = {
          defaults.unit = "celsius";
          overrides = [ ];
        };
      }
      {
        id = 7;
        type = "table";
        title = "Service Health (1=up)";
        datasource = {
          type = "prometheus";
          uid = "prometheus";
        };
        gridPos = {
          h = 8;
          w = 8;
          x = 0;
          y = 24;
        };
        targets = [
          {
            refId = "A";
            expr = "alanix_service_up";
            format = "table";
            instant = true;
          }
        ];
      }
      {
        id = 8;
        type = "table";
        title = "Failover Role Active (1=active)";
        datasource = {
          type = "prometheus";
          uid = "prometheus";
        };
        gridPos = {
          h = 8;
          w = 8;
          x = 8;
          y = 24;
        };
        targets = [
          {
            refId = "A";
            expr = "alanix_service_role_active";
            format = "table";
            instant = true;
          }
        ];
      }
      {
        id = 9;
        type = "table";
        title = "Backup Jobs Last Success (1=success)";
        datasource = {
          type = "prometheus";
          uid = "prometheus";
        };
        gridPos = {
          h = 8;
          w = 8;
          x = 16;
          y = 24;
        };
        targets = [
          {
            refId = "A";
            expr = "alanix_backup_service_last_success";
            format = "table";
            instant = true;
          }
        ];
      }
      {
        id = 10;
        type = "timeseries";
        title = "Endpoint Success (1=up)";
        datasource = {
          type = "prometheus";
          uid = "prometheus";
        };
        gridPos = {
          h = 8;
          w = 12;
          x = 0;
          y = 32;
        };
        targets = [
          {
            refId = "A";
            expr = "probe_success{job=\"blackbox-http\"}";
            legendFormat = "{{endpoint}}";
          }
        ];
        fieldConfig = {
          defaults = {
            min = 0;
            max = 1;
          };
          overrides = [ ];
        };
      }
      {
        id = 11;
        type = "timeseries";
        title = "Endpoint Latency";
        datasource = {
          type = "prometheus";
          uid = "prometheus";
        };
        gridPos = {
          h = 8;
          w = 12;
          x = 12;
          y = 32;
        };
        targets = [
          {
            refId = "A";
            expr = "probe_duration_seconds{job=\"blackbox-http\"}";
            legendFormat = "{{endpoint}}";
          }
        ];
        fieldConfig = {
          defaults.unit = "s";
          overrides = [ ];
        };
      }
    ];
  };

  dashboardFiles = pkgs.linkFarm "alanix-grafana-dashboards" [
    {
      name = "cluster-overview.json";
      path = pkgs.writeText "cluster-overview.json" (builtins.toJSON clusterOverviewDashboard);
    }
  ];

  blackboxScrapeConfig = {
    job_name = "blackbox-http";
    metrics_path = "/probe";
    params = {
      module = [ "http_2xx" ];
    };
    static_configs = map (endpoint: {
      targets = [ endpoint.url ];
      labels.endpoint = endpoint.name;
    }) cfg.endpointChecks;
    relabel_configs = [
      {
        source_labels = [ "__address__" ];
        target_label = "__param_target";
      }
      {
        source_labels = [ "__param_target" ];
        target_label = "instance";
      }
      {
        target_label = "__address__";
        replacement = "${cfg.prometheusListenAddress}:${toString cfg.blackboxPort}";
      }
    ];
  };
in
{
  options.alanix.dashboard = {
    enable = lib.mkEnableOption "Grafana/Prometheus dashboard (Alanix)";

    active = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether this node runs the Grafana/Prometheus stack.";
    };

    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 3300;
    };

    inherit (serviceAccess.mkBackendFirewallOptions {
      serviceTitle = "Dashboard";
      defaultOpenFirewall = false;
    })
      openFirewall
      firewallInterfaces;

    adminUser = lib.mkOption {
      type = lib.types.str;
      default = "admin";
    };

    adminPasswordSecret = lib.mkOption {
      type = lib.types.str;
      default = "grafana/admin-password";
      description = "sops secret containing Grafana admin password.";
    };

    prometheusListenAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
    };

    prometheusPort = lib.mkOption {
      type = lib.types.port;
      default = 9090;
    };

    blackboxPort = lib.mkOption {
      type = lib.types.port;
      default = 9115;
    };

    nodeExporterListenAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Address node_exporter listens on (typically this node's WireGuard IP).";
    };

    nodeExporterPort = lib.mkOption {
      type = lib.types.port;
      default = 9100;
    };

    nodeExporterInterface = lib.mkOption {
      type = lib.types.str;
      default = "wg0";
      description = "Interface to open for node_exporter scraping.";
    };

    metricsTextfileDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/alanix-dashboard/node-exporter-textfiles";
    };

    metricsInterval = lib.mkOption {
      type = lib.types.str;
      default = "1m";
    };

    scrapeTargets = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Prometheus scrape targets for node_exporter endpoints (host:port).";
    };

    endpointChecks = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          name = lib.mkOption {
            type = lib.types.str;
          };

          url = lib.mkOption {
            type = lib.types.str;
            description = "Full URL probe target for blackbox exporter.";
          };
        };
      });
      default = [ ];
      description = "HTTP endpoints to probe.";
    };

    wanAccess = serviceAccess.mkWanAccessOptions { serviceTitle = "Dashboard"; };

    wireguardAccess = serviceAccess.mkWireguardAccessOptions {
      serviceTitle = "Dashboard";
      defaultPort = 8094;
      defaultInterface = "wg0";
    };

    torAccess = serviceAccess.mkTorAccessOptions {
      serviceTitle = "Dashboard";
      defaultServiceName = "dashboard";
      defaultHttpLocalPort = 18330;
      defaultHttpsLocalPort = 18730;
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = hasSopsSecrets;
        message = "alanix.dashboard.adminPasswordSecret requires sops-nix configuration.";
      }
      {
        assertion = builtins.hasAttr cfg.adminPasswordSecret config.sops.secrets;
        message = "alanix.dashboard.adminPasswordSecret is set but no matching sops.secrets entry exists.";
      }
      {
        assertion = cfg.nodeExporterListenAddress != null;
        message = "alanix.dashboard.nodeExporterListenAddress must be set (use node VPN IP).";
      }
      {
        assertion = cfg.scrapeTargets != [ ];
        message = "alanix.dashboard.scrapeTargets must be non-empty.";
      }
    ] ++ serviceAccess.mkAccessAssertions {
      inherit cfg hasSopsSecrets;
      modulePathPrefix = "alanix.dashboard";
    };

    sops.secrets.${cfg.adminPasswordSecret}.restartUnits = [
      "grafana.service"
    ];

    networking.firewall = lib.mkMerge [
      (serviceAccess.mkAccessFirewallConfig { inherit cfg; })
      {
        interfaces.${cfg.nodeExporterInterface}.allowedTCPPorts = [ cfg.nodeExporterPort ];
      }
    ];

    systemd.tmpfiles.rules = [
      "d ${cfg.metricsTextfileDir} 0755 root root - -"
    ];

    systemd.services.alanix-dashboard-metrics = {
      description = "Generate Alanix dashboard textfile metrics";
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        Group = "root";
      };
      path = [
        pkgs.coreutils
        pkgs.gawk
        pkgs.systemd
      ];
      script = ''
        set -euo pipefail

        OUT_DIR=${lib.escapeShellArg cfg.metricsTextfileDir}
        OUT_FILE="$OUT_DIR/alanix_cluster.prom"
        TMP_FILE="$(mktemp "$OUT_DIR/.alanix_cluster.prom.XXXXXX")"
        trap 'rm -f "$TMP_FILE"' EXIT

        to_bool_active() {
          if systemctl -q is-active "$1" 2>/dev/null; then
            printf '1'
          else
            printf '0'
          fi
        }

        to_epoch() {
          local ts="$1"
          if [ -z "$ts" ] || [ "$ts" = "n/a" ]; then
            printf '0'
            return 0
          fi
          date --date="$ts" +%s 2>/dev/null || printf '0'
        }

        {
          printf '# HELP alanix_metrics_generated_seconds Unix timestamp when Alanix textfile metrics were generated.\n'
          printf '# TYPE alanix_metrics_generated_seconds gauge\n'
          printf 'alanix_metrics_generated_seconds %s\n' "$(date +%s)"

          printf '# HELP alanix_service_up Service unit health (1=active, 0=inactive).\n'
          printf '# TYPE alanix_service_up gauge\n'
          printf '# HELP alanix_service_role_active Failover role active marker (1=active).\n'
          printf '# TYPE alanix_service_role_active gauge\n'
          printf '# HELP alanix_service_role_standby Failover role standby marker (1=standby).\n'
          printf '# TYPE alanix_service_role_standby gauge\n'

          mapfile -t role_timers < <(systemctl list-unit-files --type=timer --no-legend | awk '/-role-controller\.timer$/ { print $1 }' | sort)
          for timer in "''${role_timers[@]}"; do
            [ -n "$timer" ] || continue
            service_name="''${timer%-role-controller.timer}"
            marker="/run/alanix-''${service_name}-failover/active"
            service_unit="''${service_name}.service"

            service_up="$(to_bool_active "$service_unit")"
            role_active=0
            role_standby=1
            if [ -f "$marker" ]; then
              role_active=1
              role_standby=0
            fi

            printf 'alanix_service_up{service="%s"} %s\n' "$service_name" "$service_up"
            printf 'alanix_service_role_active{service="%s"} %s\n' "$service_name" "$role_active"
            printf 'alanix_service_role_standby{service="%s"} %s\n' "$service_name" "$role_standby"
          done

          printf '# HELP alanix_backup_timer_active Backup timer active state (1=active).\n'
          printf '# TYPE alanix_backup_timer_active gauge\n'
          printf '# HELP alanix_backup_last_trigger_seconds Backup timer last trigger UNIX timestamp.\n'
          printf '# TYPE alanix_backup_last_trigger_seconds gauge\n'
          printf '# HELP alanix_backup_service_last_success Backup service last result (1=success, 0=otherwise).\n'
          printf '# TYPE alanix_backup_service_last_success gauge\n'

          mapfile -t backup_timers < <(systemctl list-unit-files --type=timer --no-legend | awk '/^restic-backups-.*\.timer$/ { print $1 }' | sort)
          for timer in "''${backup_timers[@]}"; do
            [ -n "$timer" ] || continue
            service="''${timer%.timer}.service"
            timer_active="$(to_bool_active "$timer")"
            last_trigger_raw="$(systemctl show "$timer" -p LastTriggerUSec --value 2>/dev/null || true)"
            last_trigger_epoch="$(to_epoch "$last_trigger_raw")"
            result="$(systemctl show "$service" -p Result --value 2>/dev/null || true)"
            last_success=0
            if [ "$result" = "success" ]; then
              last_success=1
            fi

            printf 'alanix_backup_timer_active{timer="%s"} %s\n' "$timer" "$timer_active"
            printf 'alanix_backup_last_trigger_seconds{timer="%s"} %s\n' "$timer" "$last_trigger_epoch"
            printf 'alanix_backup_service_last_success{service="%s"} %s\n' "$service" "$last_success"
          done
        } > "$TMP_FILE"

        chmod 0644 "$TMP_FILE"
        mv -f "$TMP_FILE" "$OUT_FILE"
      '';
    };

    systemd.timers.alanix-dashboard-metrics = {
      description = "Periodic Alanix dashboard textfile metrics refresh";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "30s";
        OnUnitActiveSec = cfg.metricsInterval;
        Unit = "alanix-dashboard-metrics.service";
      };
    };

    services.prometheus = {
      enable = true;
      listenAddress = cfg.prometheusListenAddress;
      port = cfg.prometheusPort;
      scrapeConfigs =
        [
          {
            job_name = "node";
            static_configs = [ { targets = cfg.scrapeTargets; } ];
          }
        ]
        ++ lib.optional (cfg.endpointChecks != [ ]) blackboxScrapeConfig;

      exporters.node = {
        enable = true;
        listenAddress = cfg.nodeExporterListenAddress;
        port = cfg.nodeExporterPort;
        openFirewall = false;
        enabledCollectors = [
          "hwmon"
          "systemd"
          "textfile"
        ];
        extraFlags = [ "--collector.textfile.directory=${cfg.metricsTextfileDir}" ];
      };

      exporters.blackbox = {
        enable = true;
        listenAddress = cfg.prometheusListenAddress;
        port = cfg.blackboxPort;
        configFile = blackboxConfig;
        openFirewall = false;
      };
    };

    services.grafana = {
      enable = true;
      settings = {
        server = {
          http_addr = cfg.listenAddress;
          http_port = cfg.port;
        };
        users.allow_sign_up = false;
        analytics.reporting_enabled = false;
        security = {
          admin_user = cfg.adminUser;
          admin_password = if adminPasswordFile == null then "" else "$__file{${adminPasswordFile}}";
        };
      };
      provision = {
        enable = true;
        datasources.settings = {
          apiVersion = 1;
          datasources = [
            {
              name = "Prometheus";
              type = "prometheus";
              uid = "prometheus";
              access = "proxy";
              url = "http://${cfg.prometheusListenAddress}:${toString cfg.prometheusPort}";
              isDefault = true;
              editable = false;
            }
          ];
        };
        dashboards.settings = {
          apiVersion = 1;
          providers = [
            {
              name = "alanix";
              type = "file";
              allowUiUpdates = false;
              updateIntervalSeconds = 30;
              options.path = dashboardFiles;
            }
          ];
        };
      };
    };

    systemd.services.prometheus.wantedBy = lib.mkIf (!cfg.active) (lib.mkForce []);
    systemd.services.grafana.wantedBy = lib.mkIf (!cfg.active) (lib.mkForce []);
    systemd.services.prometheus-blackbox-exporter = {
      wantedBy = lib.mkIf (!cfg.active) (lib.mkForce []);
      partOf = [ "prometheus.service" ];
    };
    systemd.services.prometheus.wants = [ "prometheus-blackbox-exporter.service" ];
    systemd.services.prometheus.after = [ "prometheus-blackbox-exporter.service" ];

    services.caddy = serviceAccess.mkAccessCaddyConfig {
      inherit cfg;
      upstreamPort = cfg.port;
    };

    services.tor = serviceAccess.mkTorConfig {
      inherit cfg torSecretKeyPath;
    };
  };
}
