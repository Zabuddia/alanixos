{ config, lib, name, nixosConfig, pkgs, pkgs-unstable, ... }:

let
  inherit (lib) types;

  cfg = config.antimicrox;
  swayActive = config.desktop.enable && config.desktop.profile == "sway/default";
  systemctl = "/run/current-system/sw/bin/systemctl";
  waitForStatusNotifierHost = pkgs.writeShellScript "alanix-wait-for-status-notifier-host" ''
    set -eu

    attempts=0
    while [ "$attempts" -lt 120 ]; do
      if ${pkgs.systemd}/bin/busctl --user get-property \
        org.kde.StatusNotifierWatcher \
        /StatusNotifierWatcher \
        org.kde.StatusNotifierWatcher \
        IsStatusNotifierHostRegistered 2>/dev/null \
        | ${pkgs.gnugrep}/bin/grep -qx 'b true'; then
        exit 0
      fi

      attempts=$((attempts + 1))
      ${pkgs.coreutils}/bin/sleep 0.5
    done

    echo "Timed out waiting for a StatusNotifier tray host" >&2
    exit 1
  '';

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
    r = "0x52";
    s = "0x53";
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

  controllerTriggerIndexes = {
    leftTrigger = 5;
    rightTrigger = 6;
  };

  controllerTriggerOrder = [
    "leftTrigger"
    "rightTrigger"
  ];

  controllerInputIndexes = controllerButtonIndexes // controllerTriggerIndexes;

  actionNames = builtins.attrNames actionDefinitions;

  profilePath = "${config.home.directory}/.config/antimicrox/profiles/${cfg.profile.fileName}";
  gameProfilePath = "${config.home.directory}/.config/antimicrox/profiles/game-${cfg.profile.fileName}";
  settingsFilePath = "${config.home.directory}/.config/antimicrox/antimicrox_settings.ini";
  keyboardProgramPath = "${cfg.onScreenKeyboard.package}/bin/${cfg.onScreenKeyboard.program}";
  keyboardLaunchCommand = lib.escapeShellArgs ([ keyboardProgramPath ] ++ cfg.onScreenKeyboard.extraArgs);
  keyboardToggleCommand = pkgs.writeShellScript "alanix-toggle-${cfg.onScreenKeyboard.program}" ''
    if ${pkgs.procps}/bin/pgrep -x ${lib.escapeShellArg cfg.onScreenKeyboard.program} >/dev/null; then
      exec ${pkgs.procps}/bin/pkill -x ${lib.escapeShellArg cfg.onScreenKeyboard.program}
    fi

    exec ${keyboardLaunchCommand}
  '';
  openThunarCommand = lib.escapeShellArgs (
    [ (lib.getExe cfg.openThunar.package) ]
    ++ lib.optional (cfg.openThunar.path != null) cfg.openThunar.path
  );
  scrcpyLaunchCommand = pkgs.writeShellScript "alanix-scrcpy-launch" ''
    adb="${pkgs.android-tools}/bin/adb"

    if ! "$adb" devices 2>/dev/null | ${pkgs.gnugrep}/bin/grep -q $'\tdevice$'; then
      # Auto-discover wireless debugging port via mDNS (Android 11+, requires avahi)
      while IFS= read -r addr; do
        "$adb" connect "$addr" >/dev/null 2>&1 || true
      done < <("$adb" mdns services 2>/dev/null | ${pkgs.gnugrep}/bin/grep '_adb-tls-connect' | ${pkgs.gawk}/bin/awk '{print $NF}')
    fi

    exec ${lib.getExe cfg.openScrcpy.package} ${lib.escapeShellArgs cfg.openScrcpy.extraArgs}
  '';
  pauseAntimicroxCommand = name: command: processNames: pkgs.writeShellScript "alanix-${name}" ''
    set -u

    process_names=${lib.escapeShellArg (lib.concatStringsSep "\n" processNames)}
    pause_dir="''${XDG_RUNTIME_DIR:-/tmp}/alanix-antimicrox-pause"
    pause_token="$pause_dir/${name}-$$"

    process_is_running() {
      while IFS= read -r process_name; do
        [ -n "$process_name" ] || continue
        if ${pkgs.procps}/bin/pgrep -x -- "$process_name" >/dev/null 2>&1; then
          return 0
        fi
      done <<< "$process_names"
      return 1
    }

    ${pkgs.coreutils}/bin/mkdir -p "$pause_dir"
    printf '%s\n' "$$" > "$pause_token"

    was_active=0
    if ${systemctl} --user --quiet is-active antimicrox; then
      was_active=1
      ${systemctl} --user stop antimicrox || true
    fi

    cleanup() {
      ${pkgs.coreutils}/bin/rm -f "$pause_token"
      if [ "$was_active" -eq 1 ]; then
        ${systemctl} --user start antimicrox || true
      fi
    }
    trap cleanup EXIT
    trap 'trap - EXIT; cleanup; exit 130' INT
    trap 'trap - EXIT; cleanup; exit 143' HUP TERM

    ${command} &
    command_pid=$!
    command_status=0
    command_done=0
    app_seen=0
    attempts=0
    attempts_after_command=0

    while [ "$attempts" -lt 80 ]; do
      if process_is_running; then
        app_seen=1
        break
      fi

      if [ "$command_done" -eq 0 ] && ! kill -0 "$command_pid" 2>/dev/null; then
        wait "$command_pid" || command_status=$?
        command_done=1
      fi

      if [ "$command_done" -eq 1 ]; then
        attempts_after_command=$((attempts_after_command + 1))
        if [ "$attempts_after_command" -ge 20 ]; then
          break
        fi
      fi

      attempts=$((attempts + 1))
      ${pkgs.coreutils}/bin/sleep 0.25
    done

    if [ "$command_done" -eq 0 ]; then
      wait "$command_pid" || command_status=$?
    fi

    if [ "$app_seen" -eq 1 ] || process_is_running; then
      while process_is_running; do
        ${pkgs.coreutils}/bin/sleep 1
      done
    fi

    trap - EXIT
    cleanup
    exit "$command_status"
  '';

  keyboardSlot = code: ''
                        <slot>
                            <code>${code}</code>
                            <mode>keyboard</mode>
                        </slot>
  '';

  pauseSlot = milliseconds: ''
                        <slot>
                            <code>${toString milliseconds}</code>
                            <mode>pause</mode>
                        </slot>
  '';

  # Pause 0 releases the shortcut after one pulse instead of holding it until
  # the controller button is released, which would trigger keyboard repeat.
  oneShotKeyboardSlots = codes: (map keyboardSlot codes) ++ [ (pauseSlot 0) ];

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
                            <code>${toString (setIndex - 1)}</code>
                            <mode>setchange</mode>
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

  trigger = index: slotList: ''
                <trigger index="${toString index}">
                    <throttle>positivehalf</throttle>
                    <triggerbutton index="2">
  ${slots slotList}                </triggerbutton>
                </trigger>
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
      slots = oneShotKeyboardSlots [ key.alt key.tab ];
    };
    launcher = {
      label = "Launcher";
      slots = oneShotKeyboardSlots cfg.launcher.keyCodes;
    };
    keyboard = {
      label = "Keyboard";
      slots = oneShotKeyboardSlots cfg.onScreenKeyboard.keyCodes;
    };
    openKodi = {
      label = "Open Kodi";
      slots = oneShotKeyboardSlots cfg.openKodi.keyCodes;
    };
    openDolphin = {
      label = "Open Dolphin";
      slots = oneShotKeyboardSlots cfg.openDolphin.keyCodes;
    };
    openEden = {
      label = "Open Eden";
      slots = oneShotKeyboardSlots cfg.openEden.keyCodes;
    };
    openRyubing = {
      label = "Open Ryubing";
      slots = oneShotKeyboardSlots cfg.openRyubing.keyCodes;
    };
    openThunar = {
      label = "Open Thunar";
      slots = oneShotKeyboardSlots cfg.openThunar.keyCodes;
    };
    openScrcpy = {
      label = "Open Scrcpy";
      slots = oneShotKeyboardSlots cfg.openScrcpy.keyCodes;
    };
    volumeUp = {
      label = "Volume Up";
      slots = oneShotKeyboardSlots [ key.volumeUp ];
    };
    volumeDown = {
      label = "Volume Down";
      slots = oneShotKeyboardSlots [ key.volumeDown ];
    };
    muteVolume = {
      label = "Mute Volume";
      slots = oneShotKeyboardSlots [ key.volumeMute ];
    };
    closeWindow = {
      label = "Close Window";
      slots = oneShotKeyboardSlots [ key.super key.shift key.q ];
    };
    enter = {
      label = "Enter";
      slots = oneShotKeyboardSlots [ key.return ];
    };
    escape = {
      label = "Escape";
      slots = oneShotKeyboardSlots [ key.escape ];
    };
  };

  configuredButtonNames = builtins.attrNames cfg.buttonActions;
  configuredGameButtonNames = builtins.attrNames cfg.gameButtonActions;
  unknownConfiguredButtons =
    lib.filter
      (buttonName: !(lib.hasAttr buttonName controllerInputIndexes))
      (configuredButtonNames ++ configuredGameButtonNames);
  configuredActions = builtins.attrValues cfg.buttonActions ++ builtins.attrValues cfg.gameButtonActions;

  usesAction = actionName: lib.any (configuredAction: configuredAction == actionName) configuredActions;
  usesOpenKodi = usesAction "openKodi";
  usesOpenDolphin = usesAction "openDolphin";
  usesOpenEden = usesAction "openEden";
  usesOpenRyubing = usesAction "openRyubing";
  usesOpenThunar = usesAction "openThunar";
  usesOpenScrcpy = usesAction "openScrcpy";

  mappedButtonNames = actions:
    lib.filter (buttonName: lib.hasAttr buttonName actions) controllerButtonOrder;

  mappedTriggerNames = actions:
    lib.filter (triggerName: lib.hasAttr triggerName actions) controllerTriggerOrder;

  controllerButtonNames = actions:
    map
      (mappedButtonName:
        let
          actionName = actions.${mappedButtonName};
          action = actionDefinitions.${actionName};
        in
        buttonNameXml controllerButtonIndexes.${mappedButtonName} action.label)
      (mappedButtonNames actions);

  controllerTriggerNames = actions:
    map
      (mappedTriggerName:
        let
          actionName = actions.${mappedTriggerName};
          action = actionDefinitions.${actionName};
        in
        ''
            <axisbuttonname index="${toString (controllerTriggerIndexes.${mappedTriggerName})}" button="2">${action.label}</axisbuttonname>
        '')
      (mappedTriggerNames actions);

  controllerButtons = actions:
    map
      (mappedButtonName:
        let
          actionName = actions.${mappedButtonName};
          action = actionDefinitions.${actionName};
        in
        button controllerButtonIndexes.${mappedButtonName} action.slots)
      (mappedButtonNames actions);

  controllerTriggers = actions:
    map
      (mappedTriggerName:
        let
          actionName = actions.${mappedTriggerName};
          action = actionDefinitions.${actionName};
        in
        trigger controllerTriggerIndexes.${mappedTriggerName} action.slots)
      (mappedTriggerNames actions);

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

  workspaceSwitchStickButtons = lib.optionals cfg.workspaceSwitching.enable [
    (stickButton 3 { } (oneShotKeyboardSlots cfg.workspaceSwitching.nextKeyCodes))
    (stickButton 7 { } (oneShotKeyboardSlots cfg.workspaceSwitching.previousKeyCodes))
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
  ${lib.concatStrings (scrollStickButtons ++ workspaceSwitchStickButtons)}                </stick>
                  <dpad index="1">
  ${lib.concatStrings dpadButtons}                </dpad>
  ${lib.concatStrings (controllerButtons cfg.buttonActions)}${lib.concatStrings (controllerTriggers cfg.buttonActions)}${precisionButtonXml switchToSet}          </set>
  '';

  hasPrecisionMode = cfg.mouse.precisionButton != null;

  # Launcher is handled via config.menu so Sway's built-in Mod4+d binding runs the right command.
  # All remaining bindings use extraConfig so they never conflict with or replace Sway's defaults.
  swayKeybindings =
    lib.optionalAttrs cfg.onScreenKeyboard.enable {
      "${cfg.onScreenKeyboard.keybinding}" = "exec ${keyboardToggleCommand}";
    }
    // lib.optionalAttrs usesOpenKodi {
      "${cfg.openKodi.keybinding}" = "exec ${pauseAntimicroxCommand "open-kodi" cfg.openKodi.command cfg.openKodi.processNames}";
    }
    // lib.optionalAttrs usesOpenDolphin {
      "${cfg.openDolphin.keybinding}" = "exec ${cfg.openDolphin.command}";
    }
    // lib.optionalAttrs usesOpenEden {
      "${cfg.openEden.keybinding}" = "exec ${cfg.openEden.command}";
    }
    // lib.optionalAttrs usesOpenRyubing {
      "${cfg.openRyubing.keybinding}" = "exec ${cfg.openRyubing.command}";
    }
    // lib.optionalAttrs usesOpenThunar {
      "${cfg.openThunar.keybinding}" = "exec ${openThunarCommand}";
    }
    // lib.optionalAttrs usesOpenScrcpy {
      "${cfg.openScrcpy.keybinding}" = "exec ${scrcpyLaunchCommand}";
    }
    // lib.optionalAttrs cfg.workspaceSwitching.enable {
      "${cfg.workspaceSwitching.nextKeybinding}" = "workspace next";
      "${cfg.workspaceSwitching.previousKeybinding}" = "workspace prev";
    };

  profile = ''<?xml version="1.0" encoding="UTF-8"?>
    <gamecontroller configversion="19" appversion="3.5.1">
        <sdlname>${cfg.profile.sdlName}</sdlname>
        <guid>sdlgamecontroller</guid>
        <profilename>${cfg.profile.name}</profilename>
        <names>
  ${lib.concatStrings (controllerButtonNames cfg.buttonActions)}${lib.concatStrings (controllerTriggerNames cfg.buttonActions)}            <controlstickname index="1">Mouse</controlstickname>
            <controlstickname index="2">${if cfg.workspaceSwitching.enable then "Scroll / Workspaces" else "Scroll"}</controlstickname>
        </names>
        <sets>
  ${makeSet 1 cfg.mouse.speedX cfg.mouse.speedY 2}${lib.optionalString hasPrecisionMode (makeSet 2 cfg.mouse.precisionSpeedX cfg.mouse.precisionSpeedY 1)}    </sets>
    </gamecontroller>
  '';

  gameProfile = ''<?xml version="1.0" encoding="UTF-8"?>
    <gamecontroller configversion="19" appversion="3.5.1">
        <sdlname>${cfg.profile.sdlName}</sdlname>
        <guid>sdlgamecontroller</guid>
        <profilename>${cfg.profile.name} Game</profilename>
        <names>
  ${lib.concatStrings (controllerButtonNames cfg.gameButtonActions)}${lib.concatStrings (controllerTriggerNames cfg.gameButtonActions)}        </names>
        <sets>
            <set index="1">
  ${lib.concatStrings (controllerButtons cfg.gameButtonActions)}${lib.concatStrings (controllerTriggers cfg.gameButtonActions)}            </set>
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

    openKodi = {
      keybinding = lib.mkOption {
        type = types.str;
        default = "Mod4+Ctrl+o";
        description = "Sway keybinding used to open Kodi.";
      };

      keyCodes = lib.mkOption {
        type = types.listOf types.str;
        default = [ key.super key.control key.o ];
        description = "AntiMicroX key codes to send for the open Kodi shortcut.";
      };

      command = lib.mkOption {
        type = types.str;
        default = "kodi";
        description = "Command run by the Kodi keybinding. AntiMicroX is stopped while this command runs.";
      };

      processNames = lib.mkOption {
        type = types.listOf types.str;
        default = [ "kodi" "kodi.bin" ];
        description = "Process names that keep AntiMicroX paused after launching Kodi.";
      };
    };

    openDolphin = {
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

      command = lib.mkOption {
        type = types.str;
        default = "dolphin-emu";
        description = "Command run by the Dolphin keybinding.";
      };
    };

    openEden = {
      keybinding = lib.mkOption {
        type = types.str;
        default = "Mod4+Ctrl+e";
        description = "Sway keybinding used to open Eden.";
      };

      keyCodes = lib.mkOption {
        type = types.listOf types.str;
        default = [ key.super key.control key.e ];
        description = "AntiMicroX key codes to send for the open Eden shortcut.";
      };

      command = lib.mkOption {
        type = types.str;
        default = lib.getExe pkgs-unstable.eden;
        description = "Command run by the Eden keybinding.";
      };
    };

    openRyubing = {
      keybinding = lib.mkOption {
        type = types.str;
        default = "Mod4+Ctrl+r";
        description = "Sway keybinding used to open Ryubing.";
      };

      keyCodes = lib.mkOption {
        type = types.listOf types.str;
        default = [ key.super key.control key.r ];
        description = "AntiMicroX key codes to send for the open Ryubing shortcut.";
      };

      command = lib.mkOption {
        type = types.str;
        default = lib.getExe pkgs-unstable.ryubing;
        description = "Command run by the Ryubing keybinding.";
      };
    };

    openThunar = {
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
        type = types.nullOr types.str;
        default = null;
        description = "Optional path Thunar opens to. When null, Thunar uses its default location.";
      };
    };

    openScrcpy = {
      package = lib.mkOption {
        type = types.package;
        default = pkgs.scrcpy;
        description = "scrcpy package to install.";
      };

      keybinding = lib.mkOption {
        type = types.str;
        default = "Mod4+Ctrl+s";
        description = "Sway keybinding used to launch scrcpy.";
      };

      keyCodes = lib.mkOption {
        type = types.listOf types.str;
        default = [ key.super key.control key.s ];
        description = "AntiMicroX key codes to send for the scrcpy shortcut.";
      };


      extraArgs = lib.mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Extra arguments passed to scrcpy (e.g. [ \"--fullscreen\" ]).";
      };
    };

    workspaceSwitching = {
      enable = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Whether right-stick horizontal movement switches Sway workspaces.";
      };

      previousKeybinding = lib.mkOption {
        type = types.str;
        default = "Mod4+Ctrl+Left";
        description = "Sway keybinding used to focus the previous workspace.";
      };

      previousKeyCodes = lib.mkOption {
        type = types.listOf types.str;
        default = [ key.super key.control key.left ];
        description = "AntiMicroX key codes to send for focusing the previous workspace.";
      };

      nextKeybinding = lib.mkOption {
        type = types.str;
        default = "Mod4+Ctrl+Right";
        description = "Sway keybinding used to focus the next workspace.";
      };

      nextKeyCodes = lib.mkOption {
        type = types.listOf types.str;
        default = [ key.super key.control key.right ];
        description = "AntiMicroX key codes to send for focusing the next workspace.";
      };
    };

    pauseForApps = lib.mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Wayland app_ids (e.g. \"dolphin-emu\") that should pause AntiMicroX while focused so the controller passes through to the app directly.";
    };

    pauseForGameApps = lib.mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Wayland app_ids that should pause AntiMicroX only while their title looks like an active game session.";
    };

    pauseForGameAppTitlePatterns = lib.mkOption {
      type = types.attrsOf (types.listOf types.str);
      default = { };
      description = "Additional Wayland app_ids and extended regular expressions that identify active game-session window titles.";
    };

    gameButtonActions = lib.mkOption {
      type = types.attrsOf (types.enum actionNames);
      default = { };
      description = "Minimal AntiMicroX button mappings kept active while a detected game session has focus.";
    };

    gameButtonActionApps = lib.mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Wayland app_ids whose detected game sessions use gameButtonActions instead of fully pausing AntiMicroX.";
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
      description = "Mapping from SDL gamecontroller button and trigger names to named controller actions.";
    };

    controllerGuids = lib.mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Controller GUIDs to auto-assign this profile to in antimicrox_settings.ini. Each value is the GUID string as it appears after \"Controller\" in the settings file (visible after connecting the controller once).";
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
        message = "alanix.users.accounts.${name}.antimicrox button actions contain unsupported inputs: ${lib.concatStringsSep ", " unknownConfiguredButtons}.";
      }
      {
        assertion = (cfg.gameButtonActions == { }) == (cfg.gameButtonActionApps == [ ]);
        message = "alanix.users.accounts.${name}.antimicrox.gameButtonActions and gameButtonActionApps must be configured together.";
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
          ++ lib.optionals usesOpenThunar [ cfg.openThunar.package ]
          ++ lib.optionals usesOpenScrcpy [ cfg.openScrcpy.package ];

        xdg.configFile."antimicrox/profiles/${cfg.profile.fileName}".text = profile;
        xdg.configFile."antimicrox/profiles/game-${cfg.profile.fileName}".text =
          lib.mkIf (cfg.gameButtonActions != { }) gameProfile;

        home.activation.antimicroxControllerMappings = lib.mkIf (cfg.controllerGuids != [ ]) (
          let
            f = lib.escapeShellArg;
            mapGuid = guid:
              let
                prefix = "Controller${guid}";
              in
              ''
                if ! ${pkgs.gnugrep}/bin/grep -q ${f "^${prefix}ConfigFile1="} ${f settingsFilePath} 2>/dev/null; then
                  ${pkgs.gnused}/bin/sed -i ${f "/^${prefix}/d"} ${f settingsFilePath} 2>/dev/null || true
                  printf '%s\n' \
                    ${f "${prefix}ConfigFile1=${profilePath}"} \
                    ${f "${prefix}LastSelected=${profilePath}"} \
                    ${f "${prefix}ProfileName1=${cfg.profile.name}"} \
                    >> ${f settingsFilePath}
                fi
              '';
          in
          {
            after = [ "writeBoundary" ];
            before = [ ];
            data = ''
              mkdir -p ${f (builtins.dirOf settingsFilePath)}
              if [ ! -f ${f settingsFilePath} ]; then
                printf '[General]\n\n[Controllers]\n' > ${f settingsFilePath}
              elif ! ${pkgs.gnugrep}/bin/grep -qF '[Controllers]' ${f settingsFilePath}; then
                printf '\n[Controllers]\n' >> ${f settingsFilePath}
              fi
              ${lib.concatMapStrings mapGuid cfg.controllerGuids}
            '';
          }
        );

        systemd.user.services.antimicrox-focus-watcher = lib.mkIf (swayActive && (cfg.pauseForApps != [ ] || cfg.pauseForGameApps != [ ] || cfg.pauseForGameAppTitlePatterns != { })) (
          let
            pauseAppIds = cfg.pauseForApps;
            pauseGameAppIds = cfg.pauseForGameApps;
            gameButtonActionAppIds = cfg.gameButtonActionApps;
            customGameTitleChecks = lib.concatStringsSep "\n" (
              lib.flatten (
                lib.mapAttrsToList
                  (appId: patterns:
                    map
                      (pattern: ''
                        if contains_app ${lib.escapeShellArg appId} "$1" \
                          && printf '%s' "$2" | ${pkgs.gnugrep}/bin/grep -Eq -- ${lib.escapeShellArg pattern}; then
                          return 0
                        fi
                      '')
                      patterns)
                  cfg.pauseForGameAppTitlePatterns
              )
            );
            watcherScript = pkgs.writeShellScript "antimicrox-focus-watcher" ''
              pause_apps=${lib.escapeShellArg (lib.concatStringsSep "\n" pauseAppIds)}
              pause_game_apps=${lib.escapeShellArg (lib.concatStringsSep "\n" pauseGameAppIds)}
              game_button_action_apps=${lib.escapeShellArg (lib.concatStringsSep "\n" gameButtonActionAppIds)}
              pause_dir="''${XDG_RUNTIME_DIR:-/tmp}/alanix-antimicrox-pause"

              normalize_app_id() {
                printf '%s' "$1" | ${pkgs.coreutils}/bin/tr '[:upper:]' '[:lower:]'
              }

              contains_app() {
                [ -n "$1" ] && [ -n "$2" ] || return 1
                needle="$(normalize_app_id "$2")"
                while IFS= read -r configured_app; do
                  configured_app="$(normalize_app_id "$configured_app")"
                  [ -n "$configured_app" ] || continue
                  if [ "$needle" = "$configured_app" ] || [ "''${needle##*.}" = "$configured_app" ]; then
                    return 0
                  fi
                done <<< "$1"
                return 1
              }

              manual_pause_active() {
                [ -d "$pause_dir" ] || return 1
                for marker in "$pause_dir"/*; do
                  [ -e "$marker" ] || continue
                  marker_pid="$(${pkgs.coreutils}/bin/cat "$marker" 2>/dev/null || true)"
                  if [ -n "$marker_pid" ] && kill -0 "$marker_pid" 2>/dev/null; then
                    return 0
                  fi
                  ${pkgs.coreutils}/bin/rm -f "$marker"
                done
                return 1
              }

              is_game_title() {
                [ -n "$1" ] && [ -n "$2" ] || return 1
                if contains_app "$pause_game_apps" "$1" \
                  && printf '%s' "$2" | ${pkgs.gnugrep}/bin/grep -qF " | "; then
                  return 0
                fi
                ${customGameTitleChecks}
                return 1
              }

              focused_container() {
                ${pkgs.sway}/bin/swaymsg -t get_tree | ${pkgs.jq}/bin/jq -c '
                  [
                    .. | objects | select(.focused? == true) |
                    {
                      app_id: (.app_id // .window_properties.class // ""),
                      title: (.name // "")
                    }
                  ][0] // { app_id: "", title: "" }
                '
              }

              reconcile_focus() {
                change="$1"
                focused=$(focused_container 2>/dev/null || printf '%s\n' '{ "app_id": "", "title": "" }')
                app_id=$(printf '%s' "$focused" | ${pkgs.jq}/bin/jq -r '.app_id // ""')
                title=$(printf '%s' "$focused" | ${pkgs.jq}/bin/jq -r '.title // ""')
                is_pause_app=$(contains_app "$pause_apps" "$app_id" && echo yes || echo no)
                is_game_session=$(is_game_title "$app_id" "$title" && echo yes || echo no)
                is_game_button_action_app=$(contains_app "$game_button_action_apps" "$app_id" && echo yes || echo no)
                is_manual_pause=$(manual_pause_active && echo yes || echo no)
                echo "change=$change focused_app=$app_id is_manual_pause=$is_manual_pause is_pause_app=$is_pause_app is_game_session=$is_game_session is_game_button_action_app=$is_game_button_action_app title=$title"

                if [ "$is_manual_pause" = "yes" ] || [ "$is_pause_app" = "yes" ]; then
                  ${systemctl} --user stop antimicrox antimicrox-game
                elif [ "$is_game_session" = "yes" ]; then
                  ${systemctl} --user stop antimicrox
                  if [ "$is_game_button_action_app" = "yes" ]; then
                    ${systemctl} --user start antimicrox-game
                  else
                    ${systemctl} --user stop antimicrox-game
                  fi
                else
                  ${systemctl} --user stop antimicrox-game
                  ${systemctl} --user start antimicrox
                fi
              }

              reconcile_focus startup

              while true; do
                ${pkgs.coreutils}/bin/timeout 10 ${pkgs.sway}/bin/swaymsg -t subscribe '["window"]' | while IFS= read -r event; do
                  change=$(printf '%s' "$event" | ${pkgs.jq}/bin/jq -r '.change // ""')
                  reconcile_focus "$change"
                done
                ${pkgs.coreutils}/bin/sleep 1
                reconcile_focus resubscribe
              done
            '';
          in
          {
            Unit = {
              Description = "Pause AntiMicroX when listed apps have focus";
              After = [ "graphical-session.target" "antimicrox.service" ];
              PartOf = [ "graphical-session.target" ];
            };
            Service = {
              ExecStart = "${watcherScript}";
              Restart = "always";
              RestartSec = 2;
            };
            Install.WantedBy = [ "graphical-session.target" ];
          }
        );

        systemd.user.services.antimicrox = lib.mkIf swayActive {
          Unit = {
            Description = "AntiMicroX controller mapping daemon";
            After = [ "graphical-session.target" ];
            PartOf = [ "graphical-session.target" ];
          };
          Service = {
            ExecStartPre = "${waitForStatusNotifierHost}";
            ExecStart = "${lib.getExe cfg.package} --tray --hidden --eventgen uinput --log-level warn --profile ${lib.escapeShellArg profilePath}";
            Restart = "always";
            RestartSec = 2;
          };
          Install.WantedBy = [ "graphical-session.target" ];
        };

        systemd.user.services.antimicrox-game = lib.mkIf (swayActive && cfg.gameButtonActions != { }) {
          Unit = {
            Description = "AntiMicroX minimal game controller mapping";
            After = [ "graphical-session.target" ];
            PartOf = [ "graphical-session.target" ];
          };
          Service = {
            ExecStart = "${lib.getExe cfg.package} --tray --hidden --eventgen uinput --log-level warn --profile ${lib.escapeShellArg gameProfilePath}";
            Restart = "always";
            RestartSec = 2;
          };
        };

        wayland.windowManager.sway.config = lib.mkIf swayActive {
          menu = lib.mkIf cfg.launcher.enable cfg.launcher.command;
        };

        wayland.windowManager.sway.extraConfig = lib.mkIf (swayActive && swayKeybindings != { }) (
          lib.concatStringsSep "\n" (lib.mapAttrsToList (key: cmd: "bindsym --no-repeat ${key} ${cmd}") swayKeybindings)
        );
      }
    ];
  };
}
