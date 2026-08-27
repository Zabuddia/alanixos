{ config, lib, name, pkgs, ... }:

let
  cfg = config.mqttLauncher;
  applicationIdle = "Choose an application";

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

  catalogEntries = lib.concatStringsSep "\n" (
    lib.mapAttrsToList
      (appId: app: ''
        add_catalog_entry ${lib.escapeShellArg app.label} ${lib.escapeShellArg "registered:${appId}"}
      '')
      cfg.apps
  );

  applicationSelectPayload = builtins.toJSON {
    name = "Application";
    unique_id = "${cfg.deviceId}_application";
    command_topic = "${cfg.topicPrefix}/command/application";
    state_topic = "${cfg.topicPrefix}/state/application";
    availability_topic = "${cfg.topicPrefix}/status";
    payload_available = "online";
    payload_not_available = "offline";
    icon = "mdi:application-cog";
    options = [ ];
    inherit device;
  };

  launchCases = lib.concatStringsSep "\n" (
    lib.mapAttrsToList
      (appName: app: ''
        ${lib.escapeShellArg appName})
          ${pkgs.sway}/bin/swaymsg exec -- ${lib.escapeShellArg app.command} >/dev/null
          publish "${cfg.topicPrefix}/state/last_launch" ${lib.escapeShellArg appName}
          return 0
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

    desktop_catalog="''${XDG_RUNTIME_DIR:?}/alanix-mqtt-desktop-apps.tsv"

    add_catalog_entry() {
      label="''${1//$'\t'/ }"
      label="''${label//$'\n'/ }"
      target="$2"
      [ -n "$label" ] || return 0
      if [ -n "''${seen_labels[$label]+set}" ]; then
        return 0
      fi
      seen_labels["$label"]=1
      printf '%s\t%s\n' "$label" "$target" >> "$desktop_catalog"
    }

    desktop_value() {
      ${pkgs.gawk}/bin/awk -v wanted="$1" '
        $0 == "[Desktop Entry]" { in_entry = 1; next }
        in_entry && /^\[/ { exit }
        in_entry && index($0, wanted "=") == 1 {
          sub("^[^=]*=", "")
          print
          exit
        }
      ' "$2"
    }

    declare -A seen_labels=()
    : > "$desktop_catalog"
    add_catalog_entry ${lib.escapeShellArg applicationIdle} idle:
    ${catalogEntries}

    data_dirs="''${XDG_DATA_HOME:-$HOME/.local/share}:''${XDG_DATA_DIRS:-/etc/profiles/per-user/$USER/share:/run/current-system/sw/share:/usr/local/share:/usr/share}"
    old_ifs="$IFS"
    IFS=:
    for data_dir in $data_dirs; do
      for desktop_path in "$data_dir"/applications/*.desktop; do
        [ -f "$desktop_path" ] || continue
        desktop_type="$(desktop_value Type "$desktop_path")"
        [ -z "$desktop_type" ] || [ "$desktop_type" = Application ] || continue
        [ "$(desktop_value Hidden "$desktop_path")" != true ] || continue
        [ "$(desktop_value NoDisplay "$desktop_path")" != true ] || continue
        desktop_name="$(desktop_value Name "$desktop_path")"
        desktop_id="$(${pkgs.coreutils}/bin/basename "$desktop_path" .desktop)"
        add_catalog_entry "$desktop_name" "desktop:$desktop_id"
      done
    done
    IFS="$old_ifs"

    ${pkgs.coreutils}/bin/sort -f -o "$desktop_catalog" "$desktop_catalog"
    application_options="$(${pkgs.jq}/bin/jq -Rsc '
      split("\n")
      | map(select(length > 0) | split("\t")[0])
    ' "$desktop_catalog")"
    application_select_payload="$(
      printf '%s' ${lib.escapeShellArg applicationSelectPayload} \
      | ${pkgs.jq}/bin/jq -c --argjson options "$application_options" '.options = $options'
    )"

    cleanup() {
      publish_retained "${cfg.topicPrefix}/status" offline || true
      ${pkgs.coreutils}/bin/rm -f -- "$desktop_catalog"
    }
    trap cleanup EXIT

    ${discoveryMessages}
    publish_retained \
      ${lib.escapeShellArg "${cfg.discoveryPrefix}/select/${cfg.deviceId}/application/config"} \
      "$application_select_payload"
    publish_retained ${lib.escapeShellArg "${cfg.topicPrefix}/state/application"} ${lib.escapeShellArg applicationIdle}
    publish_retained "${cfg.topicPrefix}/status" online

    launch_registered() {
      case "$1" in
        ${launchCases}
        *) return 1 ;;
      esac
    }

    ${pkgs.mosquitto}/bin/mosquitto_sub "''${mqtt_args[@]}" \
      -q 1 \
      -t ${lib.escapeShellArg "${cfg.topicPrefix}/command/launch"} \
      -t ${lib.escapeShellArg "${cfg.topicPrefix}/command/application"} \
      -F $'%t\t%p' \
      --will-topic ${lib.escapeShellArg "${cfg.topicPrefix}/status"} \
      --will-payload offline \
      --will-qos 1 \
      --will-retain \
    | while IFS=$'\t' read -r topic action; do
        if [ "$topic" = ${lib.escapeShellArg "${cfg.topicPrefix}/command/launch"} ]; then
          if ! launch_registered "$action"; then
            publish "${cfg.topicPrefix}/state/error" "unsupported launch action: $action"
          fi
          continue
        fi

        target=""
        while IFS=$'\t' read -r label configured_target; do
          if [ "$label" = "$action" ]; then
            target="$configured_target"
            break
          fi
        done < "$desktop_catalog"

        case "$target" in
          idle:)
            continue
            ;;
          registered:*)
            app_id="''${target#registered:}"
            if ! launch_registered "$app_id"; then
              publish "${cfg.topicPrefix}/state/error" "unsupported registered application: $app_id"
              continue
            fi
            ;;
          desktop:*)
            desktop_id="''${target#desktop:}"
            printf -v desktop_launch_command '%q %q' \
              ${lib.escapeShellArg config.appLauncher.desktopCommand} "$desktop_id"
            ${pkgs.sway}/bin/swaymsg exec -- "$desktop_launch_command" >/dev/null
            ;;
          *)
            publish "${cfg.topicPrefix}/state/error" "unknown desktop application: $action"
            continue
            ;;
        esac

        publish_retained ${lib.escapeShellArg "${cfg.topicPrefix}/state/application"} ${lib.escapeShellArg applicationIdle}
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
      default = lib.mapAttrs
        (appId: app: {
          inherit (app) label icon;
          command = config.appLauncher.launchCommands.${appId};
        })
        config.appLauncher.apps;
      defaultText = lib.literalExpression "registered appLauncher applications";
      description = "Registered applications exposed as MQTT buttons.";
    };
  };

  config = {
    appLauncher.desktop.enable = cfg.enable;

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
