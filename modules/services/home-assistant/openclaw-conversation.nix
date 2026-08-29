{ config, lib, pkgs-unstable, ... }:

let
  cfg = config.alanix.home-assistant.openclawConversation;

  openclawConversationComponent = pkgs-unstable.buildHomeAssistantComponent rec {
    owner = "ddrayne";
    domain = "openclaw";
    version = "1.8.1";

    src = pkgs-unstable.fetchFromGitHub {
      inherit owner;
      repo = "openclaw-homeassistant";
      tag = "v${version}";
      hash = "sha256-i8ww60/pFCpyVQyJLP1TuCaxftkpWxtm1QsIY+NZIxs=";
    };

    dependencies = [ pkgs-unstable.python3Packages.websockets ];

    meta = {
      changelog = "https://github.com/ddrayne/openclaw-homeassistant/releases/tag/v${version}";
      description = "OpenClaw conversation agent for Home Assistant Assist";
      homepage = "https://github.com/ddrayne/openclaw-homeassistant";
      license = lib.licenses.asl20;
    };
  };
in
{
  options.alanix.home-assistant.openclawConversation = {
    enable = lib.mkEnableOption "the OpenClaw conversation agent for Home Assistant Assist";

    package = lib.mkOption {
      type = lib.types.package;
      default = openclawConversationComponent;
      defaultText = lib.literalExpression "the pinned ddrayne/openclaw-homeassistant component";
      description = "Packaged OpenClaw Home Assistant custom integration to install.";
    };
  };

  config = lib.mkIf (config.alanix.home-assistant.enable && cfg.enable) {
    alanix.home-assistant.customComponents = [ cfg.package ];
  };
}
