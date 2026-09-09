{ config, lib, name, pkgs, ... }:

let
  cfg = config.mqttApps;
  selectedApps = lib.getAttrs cfg.apps config.appLauncher.apps;

  device = {
    identifiers = [ cfg.deviceId ];
    name = cfg.deviceName;
    manufacturer = "Alanix";
    model = "NixOS computer";
  };

  discovery = lib.mapAttrs (appId: app: builtins.toJSON {
    name = app.label;
    unique_id = "${cfg.deviceId}_${appId}";
    default_entity_id = "switch.${appId}";
    command_topic = "${cfg.topicPrefix}/${appId}/command";
    state_topic = "${cfg.topicPrefix}/${appId}/state";
    payload_on = "ON";
    payload_off = "OFF";
    state_on = "ON";
    state_off = "OFF";
    device_class = "switch";
    availability_topic = "${cfg.topicPrefix}/status";
    payload_available = "online";
    payload_not_available = "offline";
    icon = app.icon;
    inherit device;
  }) selectedApps;

  appCases = lib.concatStringsSep "\n" (lib.mapAttrsToList (appId: app: ''
    ${lib.escapeShellArg appId})
      launch_command=${lib.escapeShellArg config.appLauncher.launchCommands.${appId}}
      close_command=${lib.escapeShellArg config.appLauncher.closeCommands.${appId}}
      running_command=${lib.escapeShellArg config.appLauncher.runningCommands.${appId}}
      ;;
  '') selectedApps);

  publishDiscovery = lib.concatStringsSep "\n" (lib.mapAttrsToList (appId: payload: ''
    publish_retained \
      ${lib.escapeShellArg "${cfg.discoveryPrefix}/switch/${cfg.deviceId}/${appId}/config"} \
      ${lib.escapeShellArg payload}
  '') discovery);

  publishAllStates = lib.concatStringsSep "\n" (map (appId: ''publish_state ${lib.escapeShellArg appId}'') cfg.apps);
  clearRetainedTopics = lib.concatMapStringsSep "\n" (topic: ''clear_retained ${lib.escapeShellArg topic}'') cfg.retainedTopicsToClear;

  bridge = pkgs.writeShellScript "alanix-mqtt-apps" ''
    set -euo pipefail

    mqtt_args=(-h ${lib.escapeShellArg cfg.broker} -p ${toString cfg.port})

    publish_retained() {
      ${pkgs.mosquitto}/bin/mosquitto_pub "''${mqtt_args[@]}" -q 1 -r -t "$1" -m "$2"
    }

    clear_retained() {
      ${pkgs.mosquitto}/bin/mosquitto_pub "''${mqtt_args[@]}" -q 1 -r -t "$1" -n
    }

    load_app() {
      case "$1" in
${appCases}
        *) return 1 ;;
      esac
    }

    app_is_running() {
      load_app "$1"
      "$running_command"
    }

    publish_state() {
      if app_is_running "$1"; then state=ON; else state=OFF; fi
      publish_retained "${cfg.topicPrefix}/$1/state" "$state"
    }

    wait_for_state() {
      app_id="$1" desired="$2"
      for _ in {1..15}; do
        if { [ "$desired" = ON ] && app_is_running "$app_id"; } \
          || { [ "$desired" = OFF ] && ! app_is_running "$app_id"; }; then
          publish_state "$app_id"
          return 0
        fi
        ${pkgs.coreutils}/bin/sleep 1
      done
      publish_state "$app_id"
      return 1
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

    ${clearRetainedTopics}
    ${publishDiscovery}
    ${publishAllStates}
    publish_retained "${cfg.topicPrefix}/status" online

    while ${pkgs.coreutils}/bin/sleep ${toString cfg.pollIntervalSeconds}; do
      ${publishAllStates}
      publish_retained "${cfg.topicPrefix}/status" online
    done &
    monitor_pid=$!

    ${pkgs.mosquitto}/bin/mosquitto_sub "''${mqtt_args[@]}" \
      -i ${lib.escapeShellArg "alanix-mqtt-apps-${cfg.deviceId}"} \
      -q 1 -v -t ${lib.escapeShellArg "${cfg.topicPrefix}/+/command"} \
      --will-topic ${lib.escapeShellArg "${cfg.topicPrefix}/status"} \
      --will-payload offline --will-qos 1 --will-retain \
    | while read -r topic action; do
        app_id="''${topic#${cfg.topicPrefix}/}"
        app_id="''${app_id%/command}"
        load_app "$app_id" || continue
        case "$action" in
          ON)
            if ! app_is_running "$app_id"; then
              ${pkgs.sway}/bin/swaymsg exec -- "$launch_command" >/dev/null
            fi
            wait_for_state "$app_id" ON || true
            ;;
          OFF)
            if app_is_running "$app_id"; then
              "$close_command" || true
            fi
            wait_for_state "$app_id" OFF || true
            ;;
        esac
      done
  '';
in
{
  options.mqttApps = {
    enable = lib.mkEnableOption "stateful application switches published through MQTT discovery";
    apps = lib.mkOption {
      type = lib.types.listOf (lib.types.strMatching "^[a-z0-9_-]+$");
      default = [ ];
      description = "Registered appLauncher application IDs exposed as switches.";
    };
    broker = lib.mkOption { type = lib.types.str; default = "alan-home"; };
    port = lib.mkOption { type = lib.types.port; default = 1883; };
    pollIntervalSeconds = lib.mkOption { type = lib.types.ints.positive; default = 2; };
    topicPrefix = lib.mkOption { type = lib.types.str; default = "${name}/apps"; };
    discoveryPrefix = lib.mkOption { type = lib.types.str; default = "homeassistant"; };
    deviceId = lib.mkOption { type = lib.types.str; default = name; };
    deviceName = lib.mkOption { type = lib.types.str; default = name; };
    retainedTopicsToClear = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Obsolete retained MQTT topics cleared during a declarative migration.";
    };
  };

  config = {
    _assertions = lib.optionals cfg.enable [
      {
        assertion = cfg.apps != [ ] && lib.length cfg.apps == lib.length (lib.unique cfg.apps);
        message = "alanix.users.accounts.${name}.mqttApps.apps must be non-empty and unique.";
      }
      {
        assertion = lib.all (appId: lib.hasAttr appId config.appLauncher.apps) cfg.apps;
        message = "alanix.users.accounts.${name}.mqttApps contains an unregistered appLauncher ID.";
      }
      {
        assertion = lib.all (appId:
          (config.appLauncher.apps.${appId}.processNames or [ ]) != [ ]
          || (config.appLauncher.apps.${appId}.commandLineContains or [ ]) != [ ]
        ) cfg.apps;
        message = "Every mqttApps application must declare processNames or commandLineContains.";
      }
    ];

    home.modules = lib.optionals cfg.enable [{
      home.packages = [ pkgs.mosquitto ];
      systemd.user.services.alanix-mqtt-apps = {
        Unit = {
          Description = "Alanix application MQTT switches";
          After = [ "graphical-session.target" "network-online.target" ];
          PartOf = [ "graphical-session.target" ];
        };
        Service = { ExecStart = toString bridge; Restart = "always"; RestartSec = 5; };
        Install.WantedBy = [ "graphical-session.target" ];
      };
    }];
  };
}
