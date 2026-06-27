{ config, lib, pkgs, nixosConfig, ... }:

let
  cfg = config.retroarch;
  syncRoot = nixosConfig.alanix.syncthing.syncRoot;

  coreNames = [
    "mupen64plus"
    "nestopia"
    "snes9x"
    "gambatte"
    "mgba"
    "genesis-plus-gx"
  ];

  defaultCores = coreNames;

  package =
    pkgs.retroarch.withCores (cores: map (core: cores.${core}) cfg.cores);

  escapeRetroarchString = builtins.replaceStrings [ "\\" "\"" ] [ "\\\\" "\\\"" ];
  retroarchString = value: "\"${escapeRetroarchString value}\"";
  retroarchBool = value: if value then "true" else "false";

  optionalBoolSetting =
    name: value:
    lib.optionalString (value != null) ''
      ${name} = ${retroarchBool value}
    '';

  optionalIntSetting =
    name: value:
    lib.optionalString (value != null) ''
      ${name} = ${toString value}
    '';

  managedDirs = [
    cfg.dataDir
    "${cfg.dataDir}/remaps"
    "${cfg.dataDir}/saves"
    "${cfg.dataDir}/screenshots"
    "${cfg.dataDir}/states"
    "${cfg.dataDir}/system"
  ];

  managedDirScript = lib.concatMapStringsSep "\n" (dir: ''mkdir -p "${dir}"'') managedDirs;
in
{
  options.retroarch = {
    enable = lib.mkEnableOption "RetroArch for this user";

    cores = lib.mkOption {
      type = lib.types.listOf (lib.types.enum coreNames);
      default = defaultCores;
      description = "Libretro cores included in the declarative RetroArch package.";
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = package;
      description = "RetroArch package to install.";
    };

    romRoot = lib.mkOption {
      type = lib.types.str;
      default = "${syncRoot}/games/roms";
      description = "Initial RetroArch file browser directory.";
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "${syncRoot}/games/retroarch";
      description = "Synced RetroArch data directory for saves, states, remaps, screenshots, and system files.";
    };

    menuDriver = lib.mkOption {
      type = lib.types.enum [ "ozone" "xmb" "rgui" "glui" ];
      default = "ozone";
      description = "RetroArch menu driver.";
    };

    startFullscreen = lib.mkOption {
      type = lib.types.nullOr lib.types.bool;
      default = null;
      description = "Whether RetroArch starts in fullscreen mode. Null keeps RetroArch's default.";
    };

    autosaveInterval = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.unsigned;
      default = 10;
      description = "Seconds between automatic SRAM save flushes. Null keeps RetroArch's default.";
    };

    menuToggleGamepadCombo = lib.mkOption {
      type = lib.types.nullOr (lib.types.ints.between 0 10);
      default = 2;
      description = "RetroArch gamepad combo for opening the menu. The default is L3 + R3.";
    };

    extraConfig = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Extra lines appended to retroarch.cfg.";
    };
  };

  config.home.modules = lib.optionals cfg.enable [
    ({ lib, ... }: {
      home.packages = [ cfg.package ];

      home.activation.createRetroarchDirs = lib.hm.dag.entryAfter [ "writeBoundary" ] managedDirScript;

      xdg.configFile."retroarch/retroarch.cfg" = {
        force = true;
        text = ''
          # Managed by alanix.
          config_save_on_exit = false
          menu_driver = ${retroarchString cfg.menuDriver}
          menu_show_core_updater = false

          rgui_browser_directory = ${retroarchString cfg.romRoot}
          libretro_directory = ${retroarchString "${cfg.package}/lib/retroarch/cores"}
          system_directory = ${retroarchString "${cfg.dataDir}/system"}
          savefile_directory = ${retroarchString "${cfg.dataDir}/saves"}
          savestate_directory = ${retroarchString "${cfg.dataDir}/states"}
          input_remapping_directory = ${retroarchString "${cfg.dataDir}/remaps"}
          screenshot_directory = ${retroarchString "${cfg.dataDir}/screenshots"}

          input_autodetect_enable = true
          input_quit_gamepad_combo = 0
          ${optionalIntSetting "input_menu_toggle_gamepad_combo" cfg.menuToggleGamepadCombo}
          ${optionalBoolSetting "video_fullscreen" cfg.startFullscreen}
          ${optionalIntSetting "autosave_interval" cfg.autosaveInterval}
          ${cfg.extraConfig}
        '';
      };
    })
  ];
}
