{ config, lib, name, nixosConfig, pkgs, pkgs-unstable, ... }:

let
  inherit (lib) types;

  cfg = config.antimicrox;
  swayActive = config.desktop.enable && config.desktop.profile == "sway/default";

  key = {
    escape = "0x1000000";
    return = "0x1000004";
    left = "0x1000012";
    up = "0x1000013";
    right = "0x1000014";
    down = "0x1000015";
    control = "0x1000021";
    super = "0x1000022";
    alt = "0x1000023";
    d = "0x44";
    k = "0x4b";
  };

  mouseButton = {
    left = "1";
    right = "3";
    wheelUp = "4";
    wheelDown = "5";
  };

  mouseMovement = {
    up = "1";
    down = "2";
    left = "3";
    right = "4";
  };

  controllerButtonIndexes = {
    a = 1;
    b = 2;
    x = 3;
    y = 4;
    back = 5;
    guide = 6;
    start = 7;
    leftStick = 8;
    rightStick = 9;
    lb = 10;
    rb = 11;
  };

  controllerButtonOrder = [
    "a"
    "b"
    "x"
    "y"
    "back"
    "guide"
    "start"
    "leftStick"
    "rightStick"
    "lb"
    "rb"
  ];

  actionNames = [
    "leftClick"
    "rightClick"
    "launcher"
    "keyboard"
    "enter"
    "escape"
  ];

  profilePath = "${config.home.directory}/.config/antimicrox/profiles/${cfg.profile.fileName}";
  keyboardProgramPath = "${cfg.onScreenKeyboard.package}/bin/${cfg.onScreenKeyboard.program}";
  keyboardLaunchCommand = lib.escapeShellArgs ([ keyboardProgramPath ] ++ cfg.onScreenKeyboard.extraArgs);
  keyboardToggleCommand = pkgs.writeShellScript "alanix-toggle-${cfg.onScreenKeyboard.program}" ''
    if ${pkgs.procps}/bin/pgrep -x ${lib.escapeShellArg cfg.onScreenKeyboard.program} >/dev/null; then
      exec ${pkgs.procps}/bin/pkill -x ${lib.escapeShellArg cfg.onScreenKeyboard.program}
    fi

    exec ${keyboardLaunchCommand}
  '';

  keyboardSlot = code: ''
                        <slot>
                            <code>${code}</code>
                            <mode>keyboard</mode>
                        </slot>
  '';

  keyboardSlots = codes: map keyboardSlot codes;

  mouseButtonSlot = code: ''
                        <slot>
                            <code>${code}</code>
                            <mode>mousebutton</mode>
                        </slot>
  '';

  mouseMovementSlot = code: ''
                        <slot>
                            <code>${code}</code>
                            <mode>mousemovement</mode>
                        </slot>
  '';

  slots = slotList: ''
                    <slots>
  ${lib.concatStrings slotList}                    </slots>
  '';

  button = index: slotList: ''
                <button index="${toString index}">
  ${slots slotList}                </button>
  '';

  buttonNameXml = index: label: ''
            <buttonname index="${toString index}">${label}</buttonname>
  '';

  dpadButton = index: slotList: ''
                <dpadbutton index="${toString index}">
  ${slots slotList}                </dpadbutton>
  '';

  stickButton = index: attrs: slotList:
    let
      attrXml = lib.concatStringsSep "\n" (lib.mapAttrsToList (attr: value: "                    <${attr}>${toString value}</${attr}>") attrs);
      attrBlock = lib.optionalString (attrXml != "") "${attrXml}\n";
      slotsBlock = lib.optionalString (slotList != [ ]) (slots slotList);
    in
    ''
                <stickbutton index="${toString index}">
  ${attrBlock}${slotsBlock}                </stickbutton>
    '';

  actionDefinitions = {
    leftClick = {
      label = "Left Click";
      slots = [ (mouseButtonSlot mouseButton.left) ];
    };
    rightClick = {
      label = "Right Click";
      slots = [ (mouseButtonSlot mouseButton.right) ];
    };
    launcher = {
      label = "Launcher";
      slots = keyboardSlots cfg.launcher.keyCodes;
    };
    keyboard = {
      label = "Keyboard";
      slots = keyboardSlots cfg.onScreenKeyboard.keyCodes;
    };
    enter = {
      label = "Enter";
      slots = keyboardSlots [ key.return ];
    };
    escape = {
      label = "Escape";
      slots = keyboardSlots [ key.escape ];
    };
  };

  configuredButtonNames = builtins.attrNames cfg.buttonActions;
  mappedButtonNames = lib.filter (buttonName: lib.hasAttr buttonName cfg.buttonActions) controllerButtonOrder;
  unknownConfiguredButtons = lib.filter (buttonName: !(lib.hasAttr buttonName controllerButtonIndexes)) configuredButtonNames;

  usesAction = actionName: lib.any (configuredAction: configuredAction == actionName) (builtins.attrValues cfg.buttonActions);

  controllerButtonNames =
    map
      (mappedButtonName:
        let
          actionName = builtins.getAttr mappedButtonName cfg.buttonActions;
          action = builtins.getAttr actionName actionDefinitions;
        in
        buttonNameXml (builtins.getAttr mappedButtonName controllerButtonIndexes) action.label)
      mappedButtonNames;

  controllerButtons =
    map
      (mappedButtonName:
        let
          actionName = builtins.getAttr mappedButtonName cfg.buttonActions;
          action = builtins.getAttr actionName actionDefinitions;
        in
        button (builtins.getAttr mappedButtonName controllerButtonIndexes) action.slots)
      mappedButtonNames;

  mouseStickButtons = [
    (stickButton 1 { mousespeedx = cfg.mouse.speed; mousespeedy = cfg.mouse.speed; } [ (mouseMovementSlot mouseMovement.up) ])
    (stickButton 3 { mousespeedx = cfg.mouse.speed; mousespeedy = cfg.mouse.speed; } [ (mouseMovementSlot mouseMovement.right) ])
    (stickButton 5 { mousespeedx = cfg.mouse.speed; mousespeedy = cfg.mouse.speed; } [ (mouseMovementSlot mouseMovement.down) ])
    (stickButton 7 { mousespeedx = cfg.mouse.speed; mousespeedy = cfg.mouse.speed; } [ (mouseMovementSlot mouseMovement.left) ])
  ];

  scrollStickButtons = [
    (stickButton 1 { wheelspeedy = cfg.scroll.speed; } [ (mouseButtonSlot mouseButton.wheelUp) ])
    (stickButton 5 { wheelspeedy = cfg.scroll.speed; } [ (mouseButtonSlot mouseButton.wheelDown) ])
  ];

  dpadButtons = [
    (dpadButton 1 [ (keyboardSlot key.up) ])
    (dpadButton 2 [ (keyboardSlot key.right) ])
    (dpadButton 4 [ (keyboardSlot key.down) ])
    (dpadButton 8 [ (keyboardSlot key.left) ])
  ];

  swayKeybindings =
    lib.optionalAttrs cfg.launcher.enable {
      "${cfg.launcher.keybinding}" = "exec ${cfg.launcher.command}";
    }
    // lib.optionalAttrs cfg.onScreenKeyboard.enable {
      "${cfg.onScreenKeyboard.keybinding}" = "exec ${keyboardToggleCommand}";
    };

  profile = ''<?xml version="1.0" encoding="UTF-8"?>
    <gamecontroller configversion="19" appversion="3.5.1">
        <sdlname>${cfg.profile.sdlName}</sdlname>
        <guid>sdlgamecontroller</guid>
        <profilename>${cfg.profile.name}</profilename>
        <names>
  ${lib.concatStrings controllerButtonNames}            <controlstickname index="1">Mouse</controlstickname>
            <controlstickname index="2">Scroll</controlstickname>
        </names>
        <sets>
            <set index="1">
                <stick index="1">
                    <deadZone>${toString cfg.mouse.deadZone}</deadZone>
                    <maxZone>${toString cfg.mouse.maxZone}</maxZone>
                    <diagonalRange>${toString cfg.mouse.diagonalRange}</diagonalRange>
  ${lib.concatStrings mouseStickButtons}                </stick>
                <stick index="2">
                    <deadZone>${toString cfg.scroll.deadZone}</deadZone>
                    <maxZone>${toString cfg.scroll.maxZone}</maxZone>
                    <mode>four-way</mode>
  ${lib.concatStrings scrollStickButtons}                </stick>
                <dpad index="1">
  ${lib.concatStrings dpadButtons}                </dpad>
  ${lib.concatStrings controllerButtons}            </set>
        </sets>
    </gamecontroller>
  '';
