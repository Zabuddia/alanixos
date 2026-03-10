{ config, lib, pkgs, ... }:
let
  cfg = config.alanix.dashboard;
  nodeName = config.networking.hostName;
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

  computerStatsDashboard = {
    id = null;
    uid = "alanix-cluster-compute";
    title = "Alanix Computer Stats";
    timezone = "browser";
    schemaVersion = 39;
    version = 1;
    editable = false;
    refresh = "30s";
    time = {
      from = "now-6h";
      to = "now";
    };
    links = [
      {
        title = "Service Stats";
        type = "link";
        url = "/d/alanix-cluster-services/alanix-service-stats";
      }
    ];
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
    ];
  };

  serviceTilePanels =
    let
      mkTile = idx: entry:
        let
          x = (idx - (builtins.div idx 2) * 2) * 12;
          y = (builtins.div idx 2) * 10;
          serviceName = entry.service;
        in
        {
          id = 100 + idx;
          type = "table";
          title = "Service: ${serviceName}";
          datasource = {
            type = "prometheus";
            uid = "prometheus";
          };
          gridPos = {
            h = 10;
            w = 12;
            inherit x y;
          };
          targets = [
            {
              refId = "B";
              expr = "max by(node,endpoint,status,url,icon) (alanix_service_endpoint_active{service=\"${serviceName}\",url!=\"none\"})";
              format = "table";
              instant = true;
            }
          ];
          transformations = [
            {
              id = "organize";
              options = {
                excludeByName = {
                  Time = true;
                  Value = true;
                  service = true;
                  __name__ = true;
                };
                indexByName = {
                  icon = 0;
                  node = 1;
                  endpoint = 2;
                  status = 3;
                  url = 4;
                };
                renameByName = {
                  icon = "Icon";
                  node = "Node";
                  endpoint = "Endpoint";
                  status = "Status";
                  url = "URL";
                };
              };
            }
          ];
          fieldConfig = {
            defaults = { };
            overrides = [
              {
                matcher = {
                  id = "byName";
                  options = "icon";
                };
                properties = [
                  {
                    id = "custom.cellOptions";
                    value = {
                      type = "image";
                    };
                  }
                ];
              }
              {
                matcher = {
                  id = "byName";
                  options = "status";
                };
                properties = [
                  {
                    id = "mappings";
                    value = [
                      {
                        type = "value";
                        options = {
                          active = {
                            text = "active";
                            color = "green";
                          };
                          standby = {
                            text = "standby";
                            color = "orange";
                          };
                        };
                      }
                    ];
                  }
                  {
                    id = "custom.cellOptions";
                    value = {
                      type = "color-background";
                    };
                  }
                ];
              }
              {
                matcher = {
                  id = "byName";
                  options = "url";
                };
                properties = [
                  {
                    id = "links";
                    value = [
                      {
                        title = "Open";
                        url = "\${__value.raw}";
                        targetBlank = true;
                      }
                    ];
                  }
                ];
              }
            ];
          };
        };
    in
    lib.imap0 mkTile cfg.serviceDirectory;

  serviceStatsDashboard = {
    id = null;
    uid = "alanix-cluster-services";
    title = "Alanix Service Stats";
    timezone = "browser";
    schemaVersion = 39;
    version = 1;
    editable = false;
    refresh = "30s";
    time = {
      from = "now-6h";
      to = "now";
    };
    links = [
      {
        title = "Computer Stats";
        type = "link";
        url = "/d/alanix-cluster-compute/alanix-computer-stats";
      }
    ];
    templating.list = [ ];
    panels = serviceTilePanels;
  };

  dashboardFiles = pkgs.linkFarm "alanix-grafana-dashboards" [
    {
      name = "computer-stats.json";
      path = pkgs.writeText "computer-stats.json" (builtins.toJSON computerStatsDashboard);
    }
    {
      name = "service-stats.json";
      path = pkgs.writeText "service-stats.json" (builtins.toJSON serviceStatsDashboard);
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

    serviceDirectory = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          service = lib.mkOption {
            type = lib.types.str;
          };

          wanUrl = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
          };

          wireguardUrl = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
          };

          torServiceName = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
          };

          torScheme = lib.mkOption {
            type = lib.types.nullOr (lib.types.enum [ "http" "https" ]);
            default = null;
          };
        };
      });
      default = [ ];
      description = "Service endpoint metadata used for dynamic endpoint/status views.";
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
        node_name=${lib.escapeShellArg nodeName}

        to_bool_active() {
          if systemctl -q is-active "$1" 2>/dev/null; then
            printf '1'
          else
            printf '0'
          fi
        }

        esc_label() {
          local s="$1"
          s="''${s//\\/\\\\}"
          s="''${s//\"/\\\"}"
          s="''${s//$'\n'/ }"
          printf '%s' "$s"
        }

        emit_endpoint_metric() {
          local service="$1"
          local node="$2"
          local endpoint="$3"
          local status="$4"
          local url="$5"
          local icon="$6"
          local active="$7"

          if [ -z "$url" ]; then
            url="none"
          fi

          if [ -z "$icon" ]; then
            icon="none"
          fi

          printf 'alanix_service_endpoint_active{service="%s",node="%s",endpoint="%s",status="%s",url="%s",icon="%s"} %s\n' \
            "$(esc_label "$service")" \
            "$(esc_label "$node")" \
            "$(esc_label "$endpoint")" \
            "$(esc_label "$status")" \
            "$(esc_label "$url")" \
            "$(esc_label "$icon")" \
            "$active"
        }

        SERVICE_DIRECTORY=()
        ${lib.concatStringsSep "\n" (map (entry:
          let
            tuple = "${entry.service}|${entry.wanUrl or ""}|${entry.wireguardUrl or ""}|${entry.torServiceName or ""}|${entry.torScheme or ""}";
          in
          ''SERVICE_DIRECTORY+=(${lib.escapeShellArg tuple})''
        ) cfg.serviceDirectory)}

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
          printf '# HELP alanix_service_node_state Service role state per node (1=true, 0=false).\n'
          printf '# TYPE alanix_service_node_state gauge\n'

          mapfile -t role_services < <(systemctl list-unit-files --type=service --no-legend | awk '$1 ~ /-role-controller\.service$/ { print $1 }' | sort)
          for role_svc in "''${role_services[@]}"; do
            [ -n "$role_svc" ] || continue
            service_name="''${role_svc%-role-controller.service}"
            marker="/run/alanix-''${service_name}-failover/active"
            service_unit="''${service_name}.service"

            service_up="$(to_bool_active "$service_unit")"
            role_active=0
            role_standby=1
            if [ -f "$marker" ]; then
              role_active=1
              role_standby=0
            fi

            printf 'alanix_service_up{service="%s",node="%s"} %s\n' "$service_name" "$node_name" "$service_up"
            printf 'alanix_service_role_active{service="%s",node="%s"} %s\n' "$service_name" "$node_name" "$role_active"
            printf 'alanix_service_role_standby{service="%s",node="%s"} %s\n' "$service_name" "$node_name" "$role_standby"
            printf 'alanix_service_node_state{service="%s",node="%s",state="active"} %s\n' "$service_name" "$node_name" "$role_active"
            printf 'alanix_service_node_state{service="%s",node="%s",state="standby"} %s\n' "$service_name" "$node_name" "$role_standby"
          done

          printf '# HELP alanix_service_endpoint_active Service endpoint active state based on role marker (1=active, 0=inactive).\n'
          printf '# TYPE alanix_service_endpoint_active gauge\n'

          for row in "''${SERVICE_DIRECTORY[@]}"; do
            IFS='|' read -r service_name wan_url wg_url tor_service_name tor_scheme <<< "$row"
            [ -n "$service_name" ] || continue

            marker="/run/alanix-''${service_name}-failover/active"
            role_active=0
            role_status="standby"
            if [ -f "$marker" ]; then
              role_active=1
              role_status="active"
            fi

            tor_url=""
            if [ -n "$tor_service_name" ]; then
              tor_host_file="/var/lib/tor/onion/$tor_service_name/hostname"
              if [ -f "$tor_host_file" ]; then
                tor_host="$(tr -d '\r\n' < "$tor_host_file")"
                if [ -n "$tor_host" ]; then
                  if [ -n "$tor_scheme" ]; then
                    tor_url="$tor_scheme://$tor_host"
                  else
                    tor_url="http://$tor_host"
                  fi
                fi
              fi
            fi

            preferred_icon_base=""
            if [ -n "$wan_url" ]; then
              preferred_icon_base="$wan_url"
            elif [ -n "$wg_url" ]; then
              preferred_icon_base="$wg_url"
            elif [ -n "$tor_url" ]; then
              preferred_icon_base="$tor_url"
            fi
            preferred_icon=""
            if [ -n "$preferred_icon_base" ]; then
              preferred_icon="''${preferred_icon_base%/}/favicon.ico"
            fi

            emit_endpoint_metric "$service_name" "$node_name" "wan" "$role_status" "$wan_url" "$preferred_icon" "$role_active"
            emit_endpoint_metric "$service_name" "$node_name" "wireguard" "$role_status" "$wg_url" "$preferred_icon" "$role_active"
            emit_endpoint_metric "$service_name" "$node_name" "tor" "$role_status" "$tor_url" "$preferred_icon" "$role_active"
          done

          printf '# HELP alanix_backup_last_success_seconds Last successful backup completion time (Unix seconds).\n'
          printf '# TYPE alanix_backup_last_success_seconds gauge\n'

          mapfile -t backup_timers < <(systemctl list-unit-files --type=timer --no-legend | awk '$1 ~ /^restic-backups-.*\.timer$/ { print $1 }' | sort)
          for timer in "''${backup_timers[@]}"; do
            [ -n "$timer" ] || continue
            service="''${timer%.timer}.service"
            last_success_line="$(journalctl --unit "$service" --no-pager --output=short-unix -g 'Finished ' -n 1 2>/dev/null | head -n1 || true)"
            last_success_epoch="0"
            if [ -n "$last_success_line" ]; then
              last_success_epoch="''${last_success_line%% *}"
              last_success_epoch="''${last_success_epoch%%.*}"
              case "$last_success_epoch" in
                ""|*[!0-9]*) last_success_epoch="0" ;;
              esac
            fi

            printf 'alanix_backup_last_success_seconds{service="%s",node="%s"} %s\n' "$service" "$node_name" "$last_success_epoch"
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
        dashboards.default_home_dashboard_path = "${dashboardFiles}/service-stats.json";
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
