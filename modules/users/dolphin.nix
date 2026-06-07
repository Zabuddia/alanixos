{ config, lib, pkgs-unstable, ... }:

let
  cfg = config.dolphin;
  gameDirsConfig = lib.concatStringsSep "\n" (
    (lib.imap0 (index: directory: "ISOPath${toString index} = ${directory}") cfg.gameDirs)
    ++ [ "ISOPaths = ${toString (builtins.length cfg.gameDirs)}" ]
  );
  mkDolphinConfig = text: {
    inherit text;
    force = true;
  };
in
{
  options.dolphin = {
    enable = lib.mkEnableOption "Dolphin Emulator for this user";

    gameDirs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Game directories written to Dolphin's ISOPath settings.";
    };
  };

  config.home.modules = lib.optionals cfg.enable [
    {
      home.packages = [ pkgs-unstable.dolphin-emu ];

      xdg.configFile."dolphin-emu/Dolphin.ini" = mkDolphinConfig ''
        [Analytics]
        ID = 90cbd37d329edfd4a24683f5c5e53d6f
        PermissionAsked = True
        [General]
        WirelessMac = 00:17:ab:bf:9e:37
        ${gameDirsConfig}
        [NetPlay]
        TraversalChoice = direct
        [BluetoothPassthrough]
        Enabled = False
        [Core]
        WiimoteContinuousScanning = True
        WiimoteControllerInterface = False
        WiimoteEnableSpeaker = False
        [DSP]
        DSPThread = True
        [Input]
        BackgroundInput = False
        [SDL_Hints]
        SDL_JOYSTICK_DIRECTINPUT = 1
        SDL_JOYSTICK_ENHANCED_REPORTS = 1
        SDL_JOYSTICK_HIDAPI_COMBINE_JOY_CONS = 1
        SDL_JOYSTICK_HIDAPI_PS5_PLAYER_LED = 0
        SDL_JOYSTICK_HIDAPI_VERTICAL_JOY_CONS = 0
        SDL_JOYSTICK_WGI = 0
        [Display]
        Fullscreen = True
        [Interface]
        ConfirmStop = False
        HideCursor = True
      '';

      xdg.configFile."dolphin-emu/Hotkeys.ini" = mkDolphinConfig ''
        [Hotkeys]
        Device = SDL/0/8BitDo Ultimate 2 Wireless Controller
        General/Stop = Guide
      '';

      xdg.configFile."dolphin-emu/Profiles/GCPad/MarioKartX360.ini" = mkDolphinConfig ''
        [Profile]
        Device = SDL/0/8BitDo Ultimate 2 Wireless Controller
        Buttons/A = `Button E`
        Buttons/B = `Button S`
        Buttons/X = `Button W`
        Buttons/Y = `Button N`
        Buttons/Z = `Button N`
        Buttons/L = `Shoulder L`
        Buttons/Start = Start
        Main Stick/Up = `Left Y+`
        Main Stick/Down = `Left Y-`
        Main Stick/Left = `Left X-`
        Main Stick/Right = `Left X+`
        Main Stick/Calibration = 100.00 141.42 100.00 141.42 100.00 141.42 100.00 141.42
        C-Stick/Up = `Right Y+`
        C-Stick/Down = `Right Y-`
        C-Stick/Left = `Right X-`
        C-Stick/Right = `Right X+`
        C-Stick/Calibration = 100.00 141.42 100.00 141.42 100.00 141.42 100.00 141.42
        Triggers/L = `Trigger L`
        Triggers/R = `Trigger R`
        D-Pad/Up = `Pad N` | `Shoulder R`
        D-Pad/Down = `Pad S` | `Trigger R`
        D-Pad/Left = `Pad W`
        D-Pad/Right = `Pad E`
      '';

      xdg.configFile."dolphin-emu/Profiles/Wiimote/LegoX360.ini" = mkDolphinConfig ''
        [Profile]
        Device = SDL/0/8BitDo Ultimate 2 Wireless Controller
        Buttons/A = `Button S`
        Buttons/B = `Button W`
        Buttons/1 = `Shoulder L`
        Buttons/2 = `Shoulder R`
        Buttons/- = Back
        Buttons/+ = Start
        Buttons/Home = Guide
        D-Pad/Up = `Pad N`
        D-Pad/Down = `Pad S`
        D-Pad/Left = `Pad W`
        D-Pad/Right = `Pad E`
        IR/Up = `Right Y+`
        IR/Down = `Right Y-`
        IR/Left = `Right X-`
        IR/Right = `Right X+`
        Shake/X = `Click 2`
        Shake/Y = `Click 2`
        Shake/Z = `Click 2`
        Swing/Up = `Click 2`
        Swing/Down = `Click 2`
        Swing/Left = `Click 2`
        Swing/Right = `Click 2`
        Extension = Nunchuk
        Nunchuk/Buttons/C = `Button N` | `Trigger L` | `Trigger R`
        Nunchuk/Buttons/Z = `Button E`
        Nunchuk/Stick/Up = `Left Y+`
        Nunchuk/Stick/Down = `Left Y-`
        Nunchuk/Stick/Left = `Left X-`
        Nunchuk/Stick/Right = `Left X+`
        Nunchuk/Stick/Calibration = 100.00 141.42 100.00 141.42 100.00 141.42 100.00 141.42
      '';

      xdg.configFile."dolphin-emu/Profiles/Wiimote/MarioKartKeyboard.ini" = mkDolphinConfig ''
        [Profile]
        Device = XInput2/0/Virtual core pointer
        Buttons/A = W
        Buttons/B = Shift
        Buttons/1 = Z
        Buttons/2 = X
        Buttons/- = Q
        Buttons/+ = E
        Buttons/Home = Return
        D-Pad/Up = Up
        D-Pad/Down = Down
        D-Pad/Left = Left
        D-Pad/Right = Right
        IR/Up = `Cursor Y-`
        IR/Down = `Cursor Y+`
        IR/Left = `Cursor X-`
        IR/Right = `Cursor X+`
        Shake/X = L
        Shake/Y = L
        Shake/Z = L
        Tilt/Backward = K
        Swing/Up = K
        Extension = Nunchuk
        Nunchuk/Buttons/C = C
        Nunchuk/Buttons/Z = J
        Nunchuk/Stick/Up = W
        Nunchuk/Stick/Down = S
        Nunchuk/Stick/Left = A
        Nunchuk/Stick/Right = D
        Nunchuk/Stick/Calibration = 100.00 141.42 100.00 141.42 100.00 141.42 100.00 141.42
      '';

      xdg.configFile."dolphin-emu/Profiles/Wiimote/DSU-AlaniPhone.ini" = mkDolphinConfig ''
        [Profile]
        Device = DSUClient/0/AlaniPhone
        Buttons/A = Cross
        Buttons/B = Square
        Buttons/1 = Triangle
        Buttons/2 = Circle
        Buttons/- = Share
        Buttons/+ = Options
        Buttons/Home = PS
        D-Pad/Up = `Pad N`
        D-Pad/Down = `Pad S`
        D-Pad/Left = `Pad W`
        D-Pad/Right = `Pad E`
        IR/Up = `Cursor Y-`
        IR/Down = `Cursor Y+`
        IR/Left = `Cursor X-`
        IR/Right = `Cursor X+`
        Shake/X = `Click 2`
        Shake/Y = `Click 2`
        Shake/Z = `Click 2`
        IMUAccelerometer/Up = `Accel Up`
        IMUAccelerometer/Down = `Accel Down`
        IMUAccelerometer/Left = `Accel Left`
        IMUAccelerometer/Right = `Accel Right`
        IMUAccelerometer/Forward = `Accel Forward`
        IMUAccelerometer/Backward = `Accel Backward`
        IMUGyroscope/Pitch Up = `Gyro Pitch Up`
        IMUGyroscope/Pitch Down = `Gyro Pitch Down`
        IMUGyroscope/Roll Left = `Gyro Roll Left`
        IMUGyroscope/Roll Right = `Gyro Roll Right`
        IMUGyroscope/Yaw Left = `Gyro Yaw Left`
        IMUGyroscope/Yaw Right = `Gyro Yaw Right`
      '';

      xdg.configFile."dolphin-emu/Profiles/GCPad/SmashBrawlX360.ini" = mkDolphinConfig ''
        [Profile]
        Device = SDL/0/8BitDo Ultimate 2 Wireless Controller
        Buttons/A = `Button S`
        Buttons/B = `Button E`
        Buttons/X = `Button W`
        Buttons/Y = `Button N`
        Buttons/Z = `Shoulder R`
        Buttons/Start = Start
        Main Stick/Up = `Left Y+`
        Main Stick/Down = `Left Y-`
        Main Stick/Left = `Left X-`
        Main Stick/Right = `Left X+`
        Main Stick/Calibration = 100.00 141.42 100.00 141.42 100.00 141.42 100.00 141.42
        C-Stick/Up = `Right Y+`
        C-Stick/Down = `Right Y-`
        C-Stick/Left = `Right X-`
        C-Stick/Right = `Right X+`
        C-Stick/Calibration = 100.00 141.42 100.00 141.42 100.00 141.42 100.00 141.42
        Triggers/L = `Trigger L`
        Triggers/R = `Trigger R`
        D-Pad/Up = `Pad N`
        D-Pad/Down = `Pad S`
        D-Pad/Left = `Pad W`
        D-Pad/Right = `Pad E`
      '';

      xdg.configFile."dolphin-emu/Profiles/Wiimote/SMGalaxyX360.ini" = mkDolphinConfig ''
        [Profile]
        Device = SDL/0/8BitDo Ultimate 2 Wireless Controller
        Buttons/A = `Button S`
        Buttons/B = `Trigger R`
        Buttons/- = Back
        Buttons/+ = Start
        Buttons/Home = Guide
        D-Pad/Up = `Pad N`
        D-Pad/Down = `Pad S`
        D-Pad/Left = `Pad W`
        D-Pad/Right = `Pad E`
        IR/Up = `Right Y+`
        IR/Down = `Right Y-`
        IR/Left = `Right X-`
        IR/Right = `Right X+`
        Shake/X = `Button W` | `Button N`
        Shake/Y = `Button W` | `Button N`
        Shake/Z = `Button W` | `Button N`
        Extension = Nunchuk
        Nunchuk/Buttons/C = `Shoulder L`
        Nunchuk/Buttons/Z = `Trigger L`
        Nunchuk/Stick/Up = `Left Y+`
        Nunchuk/Stick/Down = `Left Y-`
        Nunchuk/Stick/Left = `Left X-`
        Nunchuk/Stick/Right = `Left X+`
        Nunchuk/Stick/Calibration = 100.00 141.42 100.00 141.42 100.00 141.42 100.00 141.42
      '';

      xdg.configFile."dolphin-emu/Profiles/Wiimote/NBAX360.ini" = mkDolphinConfig ''
        [Profile]
        Device = SDL/0/8BitDo Ultimate 2 Wireless Controller
        Buttons/Home = Guide
        Extension = Classic
        Classic/Buttons/A = `Button S`
        Classic/Buttons/B = `Button E`
        Classic/Buttons/X = `Button W`
        Classic/Buttons/Y = `Button N`
        Classic/Buttons/L = `Shoulder L`
        Classic/Buttons/R = `Shoulder R`
        Classic/Buttons/ZL = `Trigger L`
        Classic/Buttons/ZR = `Trigger R`
        Classic/Buttons/- = Back
        Classic/Buttons/+ = Start
        Classic/D-Pad/Up = `Pad N`
        Classic/D-Pad/Down = `Pad S`
        Classic/D-Pad/Left = `Pad W`
        Classic/D-Pad/Right = `Pad E`
        Classic/Left Stick/Up = `Left Y+`
        Classic/Left Stick/Down = `Left Y-`
        Classic/Left Stick/Left = `Left X-`
        Classic/Left Stick/Right = `Left X+`
        Classic/Left Stick/Calibration = 100.00 141.42 100.00 141.42 100.00 141.42 100.00 141.42
      '';

      xdg.configFile."dolphin-emu/Profiles/Wiimote/NSMBWXbox360.ini" = mkDolphinConfig ''
        [Profile]
        Device = SDL/0/8BitDo Ultimate 2 Wireless Controller
        Buttons/1 = `Button W`
        Buttons/2 = `Button S`
        Buttons/- = Back
        Buttons/+ = Start
        D-Pad/Up = `Pad N` | `Left Y+`
        D-Pad/Down = `Pad S` | `Left Y-`
        D-Pad/Left = `Pad W` | `Left X-`
        D-Pad/Right = `Pad E` | `Left X+`
        Shake/X = `Shoulder R` | `Trigger R`
        Shake/Y = `Shoulder R` | `Trigger R`
        Shake/Z = `Shoulder R` | `Trigger R`
        Options/Sideways Wiimote = True
      '';

      xdg.configFile."dolphin-emu/Profiles/Wiimote/StrikersX360.ini" = mkDolphinConfig ''
        [Profile]
        Device = SDL/0/8BitDo Ultimate 2 Wireless Controller
        Buttons/A = `Button S`
        Buttons/B = `Trigger R`
        Buttons/- = Back
        Buttons/+ = Start
        D-Pad/Up = `Pad N`
        D-Pad/Down = `Pad S`
        D-Pad/Left = `Pad W`
        D-Pad/Right = `Pad E`
        Shake/X = `Button W` | `Button E`
        Shake/Y = `Button W` | `Button E`
        Shake/Z = `Button W` | `Button E`
        Extension = Nunchuk
        Nunchuk/Buttons/C = `Shoulder R`
        Nunchuk/Buttons/Z = `Trigger L`
        Nunchuk/Stick/Up = `Left Y+`
        Nunchuk/Stick/Down = `Left Y-`
        Nunchuk/Stick/Left = `Left X-`
        Nunchuk/Stick/Right = `Left X+`
        Nunchuk/Stick/Calibration = 100.00 141.42 100.00 141.42 100.00 141.42 100.00 141.42
      '';

      xdg.configFile."dolphin-emu/Profiles/Wiimote/SportsMixX360.ini" = mkDolphinConfig ''
        [Profile]
        Device = SDL/0/8BitDo Ultimate 2 Wireless Controller
        Buttons/A = `Button S`
        Buttons/B = `Trigger R`
        Buttons/1 = `Button W`
        Buttons/2 = `Button E`
        Buttons/- = Back
        Buttons/+ = Start
        D-Pad/Up = `Pad N`
        D-Pad/Down = `Pad S`
        D-Pad/Left = `Pad W`
        D-Pad/Right = `Pad E`
        Shake/X = `Button N` | `Trigger R`
        Shake/Y = `Button N` | `Trigger R`
        Shake/Z = `Button N` | `Trigger R`
        Extension = Nunchuk
        Nunchuk/Buttons/C = `Shoulder R`
        Nunchuk/Buttons/Z = `Trigger L`
        Nunchuk/Stick/Up = `Left Y+`
        Nunchuk/Stick/Down = `Left Y-`
        Nunchuk/Stick/Left = `Left X-`
        Nunchuk/Stick/Right = `Left X+`
        Nunchuk/Stick/Calibration = 100.00 141.42 100.00 141.42 100.00 141.42 100.00 141.42
      '';

      xdg.configFile."dolphin-emu/Profiles/Wiimote/KirbyX360.ini" = mkDolphinConfig ''
        [Profile]
        Device = SDL/0/8BitDo Ultimate 2 Wireless Controller
        Buttons/1 = `Button W`
        Buttons/2 = `Button S`
        Buttons/A = `Shoulder R` | `Trigger R`
        Buttons/- = `Button N`
        Buttons/+ = Start
        D-Pad/Up = `Pad N` | `Left Y+`
        D-Pad/Down = `Pad S` | `Left Y-`
        D-Pad/Left = `Pad W` | `Left X-`
        D-Pad/Right = `Pad E` | `Left X+`
        Options/Sideways Wiimote = True
      '';

      xdg.configFile."dolphin-emu/Profiles/Wiimote/MaddenX360.ini" = mkDolphinConfig ''
        [Profile]
        Device = SDL/0/8BitDo Ultimate 2 Wireless Controller
        Buttons/A = `Button S`
        Buttons/B = `Trigger R`
        Buttons/- = Back
        Buttons/+ = Start
        D-Pad/Up = `Pad N`
        D-Pad/Down = `Pad S`
        D-Pad/Left = `Pad W`
        D-Pad/Right = `Pad E`
        IR/Up = `Right Y+`
        IR/Down = `Right Y-`
        IR/Left = `Right X-`
        IR/Right = `Right X+`
        Shake/X = `Shoulder R`
        Shake/Y = `Shoulder R`
        Shake/Z = `Shoulder R`
        Extension = Nunchuk
        Nunchuk/Buttons/C = `Shoulder L`
        Nunchuk/Buttons/Z = `Trigger L`
        Nunchuk/Stick/Up = `Left Y+`
        Nunchuk/Stick/Down = `Left Y-`
        Nunchuk/Stick/Left = `Left X-`
        Nunchuk/Stick/Right = `Left X+`
        Nunchuk/Stick/Calibration = 100.00 141.42 100.00 141.42 100.00 141.42 100.00 141.42
      '';

      xdg.configFile."dolphin-emu/Profiles/Wiimote/NSMBWKeyboard.ini" = mkDolphinConfig ''
        [Profile]
        Device = XInput2/0/Virtual core pointer
        Buttons/A = A
        Buttons/B = S
        Buttons/1 = Z
        Buttons/2 = X
        Buttons/- = Q
        Buttons/+ = E
        Buttons/Home = Return
        D-Pad/Up = Up
        D-Pad/Down = Down
        D-Pad/Left = Left
        D-Pad/Right = Right
        IR/Up = `Cursor Y-`
        IR/Down = `Cursor Y+`
        IR/Left = `Cursor X-`
        IR/Right = `Cursor X+`
        Shake/X = Shift
        Shake/Y = Shift
        Shake/Z = Shift
        Options/Sideways Wiimote = True
      '';
    }
  ];
}
