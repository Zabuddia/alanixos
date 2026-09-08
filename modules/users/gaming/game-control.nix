{ config, lib, pkgs, ... }:

let
  cfg = config.gameControl;
  control = pkgs.writeShellApplication {
    name = "alanix-game-control";
    runtimeInputs = [ pkgs.coreutils pkgs.jq pkgs.procps pkgs.python3 pkgs.sway ];
    text = ''
      exec python3 ${./game-control/game_control.py} \
        --rom-root ${lib.escapeShellArg cfg.romRoot} \
        --retroarch-core ${lib.escapeShellArg "${config.retroarch.package}/lib/retroarch/cores/mupen64plus_next_libretro.so"} \
        --title-overrides-json ${lib.escapeShellArg (builtins.toJSON cfg.titleOverrides)} \
        "$@"
    '';
  };
in
{
  options.gameControl = {
    enable = lib.mkEnableOption "bounded game inventory and launcher";
    romRoot = lib.mkOption {
      type = lib.types.str;
      description = "Root containing the configured ROM platform directories.";
    };
    titleOverrides = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Human-readable titles keyed by paths relative to romRoot for images without usable metadata.";
    };
  };

  config = {
    _assertions = lib.optionals cfg.enable [
      {
        assertion = config.desktop.enable && config.desktop.profile == "sway/default";
        message = "gameControl requires the sway/default desktop profile.";
      }
      {
        assertion = config.retroarch.enable;
        message = "gameControl currently requires RetroArch for Nintendo 64 playback.";
      }
    ];
    home.modules = lib.optionals cfg.enable [{ home.packages = [ control ]; }];
  };
}
