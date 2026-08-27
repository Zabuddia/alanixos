{ config, lib, name, pkgs, ... }:

let
  cfg = config.mqttLauncher;

  appType = lib.types.submodule ({ name, ... }: {
    options = {
      label = lib.mkOption {
        type = lib.types.str;
        default = name;
        description = "Human-readable application name exposed to Home Assistant.";
      };

      icon = lib.mkOption {
        type = lib.types.str;
        default = "mdi:application";
        description = "Material Design icon exposed through MQTT discovery.";
      };

      command = lib.mkOption {
        type = lib.types.str;
        description = "Fixed command launched in the active desktop session.";
      };

      processNames = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Process names that prevent a duplicate launch.";
      };
    };
  });

  device = {
    identifiers = [ cfg.deviceId ];
    name = cfg.deviceName;
    manufacturer = "Alanix";
    model = "NixOS media PC";
  };

  discoveryMessages = lib.concatStringsSep "\n" (
    lib.mapAttrsToList
      (appName: app: let
        payload = builtins.toJSON {
          name = "Launch ${app.label}";
          unique_id = "${cfg.deviceId}_launch_${appName}";
          command_topic = "${cfg.topicPrefix}/command/launch";
          payload_press = appName;
          availability_topic = "${cfg.topicPrefix}/status";
          payload_available = "online";
          payload_not_available = "offline";
          inherit (app) icon;
          inherit device;
        };
      in ''
        publish_retained ${lib.escapeShellArg "${cfg.discoveryPrefix}/button/${cfg.deviceId}/launch_${appName}/config"} ${lib.escapeShellArg payload}
      '')
      cfg.apps
  );

  launchCases = lib.concatStringsSep "\n" (
    lib.mapAttrsToList
      (appName: app: ''
        ${lib.escapeShellArg appName})
          process_names=${lib.escapeShellArg (lib.concatStringsSep "\n" app.processNames)}
          already_running=0
          while IFS= read -r process_name; do
            [ -n "$process_name" ] || continue
            if ${pkgs.procps}/bin/pgrep -x -- "$process_name" >/dev/null 2>&1; then
              already_running=1
              break
            fi
          done <<< "$process_names"

          if [ "$already_running" -eq 0 ]; then
            ${pkgs.sway}/bin/swaymsg exec -- ${lib.escapeShellArg app.command} >/dev/null
          fi
          publish "${cfg.topicPrefix}/state/last_launch" ${lib.escapeShellArg appName}
          ;;
      '')
      cfg.apps
  );

  launcher = pkgs.writeShellScript "alanix-mqtt-launcher" ''
    set -euo pipefail

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

    cleanup() {
      publish_retained "${cfg.topicPrefix}/status" offline || true
    }
    trap cleanup EXIT

    ${discoveryMessages}
    publish_retained "${cfg.topicPrefix}/status" online

    ${pkgs.mosquitto}/bin/mosquitto_sub "''${mqtt_args[@]}" \
      -q 1 \
      -t ${lib.escapeShellArg "${cfg.topicPrefix}/command/launch"} \
      --will-topic ${lib.escapeShellArg "${cfg.topicPrefix}/status"} \
      --will-payload offline \
      --will-qos 1 \
      --will-retain \
    | while IFS= read -r action; do
        case "$action" in
          ${launchCases}
          *)
            publish "${cfg.topicPrefix}/state/error" "unsupported launch action: $action"
            ;;
        esac
      done
  '';
in
{
  options.mqttLauncher = {
    enable = lib.mkEnableOption "an allow-listed MQTT desktop application launcher";

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

    topicPrefix = lib.mkOption {
      type = lib.types.str;
      default = name;
      description = "Root MQTT topic used by the launcher.";
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

    apps = lib.mkOption {
      type = lib.types.attrsOf appType;
      default = { };
      description = "Allow-listed applications exposed as MQTT buttons.";
    };
  };

  config = {
    _assertions = lib.optionals cfg.enable [
      {
        assertion = cfg.apps != { };
        message = "alanix.users.accounts.${name}.mqttLauncher.apps must not be empty when the launcher is enabled.";
      }
    ];

    home.modules = lib.optionals cfg.enable [
      {
        home.packages = [ pkgs.mosquitto ];

        systemd.user.services.alanix-mqtt-launcher = {
          Unit = {
            Description = "Alanix MQTT application launcher";
            After = [ "graphical-session.target" "network-online.target" ];
            PartOf = [ "graphical-session.target" ];
          };
          Service = {
            ExecStart = toString launcher;
            Restart = "always";
            RestartSec = 5;
          };
          Install.WantedBy = [ "graphical-session.target" ];
        };
      }
    ];
  };
}
