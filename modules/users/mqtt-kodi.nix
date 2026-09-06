{ config, lib, name, pkgs, ... }:

let
  cfg = config.mqttKodi;

  device = {
    identifiers = [ cfg.deviceId ];
    name = cfg.deviceName;
    manufacturer = "Alanix";
    model = "NixOS media PC";
  };

  discoveryPayload = builtins.toJSON {
    name = "Kodi";
    unique_id = "${cfg.deviceId}_kodi";
    default_entity_id = "switch.kodi";
    command_topic = "${cfg.topicPrefix}/command";
    state_topic = "${cfg.topicPrefix}/state";
    payload_on = "ON";
    payload_off = "OFF";
    state_on = "ON";
    state_off = "OFF";
    device_class = "switch";
    availability_topic = "${cfg.topicPrefix}/status";
    payload_available = "online";
    payload_not_available = "offline";
    icon = "mdi:kodi";
    inherit device;
  };

  legacyLaunchDiscoveryTopics = lib.concatStringsSep "\n" (
    lib.mapAttrsToList
      (appId: _: ''
        clear_retained ${lib.escapeShellArg "${cfg.discoveryPrefix}/button/${cfg.deviceId}/launch_${appId}/config"}
      '')
      config.appLauncher.apps
  );

  bridge = pkgs.writeShellScript "alanix-mqtt-kodi" ''
    set -euo pipefail

    mqtt_args=(
      -h ${lib.escapeShellArg cfg.broker}
      -p ${toString cfg.port}
    )

    publish_retained() {
      ${pkgs.mosquitto}/bin/mosquitto_pub "''${mqtt_args[@]}" -q 1 -r -t "$1" -m "$2"
    }

    clear_retained() {
      ${pkgs.mosquitto}/bin/mosquitto_pub "''${mqtt_args[@]}" -q 1 -r -t "$1" -n
    }

    kodi_is_running() {
      ${pkgs.procps}/bin/pgrep -x kodi >/dev/null 2>&1 \
        || ${pkgs.procps}/bin/pgrep -x kodi.bin >/dev/null 2>&1
    }

    publish_state() {
      if kodi_is_running; then
        publish_retained "${cfg.topicPrefix}/state" ON
      else
        publish_retained "${cfg.topicPrefix}/state" OFF
      fi
    }

    close_kodi() {
      kodi_is_running || return 0

      # JSON-RPC asks Kodi to shut down cleanly and does not depend on which
      # Sway window is focused. Fall back to killing only Kodi's window if its
      # web server is unavailable.
      if ! ${pkgs.curl}/bin/curl --fail --silent --show-error --max-time 5 \
        -H 'Content-Type: application/json' \
        -X POST ${lib.escapeShellArg cfg.kodiJsonRpcUrl} \
        --data '{"jsonrpc":"2.0","id":1,"method":"Application.Quit"}' \
        >/dev/null; then
        ${pkgs.sway}/bin/swaymsg '[app_id="Kodi"] kill' >/dev/null
      fi
    }

    monitor_pid=""
    cleanup() {
      if [ -n "$monitor_pid" ]; then
        kill "$monitor_pid" 2>/dev/null || true
        wait "$monitor_pid" 2>/dev/null || true
      fi
      publish_retained "${cfg.topicPrefix}/status" offline || true
    }
    trap cleanup EXIT

    # Remove the retained discovery records from the old general-purpose
    # launcher so Home Assistant drops its app buttons, selector, and text
    # entities after alan-tv is rebuilt.
    ${legacyLaunchDiscoveryTopics}
    clear_retained ${lib.escapeShellArg "${cfg.discoveryPrefix}/select/${cfg.deviceId}/application/config"}
    clear_retained ${lib.escapeShellArg "${cfg.discoveryPrefix}/button/${cfg.deviceId}/close_current_app/config"}
    clear_retained ${lib.escapeShellArg "${cfg.discoveryPrefix}/text/${cfg.deviceId}/type_text/config"}
    clear_retained ${lib.escapeShellArg "${cfg.discoveryPrefix}/sensor/${cfg.deviceId}/type_result/config"}
    clear_retained ${lib.escapeShellArg "${cfg.legacyTopicPrefix}/state/application"}
    clear_retained ${lib.escapeShellArg "${cfg.legacyTopicPrefix}/state/type_result"}
    clear_retained ${lib.escapeShellArg "${cfg.legacyTopicPrefix}/status"}

    publish_retained \
      ${lib.escapeShellArg "${cfg.discoveryPrefix}/switch/${cfg.deviceId}/kodi/config"} \
      ${lib.escapeShellArg discoveryPayload}
    publish_state
    publish_retained "${cfg.topicPrefix}/status" online

    while ${pkgs.coreutils}/bin/sleep ${toString cfg.pollIntervalSeconds}; do
      publish_state || true
      publish_retained "${cfg.topicPrefix}/status" online || true
    done &
    monitor_pid=$!

    ${pkgs.mosquitto}/bin/mosquitto_sub "''${mqtt_args[@]}" \
      -i ${lib.escapeShellArg "alanix-mqtt-kodi-${cfg.deviceId}"} \
      -q 1 \
      -t ${lib.escapeShellArg "${cfg.topicPrefix}/command"} \
      --will-topic ${lib.escapeShellArg "${cfg.topicPrefix}/status"} \
      --will-payload offline \
      --will-qos 1 \
      --will-retain \
    | while IFS= read -r action; do
        case "$action" in
          ON)
            ${pkgs.sway}/bin/swaymsg exec -- \
              ${lib.escapeShellArg config.appLauncher.launchCommands.kodi} \
              >/dev/null
            ;;
          OFF)
            close_kodi
            ;;
          *)
            ;;
        esac
        publish_state || true
      done
  '';