in
{
  options.antimicrox = {
    enable = lib.mkEnableOption "AntiMicroX desktop controller profile for this user";

    package = lib.mkOption {
      type = types.package;
      default = pkgs.antimicrox;
      description = "AntiMicroX package to install and launch.";
    };

    profile = {
      name = lib.mkOption {
        type = types.str;
        default = "Xbox Desktop";
        description = "Profile name written into the AntiMicroX profile.";
      };

      fileName = lib.mkOption {
        type = types.str;
        default = "xbox-desktop.gamecontroller.amgp";
        description = "AntiMicroX profile file name under ~/.config/antimicrox/profiles.";
      };

      sdlName = lib.mkOption {
        type = types.str;
        default = "Xbox Controller";
        description = "Informational SDL controller name written into the profile.";
      };
    };

    mouse = {
      speed = lib.mkOption {
        type = types.int;
        default = 60;
        description = "Mouse cursor speed for left-stick movement.";
      };

      deadZone = lib.mkOption {
        type = types.int;
        default = 8000;
        description = "Dead zone for left-stick mouse movement.";
      };

      maxZone = lib.mkOption {
        type = types.int;
        default = 32767;
        description = "Max zone for left-stick mouse movement.";
      };

      diagonalRange = lib.mkOption {
        type = types.int;
        default = 65;
        description = "Diagonal range for left-stick mouse movement.";
      };
    };

    scroll = {
      speed = lib.mkOption {
        type = types.int;
        default = 10;
        description = "Mouse wheel speed for right-stick vertical scrolling.";
      };

      deadZone = lib.mkOption {
        type = types.int;
        default = 8000;
        description = "Dead zone for right-stick scrolling.";
      };

      maxZone = lib.mkOption {
        type = types.int;
        default = 32767;
        description = "Max zone for right-stick scrolling.";
      };
    };

    launcher = {
      enable = lib.mkOption {
        type = types.bool;
        default = true;
        description = "Whether to declare a Sway launcher keybinding for controller activation.";
      };

      keybinding = lib.mkOption {
        type = types.str;
        default = "Mod4+d";
        description = "Sway keybinding used to open the application launcher.";
      };

      keyCodes = lib.mkOption {
        type = types.listOf types.str;
        default = [ key.super key.d ];
        description = "AntiMicroX key codes to send for the launcher shortcut.";
      };

      command = lib.mkOption {
        type = types.str;
        default = "${lib.getExe pkgs-unstable.wofi} --show drun";
        description = "Command run by the launcher keybinding.";
      };
    };

    onScreenKeyboard = {
      enable = lib.mkOption {
        type = types.bool;
        default = true;
        description = "Whether to install and declare a Sway toggle for wvkbd.";
      };

      package = lib.mkOption {
        type = types.package;
        default = pkgs.wvkbd;
        description = "wvkbd package to install.";
      };

      program = lib.mkOption {
        type = types.str;
        default = "wvkbd-mobintl";
        description = "wvkbd executable to launch and toggle.";
      };

      extraArgs = lib.mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Extra arguments passed to the wvkbd executable.";
      };

      keybinding = lib.mkOption {
        type = types.str;
        default = "Mod4+k";
        description = "Sway keybinding used to toggle the on-screen keyboard.";
      };

      keyCodes = lib.mkOption {
        type = types.listOf types.str;
        default = [ key.super key.k ];
        description = "AntiMicroX key codes to send for the on-screen keyboard shortcut.";
      };
    };

    buttonActions = lib.mkOption {
      type = types.attrsOf (types.enum actionNames);
      default = {
        a = "leftClick";
        b = "rightClick";
        y = "keyboard";
        back = "escape";
        guide = "launcher";
        start = "enter";
        lb = "launcher";
      };
      description = "Mapping from SDL gamecontroller button names to named controller actions.";
    };
  };

  config = {
    _assertions = lib.optionals cfg.enable [
      {
        assertion = swayActive;
        message = "alanix.users.accounts.${name}.antimicrox.enable requires desktop.enable = true and desktop.profile = \"sway/default\".";
      }
      {
        assertion = nixosConfig.alanix.desktop.profile == "sway";
        message = "alanix.users.accounts.${name}.antimicrox.enable requires alanix.desktop.profile = \"sway\".";
      }
      {
        assertion = unknownConfiguredButtons == [ ];
        message = "alanix.users.accounts.${name}.antimicrox.buttonActions contains unsupported buttons: ${lib.concatStringsSep ", " unknownConfiguredButtons}.";
      }
      {
        assertion = cfg.launcher.enable || !(usesAction "launcher");
        message = "alanix.users.accounts.${name}.antimicrox.buttonActions uses launcher, but antimicrox.launcher.enable is false.";
      }
      {
        assertion = cfg.onScreenKeyboard.enable || !(usesAction "keyboard");
        message = "alanix.users.accounts.${name}.antimicrox.buttonActions uses keyboard, but antimicrox.onScreenKeyboard.enable is false.";
      }
    ];

    home.modules = lib.optionals cfg.enable [
      {
        home.packages =
          [ cfg.package ]
          ++ lib.optionals cfg.launcher.enable [ pkgs-unstable.wofi ]
          ++ lib.optionals cfg.onScreenKeyboard.enable [ cfg.onScreenKeyboard.package ];

        xdg.configFile."antimicrox/profiles/${cfg.profile.fileName}".text = profile;

        wayland.windowManager.sway.config = lib.mkIf swayActive {
          startup = lib.mkAfter [
            {
              command = "${lib.getExe cfg.package} --tray --eventgen uinput --profile ${lib.escapeShellArg profilePath}";
              always = false;
            }
          ];

          keybindings = lib.mkOptionDefault swayKeybindings;
        };
      }
    ];
  };
}
