{
  config,
  hostname,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.alanix.opensave;
  opensavePackage = pkgs.callPackage ./package.nix { };
  userHome = config.users.users.${cfg.user}.home;
  emulatorGames = [
    {
      name = "Azahar 3DS Saves";
      path = "${userHome}/.local/share/azahar-emu/sdmc/Nintendo 3DS";
    }
    {
      name = "Dolphin GameCube Saves";
      path = "${userHome}/.local/share/dolphin-emu/GC";
    }
    {
      name = "Dolphin Wii Saves";
      path = "${userHome}/.local/share/dolphin-emu/Wii/title";
    }
    {
      name = "melonDS Saves";
      path = "${userHome}/.local/share/melonDS/saves";
    }
    {
      name = "RetroArch Save Files";
      path = "${userHome}/.local/share/retroarch/saves";
    }
    {
      name = "RetroArch Save States";
      path = "${userHome}/.local/share/retroarch/states";
    }
    {
      name = "Ryujinx Saves";
      path = "${userHome}/.config/Ryujinx/bis/user/save";
    }
  ];
  effectiveGames = lib.optionals cfg.emulatorSaves.enable emulatorGames ++ cfg.games;
  gameType = lib.types.submodule {
    options = {
      name = lib.mkOption {
        type = lib.types.str;
        description = "Stable OpenSave name used to identify this save set across devices.";
      };

      path = lib.mkOption {
        type = lib.types.str;
        description = "Absolute path to the save data on this device.";
      };

      kind = lib.mkOption {
        type = lib.types.enum [
          "directory"
          "file"
        ];
        default = "directory";
        description = "Whether the tracked save path is a directory or a single file.";
      };
    };
  };
  provisionGame = game: ''
    save_path=${lib.escapeShellArg game.path}
    ${
      if (game.kind or "directory") == "directory" then
        ''mkdir -p "$save_path"''
      else
        ''
          mkdir -p "$(dirname "$save_path")"
          if [[ ! -e "$save_path" ]]; then
            touch "$save_path"
          fi
        ''
    }

    if ! ${opensavePackage}/bin/opensave status --json \
      | ${pkgs.jq}/bin/jq -e --arg path "$save_path" '.games[] | select(.savePath == $path)' >/dev/null; then
      ${opensavePackage}/bin/opensave add ${lib.escapeShellArg game.name} "$save_path"
    fi
  '';
  provisionScript = pkgs.writeShellScript "alanix-opensave-provision" ''
    set -euo pipefail

    export HOME=${lib.escapeShellArg userHome}
    ${opensavePackage}/bin/opensave config set device-name ${lib.escapeShellArg hostname}
    ${opensavePackage}/bin/opensave config set port ${toString cfg.port}

    ${lib.concatMapStringsSep "\n" provisionGame effectiveGames}
  '';
  autopairScript = pkgs.writeShellScript "alanix-opensave-autopair" ''
    set -euo pipefail

    export HOME=${lib.escapeShellArg userHome}
    peers_json="$(${opensavePackage}/bin/opensave peers --json 2>/dev/null || echo '{}')"

    ${lib.concatMapStringsSep "\n" (peer: ''
      if ! printf '%s' "$peers_json" \
        | ${pkgs.jq}/bin/jq -e --arg name ${lib.escapeShellArg peer} \
          '.peers[]? | select(.name == $name)' >/dev/null; then
        ${opensavePackage}/bin/opensave pair ${lib.escapeShellArg "${peer}:${toString cfg.port}"} >/dev/null 2>&1 || true
      fi
    '') cfg.peers}

    printf '%s' "$peers_json" \
      | ${pkgs.jq}/bin/jq -r --argjson names ${lib.escapeShellArg (builtins.toJSON cfg.peers)} \
        '.pairingRequests[]? | select(.deviceName as $n | $names | index($n) != null) | .peerId' \
      | while IFS= read -r peer_id; do
          [ -n "$peer_id" ] || continue
          ${opensavePackage}/bin/opensave pair approve "$peer_id" >/dev/null 2>&1 || true
        done
  '';
in
{
  options.alanix.opensave = {
    enable = lib.mkEnableOption "OpenSave peer-to-peer game-save synchronization";

    user = lib.mkOption {
      type = lib.types.str;
      default = "buddia";
      description = "Local user whose saves and OpenSave state are managed.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8383;
      description = "OpenSave REST API and peer-to-peer TCP port.";
    };

    openFirewallOnTailscale = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Allow OpenSave peer traffic on the Tailscale interface.";
    };

    emulatorSaves.enable = lib.mkEnableOption "the standard Alanix emulator save locations";

    games = lib.mkOption {
      type = lib.types.listOf gameType;
      default = [ ];
      description = "Save sets provisioned idempotently before the OpenSave daemon starts.";
    };

    peers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Other OpenSave devices (by Tailscale/Headscale hostname) to pair
        with automatically. Pairing is mutual: each side must send a
        request and have the other approve it, so every host in the mesh
        should list the others here. A periodic timer sends and approves
        pairing requests until both directions converge, so no manual
        `opensave pair`/`opensave pair approve` is ever needed.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = builtins.hasAttr cfg.user config.users.users;
        message = "alanix.opensave.user must name an existing local user.";
      }
      {
        assertion = lib.all (game: lib.hasPrefix "/" game.path) effectiveGames;
        message = "Every alanix.opensave.games path must be absolute.";
      }
      {
        assertion = !cfg.openFirewallOnTailscale || config.alanix.tailscale.enable;
        message = "alanix.opensave.openFirewallOnTailscale requires alanix.tailscale.enable.";
      }
    ];

    environment.systemPackages = [ opensavePackage ];

    networking.firewall.interfaces.${config.services.tailscale.interfaceName} = {
      allowedTCPPorts = lib.optionals cfg.openFirewallOnTailscale [ cfg.port ];
      allowedUDPPorts = lib.optionals cfg.openFirewallOnTailscale [ 8385 ];
    };

    home-manager.users.${cfg.user}.systemd.user = {
      services.opensave-daemon = {
        Unit = {
          Description = "OpenSave game-save synchronization daemon";
          Documentation = "https://github.com/Liquid-co/OpenSave";
          After = [ "network-online.target" ];
          Wants = [ "network-online.target" ];
        };

        Service = {
          Type = "simple";
          Environment = [ "HOME=${userHome}" ];
          ExecStartPre = provisionScript;
          ExecStart = "${opensavePackage}/bin/opensave daemon start";
          Restart = "on-failure";
          RestartSec = 10;
          Nice = 10;
          IOSchedulingClass = "best-effort";
          IOSchedulingPriority = 6;
        };

        Install.WantedBy = [ "default.target" ];
      };

      services.opensave-autopair = lib.mkIf (cfg.peers != [ ]) {
        Unit = {
          Description = "Converge OpenSave pairing with configured peers";
          After = [ "opensave-daemon.service" ];
          Requisite = [ "opensave-daemon.service" ];
        };

        Service = {
          Type = "oneshot";
          Environment = [ "HOME=${userHome}" ];
          ExecStart = "${autopairScript}";
        };
      };

      timers.opensave-autopair = lib.mkIf (cfg.peers != [ ]) {
        Unit.Description = "Periodic OpenSave pairing convergence";

        Timer = {
          OnStartupSec = "30s";
          OnUnitActiveSec = "2min";
        };

        Install.WantedBy = [ "timers.target" ];
      };
    };
  };
}