in
{
  options.mqttKodi = {
    enable = lib.mkEnableOption "a stateful Kodi switch published to Home Assistant via MQTT";

    broker = lib.mkOption {
      type = lib.types.str;
      default = "alan-home";
      description = "MQTT broker hostname.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 1883;
      description = "MQTT broker port.";
    };

    kodiJsonRpcUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:8080/jsonrpc";
      description = "Kodi JSON-RPC endpoint used for a clean, targeted shutdown.";
    };

    pollIntervalSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2;
      description = "How often to publish whether the Kodi process is running.";
    };

    topicPrefix = lib.mkOption {
      type = lib.types.str;
      default = "${name}/kodi";
      description = "Root MQTT topic used by the Kodi switch.";
    };

    legacyTopicPrefix = lib.mkOption {
      type = lib.types.str;
      default = name;
      description = "Old launcher topic root whose retained state is removed during migration.";
    };

    discoveryPrefix = lib.mkOption {
      type = lib.types.str;
      default = "homeassistant";
      description = "Home Assistant MQTT discovery prefix.";
    };

    deviceId = lib.mkOption {
      type = lib.types.str;
      default = name;
      description = "Stable Home Assistant MQTT device identifier.";
    };

    deviceName = lib.mkOption {
      type = lib.types.str;
      default = name;
      description = "Home Assistant MQTT device name.";
    };
  };

  config = {
    _assertions = lib.optionals cfg.enable [
      {
        assertion = config.kodi.enable;
        message = "alanix.users.accounts.${name}.mqttKodi requires Kodi to be enabled.";
      }
    ];

    home.modules = lib.optionals cfg.enable [
      {
        home.packages = [ pkgs.mosquitto ];

        systemd.user.services.alanix-mqtt-kodi = {
          Unit = {
            Description = "Alanix Kodi MQTT switch";
            After = [ "graphical-session.target" "network-online.target" ];
            PartOf = [ "graphical-session.target" ];
          };
          Service = {
            ExecStart = toString bridge;
            Restart = "always";
            RestartSec = 5;
          };
          Install.WantedBy = [ "graphical-session.target" ];
        };
      }
    ];
  };
}
