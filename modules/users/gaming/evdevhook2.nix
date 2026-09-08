{ config, lib, pkgs, ... }:

let
  cfg = config.evdevhook2;
  dsu = pkgs.writeShellApplication {
    name = "dsu";
    runtimeInputs = [ pkgs.python3 ];
    text = ''
      exec python3 - "$@" <<'PY'
      import pathlib
      import re
      import secrets
      import socket
      import struct
      import sys
      import time
      import zlib

      host = "127.0.0.1"
      port = ${toString cfg.port}

      if len(sys.argv) > 2:
          print("usage: dsu [HOST[:PORT]]", file=sys.stderr)
          raise SystemExit(2)
      if len(sys.argv) == 2:
          target = sys.argv[1]
          if ":" in target:
              host, port_text = target.rsplit(":", 1)
              port = int(port_text)
          else:
              host = target

      names_by_mac = {}
      try:
          blocks = pathlib.Path("/proc/bus/input/devices").read_text().split("\n\n")
          for block in blocks:
              name_match = re.search(r'^N: Name="(.+)"$', block, re.MULTILINE)
              uniq_match = re.search(r"^U: Uniq=(.+)$", block, re.MULTILINE)
              if name_match and uniq_match:
                  name = name_match.group(1).removesuffix(" (IMU)")
                  names_by_mac[uniq_match.group(1).upper()] = name
      except OSError:
          pass

      message_type = 0x100001
      body = struct.pack("<II4B", message_type, 4, 0, 1, 2, 3)
      packet = bytearray(
          struct.pack("<4sHHII", b"DSUC", 1001, len(body), 0, secrets.randbits(32)) + body
      )
      struct.pack_into("<I", packet, 8, zlib.crc32(packet))

      sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
      sock.settimeout(0.2)
      sock.sendto(packet, (host, port))

      slots = {}
      deadline = time.monotonic() + 1
      while len(slots) < 4 and time.monotonic() < deadline:
          try:
              response, _ = sock.recvfrom(1024)
          except TimeoutError:
              continue
          if len(response) < 32 or response[:4] != b"DSUS":
              continue
          response_type, slot, state, model, connection, mac, battery, _ = struct.unpack_from(
              "<I4B6s2B", response, 16
          )
          if response_type == message_type and slot < 4:
              slots[slot] = (state, connection, mac, battery)

      if not slots:
          print(f"No DSU server response from {host}:{port}", file=sys.stderr)
          raise SystemExit(1)

      connection_names = {1: "USB", 2: "Bluetooth"}
      battery_names = {
          1: "dying",
          2: "low",
          3: "medium",
          4: "high",
          5: "full",
          0xEE: "charging",
          0xEF: "charged",
      }

      print(f"DSU server {host}:{port}")
      for slot in range(4):
          state, connection, mac_bytes, battery = slots.get(slot, (0, 0, bytes(6), 0))
          if state != 2:
              print(f"Slot {slot}: empty")
              continue
          mac = ":".join(f"{byte:02X}" for byte in mac_bytes)
          name = names_by_mac.get(mac, "Unknown controller")
          details = connection_names.get(connection, "unknown connection")
          if battery in battery_names:
              details += f", battery {battery_names[battery]}"
          print(f"Slot {slot}: {name} [{mac}] ({details})")
      PY
    '';
  };
in
{
  options.evdevhook2 = {
    enable = lib.mkEnableOption "evdevhook2 CemuHook/DSU motion server";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.evdevhook2;
      description = "evdevhook2 package to install and run.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 26760;
      description = "UDP port used by the evdevhook2 DSU server.";
    };
  };

  config.home.modules = lib.optionals cfg.enable [
    ({ config, ... }:
      let
        configFilePath = "${config.xdg.configHome}/evdevhook2/config.ini";
      in
      {
        home.packages = [
          cfg.package
          dsu
        ];

        xdg.configFile."evdevhook2/config.ini".text = ''
          [Evdevhook]
          Port=${toString cfg.port}
        '';

        systemd.user.services.evdevhook2 = {
          Unit = {
            Description = "evdevhook2 CemuHook/DSU motion server";
            After = [ "graphical-session.target" ];
            PartOf = [ "graphical-session.target" ];
          };
          Service = {
            ExecStart = "${lib.getExe cfg.package} ${lib.escapeShellArg configFilePath}";
            Restart = "always";
            RestartSec = 2;
          };
          Install.WantedBy = [ "graphical-session.target" ];
        };
      })
  ];
}
