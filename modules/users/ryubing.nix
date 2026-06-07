{ config, lib, pkgs, pkgs-unstable, ... }:

let
  cfg = config.ryubing;
  gameDirsJson = builtins.toJSON cfg.gameDirs;
in
{
  options.ryubing = {
    enable = lib.mkEnableOption "Ryubing for this user";

    gameDirs = lib.mkOption {
      type = lib.types.nullOr (lib.types.listOf lib.types.str);
      default = null;
      description = "Game directories written to Ryubing's game_dirs setting.";
    };
  };

  config.home.modules = lib.optionals cfg.enable [
    ({ config, lib, ... }: {
      home.packages = [ pkgs-unstable.ryubing ];

      home.activation.writeRyubingGameDirs = lib.mkIf (cfg.gameDirs != null) (lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        configDir="${config.home.homeDirectory}/.config/Ryujinx"
        configFile="$configDir/Config.json"
        mkdir -p "$configDir"
        tmpFile="$(mktemp "$configDir/.Config.json.XXXXXX")"

        if [ -f "$configFile" ]; then
          ${pkgs.jq}/bin/jq --argjson game_dirs ${lib.escapeShellArg gameDirsJson} \
            '.game_dirs = $game_dirs' "$configFile" > "$tmpFile"
          chmod --reference="$configFile" "$tmpFile"
        else
          ${pkgs.jq}/bin/jq --null-input --argjson game_dirs ${lib.escapeShellArg gameDirsJson} \
            '{ game_dirs: $game_dirs }' > "$tmpFile"
          chmod 600 "$tmpFile"
        fi

        mv -f "$tmpFile" "$configFile"
      '');
    })
  ];
}
