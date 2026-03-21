{ config, lib, pkgs, ... }:

let
  cfg = config.alanix.remote-desktop;
  wayvncLauncher = pkgs.writeShellScriptBin "alanix-wayvnc" ''
    set -eu

    runtime_dir="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

    if [ -z "''${SWAYSOCK:-}" ]; then
      SWAYSOCK="$(${pkgs.findutils}/bin/find "$runtime_dir" -maxdepth 1 -type s -name 'sway-ipc.*.sock' | ${pkgs.coreutils}/bin/head -n1)"
      export SWAYSOCK
    fi

    if [ -z "''${SWAYSOCK:-}" ]; then
      echo "alanix-wayvnc: could not find SWAYSOCK" >&2
      exit 1
    fi

    ${
      lib.optionalString (cfg.output != null) ''
        found_output=0
        for _ in $(seq 1 15); do
          if ${pkgs.sway}/bin/swaymsg -r -t get_outputs 2>/dev/null | ${pkgs.gnugrep}/bin/grep -Fq ${lib.escapeShellArg "\"name\": ${builtins.toJSON cfg.output}"}; then
            found_output=1
            break
          fi
          sleep 1
        done

        if [ "$found_output" -ne 1 ]; then
          echo "alanix-wayvnc: output ${cfg.output} did not appear in Sway" >&2
          exit 1
        fi
      ''
    }

    exec ${pkgs.wayvnc}/bin/wayvnc ${lib.optionalString (cfg.output != null) "-o ${lib.escapeShellArg cfg.output} "}0.0.0.0 ${toString cfg.port}
  '';
in
{
  options.alanix.remote-desktop = {
    enable = lib.mkEnableOption "wayvnc VNC remote desktop (WireGuard-restricted)";

    autoStart = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether wayvnc should start automatically from the Sway session.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 5900;
      description = "TCP port for wayvnc to listen on.";
    };

    output = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Specific Sway output for wayvnc to capture.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.alanix.wireguard.enable;
        message = "alanix.remote-desktop: requires alanix.wireguard.enable = true (VNC is restricted to wg0).";
      }
      {
        assertion = config.alanix.desktop.enable;
        message = "alanix.remote-desktop: requires alanix.desktop.enable = true.";
      }
    ];

    networking.firewall.interfaces.wg0.allowedTCPPorts = [ cfg.port ];

    environment.systemPackages = [
      pkgs.wayvnc
      wayvncLauncher
    ];

    environment.etc."sway/config.d/20-alanix-wayvnc.conf" = lib.mkIf cfg.autoStart {
      text = "exec ${wayvncLauncher}/bin/alanix-wayvnc\n";
    };
  };
}
