{ config, lib, pkgs, pkgs-unstable, ... }:

let
  cfg = config.eden;

  joycondControllerMappings = ''
    060000004e696e74656e646f20537700,Nintendo Switch Combined Joy-Cons,a:b1,b:b0,back:b9,dpdown:b15,dpleft:b16,dpright:b17,dpup:b14,guide:b11,leftshoulder:b5,leftstick:b12,lefttrigger:b7,leftx:a0,lefty:a1,misc1:b4,rightshoulder:b6,rightstick:b13,righttrigger:b8,rightx:a2,righty:a3,start:b10,x:b2,y:b3,platform:Linux,
    060000007e0500000620000000000000,Nintendo Switch Combined Joy-Cons,a:b1,b:b0,back:b9,dpdown:b15,dpleft:b16,dpright:b17,dpup:b14,guide:b11,leftshoulder:b5,leftstick:b12,lefttrigger:b7,leftx:a0,lefty:a1,misc1:b4,rightshoulder:b6,rightstick:b13,righttrigger:b8,rightx:a2,righty:a3,start:b10,x:b2,y:b3,platform:Linux,
    060000007e0500000820000000000000,Nintendo Switch Combined Joy-Cons,a:b1,b:b0,back:b9,dpdown:b15,dpleft:b16,dpright:b17,dpup:b14,guide:b11,leftshoulder:b5,leftstick:b12,lefttrigger:b7,leftx:a0,lefty:a1,misc1:b4,rightshoulder:b6,rightstick:b13,righttrigger:b8,rightx:a2,righty:a3,start:b10,x:b2,y:b3,platform:Linux,
  '';

  package = pkgs.symlinkJoin {
    name = "${cfg.package.name}-alanix";
    paths = [ cfg.package ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram "$out/bin/eden" \
        --set SDL_GAMECONTROLLERCONFIG ${lib.escapeShellArg joycondControllerMappings}
      wrapProgram "$out/bin/eden-cli" \
        --set SDL_GAMECONTROLLERCONFIG ${lib.escapeShellArg joycondControllerMappings}
    '';
    meta = cfg.package.meta // {
      mainProgram = "eden";
    };
  };

  f = lib.escapeShellArg;
  boolString = value: if value then "true" else "false";
  confirmStop = if cfg.confirmExit then "0" else "2";
  gameDirs = [ "SDMC" "UserNAND" "SysNAND" ] ++ lib.optionals (cfg.gameDirs != null) cfg.gameDirs;
  gameDirSettings = lib.concatStringsSep "\n" (
    lib.imap0
      (index: directory:
        ''setSetting UI ${f "Paths\\gamedirs\\${toString (index + 1)}\\path"} ${f directory}'')
      gameDirs
  );
  cemuHookMotionParam = slot:
    ''"motion:0,pad:${toString slot},port:${toString cfg.cemuHookMotion.port},guid:${cfg.cemuHookMotion.guid},engine:cemuhookudp"'';
  hasManagedSettings =
    cfg.gameDirs != null
    || cfg.startFullscreen != null
    || cfg.confirmExit != null
    || cfg.stopEmulationControllerHotkey != null
    || cfg.cemuHookMotion.enable;
in
{
  options.eden = {
    enable = lib.mkEnableOption "Eden for this user";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs-unstable.eden;
      description = "Eden package to install and launch.";
    };

    gameDirs = lib.mkOption {
      type = lib.types.nullOr (lib.types.listOf lib.types.str);
      default = null;
      description = "Additional game directories written to Eden's game list.";
    };

    startFullscreen = lib.mkOption {
      type = lib.types.nullOr lib.types.bool;
      default = null;
      description = "Whether Eden starts games in fullscreen mode.";
    };

    confirmExit = lib.mkOption {
      type = lib.types.nullOr lib.types.bool;
      default = null;
      description = "Whether Eden asks for confirmation before exiting a running game.";
    };

    stopEmulationControllerHotkey = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Eden controller-button sequence used to stop the running game, such as Home.";
    };

    cemuHookMotion = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = config.evdevhook2.enable;
        description = "Whether to configure Eden player one motion inputs from CemuHook/DSU.";
      };

      host = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
        description = "CemuHook/DSU server host.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = config.evdevhook2.port;
        description = "CemuHook/DSU server port.";
      };

      guid = lib.mkOption {
        type = lib.types.strMatching "[[:xdigit:]]{32}";
        default = "0000000000000000000000007f000001";
        description = "Eden CemuHook/DSU device GUID. The default represents 127.0.0.1.";
      };

      slot = lib.mkOption {
        type = lib.types.ints.between 0 3;
        default = 0;
        description = "Primary CemuHook/DSU controller slot.";
      };

      rightJoyConSlot = lib.mkOption {
        type = lib.types.ints.between 0 3;
        default = 0;
        description = "Right Joy-Con CemuHook/DSU controller slot.";
      };
    };
  };

  config.antimicrox.openEden.command =
    lib.mkIf cfg.enable (lib.mkDefault (lib.getExe package));

  config.home.modules = lib.optionals cfg.enable [
    ({ config, lib, ... }: {
      home.packages = [ package ];

      home.activation.writeEdenSettings = lib.mkIf hasManagedSettings (lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        configDir="${config.home.homeDirectory}/.config/eden"
        configFile="$configDir/qt-config.ini"
        mkdir -p "$configDir"
        touch "$configFile"
        chmod 600 "$configFile"

        setSetting() {
          ${pkgs.crudini}/bin/crudini --set "$configFile" "$1" "$2" "$3"
        }

        ${lib.optionalString (cfg.gameDirs != null) ''
          while IFS= read -r key; do
            if [[ "$key" == Paths\\gamedirs\\* ]]; then
              ${pkgs.crudini}/bin/crudini --del "$configFile" UI "$key"
            fi
          done < <(${pkgs.crudini}/bin/crudini --get "$configFile" UI 2>/dev/null || true)

          setSetting UI ${f "Paths\\gamedirs\\size"} ${f (toString (builtins.length gameDirs))}
          ${gameDirSettings}
        ''}

        ${lib.optionalString (cfg.startFullscreen != null) ''
          setSetting UI ${f "fullscreen\\default"} false
          setSetting UI fullscreen ${f (boolString cfg.startFullscreen)}
        ''}

        ${lib.optionalString (cfg.confirmExit != null) ''
          setSetting UI ${f "confirmStop\\default"} false
          setSetting UI confirmStop ${f confirmStop}
        ''}

        ${lib.optionalString (cfg.stopEmulationControllerHotkey != null) ''
          setSetting UI ${f "Shortcuts\\Main%20Window\\Stop%20Emulation\\Controller_KeySeq\\default"} false
          setSetting UI ${f "Shortcuts\\Main%20Window\\Stop%20Emulation\\Controller_KeySeq"} ${f cfg.stopEmulationControllerHotkey}
        ''}

        ${lib.optionalString cfg.cemuHookMotion.enable ''
          setSetting Controls ${f "udp_input_servers\\default"} false
          setSetting Controls udp_input_servers ${f "${cfg.cemuHookMotion.host}:${toString cfg.cemuHookMotion.port}"}
          setSetting Controls ${f "player_0_motionleft\\default"} false
          setSetting Controls player_0_motionleft ${f (cemuHookMotionParam cfg.cemuHookMotion.slot)}
          setSetting Controls ${f "player_0_motionright\\default"} false
          setSetting Controls player_0_motionright ${f (cemuHookMotionParam cfg.cemuHookMotion.rightJoyConSlot)}
        ''}
      '');
    })
  ];
}
