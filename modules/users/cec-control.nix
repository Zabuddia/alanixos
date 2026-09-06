{ config, lib, name, pkgs, ... }:

let
  cfg = config.cecControl;

  device = {
    identifiers = [ cfg.deviceId ];
    name = cfg.deviceName;
    manufacturer = "Alanix";
    model = "NixOS media PC";
  };

  powerDiscoveryPayload = builtins.toJSON {
    name = "Power";
    unique_id = "${cfg.deviceId}_cec_power";
    command_topic = "${cfg.topicPrefix}/command/power";
    state_topic = "${cfg.topicPrefix}/state/power";
    payload_on = "ON";
    payload_off = "OFF";
    state_on = "ON";
    state_off = "OFF";
    device_class = "switch";
    availability_topic = "${cfg.topicPrefix}/status";
    payload_available = "online";
    payload_not_available = "offline";
    icon = "mdi:television";
    inherit device;
  };

  switchInputDiscoveryPayload = builtins.toJSON {
    name = "Switch Input";
    unique_id = "${cfg.deviceId}_cec_switch_input";
    command_topic = "${cfg.topicPrefix}/command/switch_input";
    payload_press = "PRESS";
    availability_topic = "${cfg.topicPrefix}/status";
    payload_available = "online";
    payload_not_available = "offline";
    icon = "mdi:hdmi-port";
    inherit device;
  };

  bridge = pkgs.writeShellScript "alanix-cec-control" ''
    set -euo pipefail

    cec_lock="''${XDG_RUNTIME_DIR:-/tmp}/alanix-cec-control.lock"

    mqtt_args=(
      -h ${lib.escapeShellArg cfg.broker}
      -p ${toString cfg.port}
    )

    publish() {
      ${pkgs.mosquitto}/bin/mosquitto_pub "''${mqtt_args[@]}" -q 1 -t "$1" -m "$2"
    }

    publish_retained() {
      ${pkgs.mosquitto}/bin/mosquitto_pub "''${mqtt_args[@]}" -q 1 -r -t "$1" -m "$2"
    }

    cec_send() {
      printf '%s\n' "$1" \
        | ${pkgs.coreutils}/bin/timeout 15 \
            ${pkgs.util-linux}/bin/flock -w 15 "$cec_lock" \
            ${pkgs.libcec}/bin/cec-client ${lib.optionalString (cfg.adapter != null) (lib.escapeShellArg cfg.adapter)} -s -d 1
    }

    poll_power_state() {
      status="$(cec_send 'pow 0' | ${pkgs.gnugrep}/bin/grep -oE 'power status: [a-z]+' | ${pkgs.coreutils}/bin/cut -d' ' -f3 || true)"
      case "$status" in
        on) publish_retained "${cfg.topicPrefix}/state/power" ON || true ;;
        standby) publish_retained "${cfg.topicPrefix}/state/power" OFF || true ;;
      esac
      return 0
    }

    poll_pid=""
    subscriber_pid=""

    cleanup() {
      if [ -n "$poll_pid" ]; then
        kill "$poll_pid" 2>/dev/null || true
        wait "$poll_pid" 2>/dev/null || true
      fi
      if [ -n "$subscriber_pid" ]; then
        kill "$subscriber_pid" 2>/dev/null || true
        wait "$subscriber_pid" 2>/dev/null || true
      fi
      publish_retained "${cfg.topicPrefix}/status" offline || true
    }
    trap cleanup EXIT

    publish_retained ${lib.escapeShellArg "${cfg.discoveryPrefix}/switch/${cfg.deviceId}/cec_power/config"} ${lib.escapeShellArg powerDiscoveryPayload}
    publish_retained ${lib.escapeShellArg "${cfg.discoveryPrefix}/button/${cfg.deviceId}/cec_switch_input/config"} ${lib.escapeShellArg switchInputDiscoveryPayload}

    poll_power_state
    while ${pkgs.coreutils}/bin/sleep ${toString cfg.pollIntervalSeconds}; do
      poll_power_state || true
    done &
    poll_pid=$!

    ${pkgs.mosquitto}/bin/mosquitto_sub "''${mqtt_args[@]}" \
      -i ${lib.escapeShellArg "alanix-cec-control-${cfg.deviceId}"} \
      -q 1 \
      -t ${lib.escapeShellArg "${cfg.topicPrefix}/command/power"} \
      -t ${lib.escapeShellArg "${cfg.topicPrefix}/command/switch_input"} \
      -F $'%t\t%p' \
      --will-topic ${lib.escapeShellArg "${cfg.topicPrefix}/status"} \
      --will-payload offline \
      --will-qos 1 \
      --will-retain \
    | while IFS=$'\t' read -r topic payload; do
        case "$topic" in
          ${lib.escapeShellArg "${cfg.topicPrefix}/command/power"})
            case "$payload" in
              ON)
                cec_send 'on 0'
                for _ in {1..5}; do
                  ${pkgs.coreutils}/bin/sleep 2
                  poll_power_state
                done
                ;;
              OFF)
                cec_send 'standby 0'
                for _ in {1..5}; do
                  ${pkgs.coreutils}/bin/sleep 2
                  poll_power_state
                done
                ;;
              *) publish "${cfg.topicPrefix}/state/error" "unsupported power payload: $payload" ;;
            esac
            ;;
          ${lib.escapeShellArg "${cfg.topicPrefix}/command/switch_input"})
            cec_send 'as'
            ;;
        esac
      done &
    subscriber_pid=$!

    # Publish online only after the long-lived subscriber has replaced any old
    # connection with the same client ID.  Otherwise an old connection's Last
    # Will can race with startup and leave a retained offline status behind.
    ${pkgs.coreutils}/bin/sleep 1
    publish_retained "${cfg.topicPrefix}/status" online

    wait "$subscriber_pid"
  '';
in
{
  options.cecControl = {
    enable = lib.mkEnableOption "an HDMI-CEC power and input bridge published to Home Assistant via MQTT";

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

    adapter = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "cec-client adapter device path, e.g. /dev/ttyACM0. Null autodetects the first CEC adapter.";
    };

    pollIntervalSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 30;
      description = "How often to poll the TV's CEC power status.";
    };

    topicPrefix = lib.mkOption {
      type = lib.types.str;
      default = name;
      description = "Root MQTT topic used by the bridge.";
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

  config.home.modules = lib.optionals cfg.enable [
    {
      systemd.user.services.alanix-cec-control = {
        Unit = {
          Description = "Alanix HDMI-CEC bridge";
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
}
