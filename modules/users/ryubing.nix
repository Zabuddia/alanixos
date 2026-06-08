{ config, lib, pkgs, pkgs-unstable, ... }:

let
  cfg = config.ryubing;

  cemuHookControllerProfile = {
    left_joycon_stick = {
      joystick = "Left";
      invert_stick_x = false;
      invert_stick_y = false;
      rotate90_cw = false;
      stick_button = "LeftStick";
    };
    right_joycon_stick = {
      joystick = "Right";
      invert_stick_x = false;
      invert_stick_y = false;
      rotate90_cw = false;
      stick_button = "RightStick";
    };
    deadzone_left = 0.1;
    deadzone_right = 0.1;
    range_left = 1.0;
    range_right = 1.0;
    trigger_threshold = 0.5;
    motion = {
      slot = cfg.cemuHookProfile.slot;
      alt_slot = cfg.cemuHookProfile.rightJoyConSlot;
      mirror_input = false;
      dsu_server_host = cfg.cemuHookProfile.host;
      dsu_server_port = cfg.cemuHookProfile.port;
      motion_backend = "CemuHook";
      sensitivity = 100;
      gyro_deadzone = 1.0;
      enable_motion = true;
    };
    rumble = {
      strong_rumble = 1.0;
      weak_rumble = 1.0;
      enable_rumble = false;
    };
    led = {
      enable_led = false;
      turn_off_led = false;
      use_rainbow = false;
      led_color = 0;
    };
    left_joycon = {
      button_minus = "Back";
      button_l = "LeftShoulder";
      button_zl = "LeftTrigger";
      button_sl = "SingleLeftTrigger0";
      button_sr = "SingleRightTrigger0";
      dpad_up = "DpadUp";
      dpad_down = "DpadDown";
      dpad_left = "DpadLeft";
      dpad_right = "DpadRight";
    };
    right_joycon = {
      button_plus = "Start";
      button_r = "RightShoulder";
      button_zr = "RightTrigger";
      button_sl = "SingleLeftTrigger1";
      button_sr = "SingleRightTrigger1";
      button_x = "X";
      button_b = "B";
      button_y = "Y";
      button_a = "A";
    };
    version = 1;
    backend = "GamepadSDL2";
    id = "";
    name = "Nintendo Switch Controller";
    controller_type = "ProController";
    player_index = "Player1";
  };

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

    cemuHookProfile = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = config.evdevhook2.enable;
        description = "Whether to install a Ryubing controller profile configured for CemuHook motion.";
      };

      name = lib.mkOption {
        type = lib.types.str;
        default = "CemuHook Motion";
        description = "Name of the generated Ryubing controller profile.";
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

      slot = lib.mkOption {
        type = lib.types.ints.between 0 3;
        default = 0;
        description = "Primary CemuHook/DSU controller slot used by the generated profile.";
      };

      rightJoyConSlot = lib.mkOption {
        type = lib.types.ints.between 0 3;
        default = 0;
        description = "Right Joy-Con CemuHook/DSU slot used by the generated profile.";
      };
    };
  };

  config.antimicrox.openRyubing.command =
    lib.mkIf cfg.enable (lib.mkDefault (lib.getExe cfg.package));

  config.home.modules = lib.optionals cfg.enable [
    ({ config, lib, ... }: {
      home.packages = [ cfg.package ];

      xdg.configFile."Ryujinx/SDL_GameControllerDB.txt".text = joycondControllerMappings;

      xdg.configFile."Ryujinx/profiles/controller/${cfg.cemuHookProfile.name}.json" =
        lib.mkIf cfg.cemuHookProfile.enable {
          text = builtins.toJSON cemuHookControllerProfile;
          force = true;
        };

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
