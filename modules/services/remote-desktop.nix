{ config, lib, pkgs, ... }:

let
  cfg = config.alanix.remote-desktop;
  desktopUsers = lib.filterAttrs (_: userCfg: userCfg.enable && userCfg.home.enable && userCfg.desktop.enable)
    config.alanix.users.accounts;
  desktopUserNames = builtins.attrNames desktopUsers;
  autoStartUser =
    if builtins.length desktopUserNames == 1
    then builtins.head desktopUserNames
    else null;
  wayvncLauncher = pkgs.writeShellScriptBin "alanix-wayvnc" ''
    set -eu

    runtime_dir="''${XDG_RUNTIME_DIR:-/run/user/$(${pkgs.coreutils}/bin/id -u)}"

    for _ in $(${pkgs.coreutils}/bin/seq 1 30); do
      if [ -n "''${SWAYSOCK:-}" ] && [ -S "$SWAYSOCK" ]; then
        break
      fi

      SWAYSOCK="$(${pkgs.findutils}/bin/find "$runtime_dir" -maxdepth 1 -type s -name 'sway-ipc.*.sock' | ${pkgs.coreutils}/bin/head -n1 || true)"
      export SWAYSOCK

      if [ -n "''${SWAYSOCK:-}" ] && [ -S "$SWAYSOCK" ]; then
        break
      fi

      ${pkgs.coreutils}/bin/sleep 1
    done

    if [ -z "''${SWAYSOCK:-}" ] || [ ! -S "$SWAYSOCK" ]; then
      echo "alanix-wayvnc: could not find SWAYSOCK" >&2
      exit 1
    fi

    ${
      lib.optionalString (cfg.output != null) ''
        found_output=0
        for _ in $(${pkgs.coreutils}/bin/seq 1 30); do
          if ${pkgs.sway}/bin/swaymsg -r -t get_outputs 2>/dev/null | ${pkgs.gnugrep}/bin/grep -Fq ${lib.escapeShellArg "\"name\": ${builtins.toJSON cfg.output}"}; then
            found_output=1
            break
          fi
          ${pkgs.coreutils}/bin/sleep 1
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
    ] ++ lib.optionals cfg.autoStart [
      {
        assertion = desktopUserNames != [ ];
        message = "alanix.remote-desktop.autoStart requires one enabled alanix.users.accounts entry with home.enable and desktop.enable.";
      }
      {
        assertion = builtins.length desktopUserNames <= 1;
        message = "alanix.remote-desktop.autoStart supports exactly one desktop user; found: ${lib.concatStringsSep ", " desktopUserNames}.";
      }
    ];

    networking.firewall.interfaces.wg0.allowedTCPPorts = [ cfg.port ];

    environment.systemPackages = [
      pkgs.wayvnc
      wayvncLauncher
    ];

    home-manager.users = lib.mkIf (cfg.autoStart && autoStartUser != null) {
      ${autoStartUser} = {
        systemd.user.services.alanix-wayvnc = {
          Unit = {
            Description = "WayVNC remote desktop server";
            After = [ "graphical-session.target" ];
            PartOf = [ "graphical-session.target" ];
          };

          Service = {
            ExecStart = "${wayvncLauncher}/bin/alanix-wayvnc";
            Environment = [ "XDG_RUNTIME_DIR=%t" ];
            Restart = "always";
            RestartSec = 2;
          };

          Install.WantedBy = [ "graphical-session.target" ];
        };
      };
    };
  };
}
