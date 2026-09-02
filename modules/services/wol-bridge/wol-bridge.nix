{ config, lib, pkgs, ... }:

let
  cfg = config.alanix.wolBridge;

  hostType = lib.types.submodule ({ name, ... }: {
    options = {
      mac = lib.mkOption {
        type = lib.types.strMatching "^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$";
        description = "MAC address of the host's network interface.";
      };

      deviceId = lib.mkOption {
        type = lib.types.str;
        default = name;
        description = "Home Assistant MQTT device identifier this button is grouped under.";
      };

      deviceName = lib.mkOption {
        type = lib.types.str;
        default = name;
        description = "Home Assistant MQTT device name.";
      };

      broadcastAddress = lib.mkOption {
        type = lib.types.str;
        default = "255.255.255.255";
        description = "Broadcast address used to deliver the magic packet.";
      };
    };
  });

  discoveryPayload = hostId: hostCfg: builtins.toJSON {
    name = "Wake on LAN";
    unique_id = "wol_${hostId}";
    command_topic = "${cfg.topicPrefix}/command/${hostId}";
    payload_press = "PRESS";
    availability_topic = "${cfg.topicPrefix}/status";
    payload_available = "online";
    payload_not_available = "offline";
    icon = "mdi:lan-connect";
    device = {
      identifiers = [ hostCfg.deviceId ];
      name = hostCfg.deviceName;
      manufacturer = "Alanix";
      model = "NixOS host";
    };
  };

  discoveryMessages = lib.concatStringsSep "\n" (
    lib.mapAttrsToList
      (hostId: hostCfg: ''
        publish_retained ${lib.escapeShellArg "${cfg.discoveryPrefix}/button/wol_${hostId}/config"} ${lib.escapeShellArg (discoveryPayload hostId hostCfg)}
      '')
      cfg.hosts
  );

  wakeCases = lib.concatStringsSep "\n" (
    lib.mapAttrsToList
      (hostId: hostCfg: ''
        ${lib.escapeShellArg "${cfg.topicPrefix}/command/${hostId}"})
          ${pkgs.wakeonlan}/bin/wakeonlan -i ${lib.escapeShellArg hostCfg.broadcastAddress} ${lib.escapeShellArg hostCfg.mac} || true
          ;;
      '')
      cfg.hosts
  );

  topicArgs = lib.concatMapStringsSep " "
    (hostId: "-t ${lib.escapeShellArg "${cfg.topicPrefix}/command/${hostId}"}")
    (lib.attrNames cfg.hosts);

  bridge = pkgs.writeShellScript "alanix-wol-bridge" ''
    set -euo pipefail

    mqtt_args=(
      -h ${lib.escapeShellArg cfg.broker}
      -p ${toString cfg.port}
    )

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
      ${topicArgs} \
      -F $'%t\t%p' \
      --will-topic ${lib.escapeShellArg "${cfg.topicPrefix}/status"} \
      --will-payload offline \
      --will-qos 1 \
      --will-retain \
    | while IFS=$'\t' read -r topic _; do
        case "$topic" in
          ${wakeCases}
        esac
      done
  '';
in
{
  options.alanix.wolBridge = {
    enable = lib.mkEnableOption "a Wake-on-LAN bridge published to Home Assistant via MQTT";

    broker = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "MQTT broker hostname.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 1883;
      description = "MQTT broker port.";
    };

    topicPrefix = lib.mkOption {
      type = lib.types.str;
      default = "wol";
      description = "Root MQTT topic used by the bridge.";
    };

    discoveryPrefix = lib.mkOption {
      type = lib.types.str;
      default = "homeassistant";
      description = "Home Assistant MQTT discovery prefix.";
    };

    hosts = lib.mkOption {
      type = lib.types.attrsOf hostType;
      default = { };
      description = ''
        Hosts on the local broadcast domain that can be woken over MQTT.
        Wake-on-LAN only reaches hosts on the same physical network segment as
        this bridge, and only where the target's NIC and firmware support it
        while powered off.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.hosts != { };
        message = "alanix.wolBridge.hosts must not be empty when alanix.wolBridge.enable = true.";
      }
    ];

    systemd.services.alanix-wol-bridge = {
      description = "Alanix Wake-on-LAN bridge";
      after = [ "network-online.target" "mosquitto.service" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = toString bridge;
        DynamicUser = true;
        Restart = "always";
        RestartSec = 5;
      };
    };
  };
}
