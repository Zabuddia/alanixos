{ config, lib, pkgs, pkgs-unstable, ... }:

let
  cfg = config.ryubing;

  effectivePackage =
    if cfg.sdlVideoDriver == null then cfg.package
    else cfg.package.overrideAttrs (old: {
      postFixup = (old.postFixup or "") + ''
        sed -i "s|export SDL_VIDEODRIVER='x11'|export SDL_VIDEODRIVER='${cfg.sdlVideoDriver}'|" \
          "$out/bin/Ryujinx" || true
      '';
    });

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

    sdlVideoDriver = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "wayland";
      description = ''
        Override SDL_VIDEODRIVER when launching Ryubing. The nixpkgs wrapper
        forces x11 (XWayland) by default; set to "wayland" to use the native
        Wayland backend and avoid XWayland crashes on Wayland compositors.
      '';
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
    lib.mkIf cfg.enable (lib.mkDefault (lib.getExe effectivePackage));

  config.home.modules = lib.optionals cfg.enable [
    ({ config, lib, ... }: {
      home.packages = [ effectivePackage ];

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
