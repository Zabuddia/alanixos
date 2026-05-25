{ config, lib, name, nixosConfig, pkgs, pkgs-unstable, ... }:

let
  inherit (lib) types;

  cfg = config.antimicrox;
  swayActive = config.desktop.enable && config.desktop.profile == "sway/default";

  key = {
    escape = "0x1000000";
    tab = "0x1000001";
    return = "0x1000004";
    left = "0x1000012";
    up = "0x1000013";
    right = "0x1000014";
    down = "0x1000015";
    shift = "0x1000020";
    control = "0x1000021";
    super = "0x1000022";
    alt = "0x1000023";
    d = "0x44";
    e = "0x45";
    k = "0x4b";
    o = "0x4f";
    q = "0x51";
    t = "0x54";
    volumeDown = "0x1008ff11";
    volumeMute = "0x1008ff12";
    volumeUp = "0x1008ff13";
  };

  mouseButton = {
    left = "1";
    middle = "2";
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

  actionNames = builtins.attrNames actionDefinitions;

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

  changeSetSlot = setIndex: ''
                        <slot>
                            <code>${toString setIndex}</code>
                            <mode>changeset</mode>
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
    middleClick = {
      label = "Middle Click";
      slots = [ (mouseButtonSlot mouseButton.middle) ];
    };
    rightClick = {
      label = "Right Click";
      slots = [ (mouseButtonSlot mouseButton.right) ];
    };
    altTab = {
      label = "Alt+Tab";
      slots = keyboardSlots [ key.alt key.tab ];
    };
    launcher = {
      label = "Launcher";
      slots = keyboardSlots cfg.launcher.keyCodes;
    };
    keyboard = {
      label = "Keyboard";
      slots = keyboardSlots cfg.onScreenKeyboard.keyCodes;
    };
    openDolphin = {
      label = "Open Dolphin";
      slots = keyboardSlots cfg.openDolphin.keyCodes;
    };
    openThunar = {
      label = "Open Thunar";
      slots = keyboardSlots cfg.openThunar.keyCodes;
    };
    volumeUp = {
      label = "Volume Up";
      slots = keyboardSlots [ key.volumeUp ];
    };
    volumeDown = {
      label = "Volume Down";
      slots = keyboardSlots [ key.volumeDown ];
    };
    muteVolume = {
      label = "Mute Volume";
      slots = keyboardSlots [ key.volumeMute ];
    };
    closeWindow = {
      label = "Close Window";
      slots = keyboardSlots [ key.super key.shift key.q ];
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
          actionName = cfg.buttonActions.${mappedButtonName};
          action = actionDefinitions.${actionName};
        in
        buttonNameXml controllerButtonIndexes.${mappedButtonName} action.label)
      mappedButtonNames;

  controllerButtons =
    map
      (mappedButtonName:
        let
          actionName = cfg.buttonActions.${mappedButtonName};
          action = actionDefinitions.${actionName};
        in
        button controllerButtonIndexes.${mappedButtonName} action.slots)
      mappedButtonNames;

  makeMouseStickButtons = speedX: speedY: [
    (stickButton 1 { mousespeedx = speedX; mousespeedy = speedY; } [ (mouseMovementSlot mouseMovement.up) ])
    (stickButton 3 { mousespeedx = speedX; mousespeedy = speedY; } [ (mouseMovementSlot mouseMovement.right) ])
    (stickButton 5 { mousespeedx = speedX; mousespeedy = speedY; } [ (mouseMovementSlot mouseMovement.down) ])
    (stickButton 7 { mousespeedx = speedX; mousespeedy = speedY; } [ (mouseMovementSlot mouseMovement.left) ])
  ];

  scrollStickButtons = [
    (stickButton 1 { wheelspeedy = cfg.scroll.speed; } [ (mouseButtonSlot mouseButton.wheelUp) ])
    (stickButton 5 { wheelspeedy = cfg.scroll.speed; } [ (mouseButtonSlot mouseButton.wheelDown) ])
  ];

  dpadButtons = [
    (dpadButton 1 (map keyboardSlot cfg.dpad.up))
    (dpadButton 2 (map keyboardSlot cfg.dpad.right))
    (dpadButton 4 (map keyboardSlot cfg.dpad.down))
    (dpadButton 8 (map keyboardSlot cfg.dpad.left))
  ];

  precisionButtonXml = switchToSet:
    lib.optionalString (cfg.mouse.precisionButton != null)
      (button controllerButtonIndexes.${cfg.mouse.precisionButton} [ (changeSetSlot switchToSet) ]);

  makeSet = setIndex: mouseSpeedX: mouseSpeedY: switchToSet: ''
              <set index="${toString setIndex}">
                  <stick index="1">
                      <deadZone>${toString cfg.mouse.deadZone}</deadZone>
                      <maxZone>${toString cfg.mouse.maxZone}</maxZone>
                      <diagonalRange>${toString cfg.mouse.diagonalRange}</diagonalRange>
  ${lib.concatStrings (makeMouseStickButtons mouseSpeedX mouseSpeedY)}                </stick>
                  <stick index="2">
                      <deadZone>${toString cfg.scroll.deadZone}</deadZone>
                      <maxZone>${toString cfg.scroll.maxZone}</maxZone>
                      <mode>four-way</mode>
  ${lib.concatStrings scrollStickButtons}                </stick>
                  <dpad index="1">
  ${lib.concatStrings dpadButtons}                </dpad>
  ${lib.concatStrings controllerButtons}${precisionButtonXml switchToSet}          </set>
  '';

  hasPrecisionMode = cfg.mouse.precisionButton != null;

  # Launcher is handled via config.menu so Sway's built-in Mod4+d binding runs the right command.
  # All remaining bindings use extraConfig so they never conflict with or replace Sway's defaults.
  swayKeybindings =
    lib.optionalAttrs cfg.onScreenKeyboard.enable {
      "${cfg.onScreenKeyboard.keybinding}" = "exec ${keyboardToggleCommand}";
    }
    // lib.optionalAttrs cfg.openDolphin.enable {
      "${cfg.openDolphin.keybinding}" = "exec ${lib.getExe' cfg.openDolphin.package "dolphin"}";
    }
    // lib.optionalAttrs cfg.openThunar.enable {
      "${cfg.openThunar.keybinding}" = "exec ${lib.getExe cfg.openThunar.package} ${lib.escapeShellArg cfg.openThunar.path}";
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
  ${makeSet 1 cfg.mouse.speedX cfg.mouse.speedY 2}${lib.optionalString hasPrecisionMode (makeSet 2 cfg.mouse.precisionSpeedX cfg.mouse.precisionSpeedY 1)}    </sets>
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
      speedX = lib.mkOption {
        type = types.int;
        default = 60;
        description = "Horizontal cursor speed for left-stick movement.";
      };

      speedY = lib.mkOption {
        type = types.int;
        default = 60;
        description = "Vertical cursor speed for left-stick movement.";
      };

      precisionSpeedX = lib.mkOption {
        type = types.int;
        default = 15;
        description = "Horizontal cursor speed while in precision mode.";
      };

      precisionSpeedY = lib.mkOption {
        type = types.int;
        default = 15;
        description = "Vertical cursor speed while in precision mode.";
      };

      precisionButton = lib.mkOption {
        type = types.nullOr (types.enum (builtins.attrNames controllerButtonIndexes));
        default = null;
        description = "Button that toggles precision (slow) mouse mode. Must not also appear in buttonActions.";
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

    dpad = {
      up = lib.mkOption {
        type = types.listOf types.str;
        default = [ key.up ];
        description = "AntiMicroX key codes sent when d-pad up is pressed.";
      };
      right = lib.mkOption {
        type = types.listOf types.str;
        default = [ key.right ];
        description = "AntiMicroX key codes sent when d-pad right is pressed.";
      };
      down = lib.mkOption {
        type = types.listOf types.str;
        default = [ key.down ];
        description = "AntiMicroX key codes sent when d-pad down is pressed.";
      };
      left = lib.mkOption {
        type = types.listOf types.str;
        default = [ key.left ];
        description = "AntiMicroX key codes sent when d-pad left is pressed.";
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

      package = lib.mkOption {
        type = types.package;
        default = pkgs-unstable.wofi;
        description = "Launcher package to install when launcher.enable is true.";
      };

      command = lib.mkOption {
        type = types.str;
        default = "${lib.getExe cfg.launcher.package} --show drun";
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
        default = "Mod4+Ctrl+k";
        description = "Sway keybinding used to toggle the on-screen keyboard.";
      };

      keyCodes = lib.mkOption {
        type = types.listOf types.str;
        default = [ key.super key.control key.k ];
        description = "AntiMicroX key codes to send for the on-screen keyboard shortcut.";
      };
    };

    openDolphin = {
      enable = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Install dolphin and register a Sway keybinding to open it.";
      };

      package = lib.mkOption {
        type = types.package;
        default = pkgs.kdePackages.dolphin;
        description = "Dolphin package to install.";
      };

      keybinding = lib.mkOption {
        type = types.str;
        default = "Mod4+o";
        description = "Sway keybinding used to open Dolphin.";
      };

      keyCodes = lib.mkOption {
        type = types.listOf types.str;
        default = [ key.super key.o ];
        description = "AntiMicroX key codes to send for the open Dolphin shortcut.";
      };
    };

    openThunar = {
      enable = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Install Thunar and register a Sway keybinding to open it at a configured path.";
      };

      package = lib.mkOption {
        type = types.package;
        default = pkgs.xfce.thunar;
        description = "Thunar package to install.";
      };

      keybinding = lib.mkOption {
        type = types.str;
        default = "Mod4+t";
        description = "Sway keybinding used to open Thunar.";
      };

      keyCodes = lib.mkOption {
        type = types.listOf types.str;
        default = [ key.super key.t ];
        description = "AntiMicroX key codes to send for the open Thunar shortcut.";
      };

      path = lib.mkOption {
        type = types.str;
        default = "${config.home.directory}/Syncthing/media";
        description = "Path Thunar opens to.";
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
      {
        assertion = cfg.openDolphin.enable || !(usesAction "openDolphin");
        message = "alanix.users.accounts.${name}.antimicrox.buttonActions uses openDolphin, but antimicrox.openDolphin.enable is false.";
      }
      {
        assertion = cfg.openThunar.enable || !(usesAction "openThunar");
        message = "alanix.users.accounts.${name}.antimicrox.buttonActions uses openThunar, but antimicrox.openThunar.enable is false.";
      }
      {
        assertion = cfg.mouse.precisionButton == null || !(lib.hasAttr cfg.mouse.precisionButton cfg.buttonActions);
        message = "alanix.users.accounts.${name}.antimicrox.mouse.precisionButton \"${toString cfg.mouse.precisionButton}\" must not also appear in buttonActions.";
      }
    ];

    home.modules = lib.optionals cfg.enable [
      {
        home.packages =
          [ cfg.package ]
          ++ lib.optionals cfg.launcher.enable [ cfg.launcher.package ]
          ++ lib.optionals cfg.onScreenKeyboard.enable [ cfg.onScreenKeyboard.package ]
          ++ lib.optionals cfg.openDolphin.enable [ cfg.openDolphin.package ]
          ++ lib.optionals cfg.openThunar.enable [ cfg.openThunar.package ];

        xdg.configFile."antimicrox/profiles/${cfg.profile.fileName}".text = profile;

        systemd.user.services.antimicrox = lib.mkIf swayActive {
          Unit = {
            Description = "AntiMicroX controller mapping daemon";
            After = [ "graphical-session.target" ];
            PartOf = [ "graphical-session.target" ];
          };
          Service = {
            ExecStart = "${lib.getExe cfg.package} --tray --eventgen uinput --profile ${lib.escapeShellArg profilePath}";
            Restart = "on-failure";
            RestartSec = 2;
          };
          Install.WantedBy = [ "graphical-session.target" ];
        };

        wayland.windowManager.sway.config = lib.mkIf swayActive {
          menu = lib.mkIf cfg.launcher.enable cfg.launcher.command;
        };

        wayland.windowManager.sway.extraConfig = lib.mkIf (swayActive && swayKeybindings != { }) (
          lib.concatStringsSep "\n" (lib.mapAttrsToList (key: cmd: "bindsym ${key} ${cmd}") swayKeybindings)
        );
      }
    ];
  };
}
