{ config, lib, pkgs, pkgs-unstable, ... }:

let
  cfg = config.ryubing;

  joycondControllerMappings = ''
    060000004e696e74656e646f20537700,Nintendo Switch Combined Joy-Cons,a:b1,b:b0,back:b9,dpdown:b15,dpleft:b16,dpright:b17,dpup:b14,guide:b11,leftshoulder:b5,leftstick:b12,lefttrigger:b7,leftx:a0,lefty:a1,misc1:b4,rightshoulder:b6,rightstick:b13,righttrigger:b8,rightx:a2,righty:a3,start:b10,x:b2,y:b3,platform:Linux,
    060000007e0500000620000000000000,Nintendo Switch Combined Joy-Cons,a:b1,b:b0,back:b9,dpdown:b15,dpleft:b16,dpright:b17,dpup:b14,guide:b11,leftshoulder:b5,leftstick:b12,lefttrigger:b7,leftx:a0,lefty:a1,misc1:b4,rightshoulder:b6,rightstick:b13,righttrigger:b8,rightx:a2,righty:a3,start:b10,x:b2,y:b3,platform:Linux,
    060000007e0500000820000000000000,Nintendo Switch Combined Joy-Cons,a:b1,b:b0,back:b9,dpdown:b15,dpleft:b16,dpright:b17,dpup:b14,guide:b11,leftshoulder:b5,leftstick:b12,lefttrigger:b7,leftx:a0,lefty:a1,misc1:b4,rightshoulder:b6,rightstick:b13,righttrigger:b8,rightx:a2,righty:a3,start:b10,x:b2,y:b3,platform:Linux,
  '';

  managedSettings = lib.filterAttrs (_: value: value != null) {
    game_dirs = cfg.gameDirs;
    start_fullscreen = cfg.startFullscreen;
    show_confirm_exit = cfg.confirmExit;
  };
  managedSettingsJson = builtins.toJSON managedSettings;
in
{
  options.ryubing = {
    enable = lib.mkEnableOption "Ryubing for this user";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs-unstable.ryubing;
      description = "Ryubing package to install and launch.";
    };

    gameDirs = lib.mkOption {
      type = lib.types.nullOr (lib.types.listOf lib.types.str);
      default = null;
      description = "Game directories written to Ryubing's game_dirs setting.";
    };

    startFullscreen = lib.mkOption {
      type = lib.types.nullOr lib.types.bool;
      default = null;
      description = "Whether Ryubing starts games in fullscreen mode.";
    };

    confirmExit = lib.mkOption {
      type = lib.types.nullOr lib.types.bool;
      default = null;
      description = "Whether Ryubing asks for confirmation before exiting.";
    };
  };

  config.antimicrox.openRyubing.command =
    lib.mkIf cfg.enable (lib.mkDefault (lib.getExe cfg.package));

  config.home.modules = lib.optionals cfg.enable [
    ({ config, lib, ... }: {
      home.packages = [ cfg.package ];

      xdg.configFile."Ryujinx/SDL_GameControllerDB.txt".text = joycondControllerMappings;

      home.activation.writeRyubingSettings = lib.mkIf (managedSettings != { }) (lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        configDir="${config.home.homeDirectory}/.config/Ryujinx"
        configFile="$configDir/Config.json"
        mkdir -p "$configDir"
        tmpFile="$(mktemp "$configDir/.Config.json.XXXXXX")"

        if [ -f "$configFile" ]; then
          ${pkgs.jq}/bin/jq --argjson settings ${lib.escapeShellArg managedSettingsJson} \
            '. + $settings' "$configFile" > "$tmpFile"
          chmod --reference="$configFile" "$tmpFile"
        else
          printf '%s\n' ${lib.escapeShellArg managedSettingsJson} > "$tmpFile"
          chmod 600 "$tmpFile"
        fi

        mv -f "$tmpFile" "$configFile"
      '');
    })
  ];
}
