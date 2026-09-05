{ config, lib, pkgs, ... }:

let
  cfg = config.alanix.home-assistant.assist;
  homeAssistantCfg = config.alanix.home-assistant;
  yamlFormat = pkgs.formats.yaml { };
  customSentencesFile = yamlFormat.generate "alanix-assist-sentences.yaml" (
    lib.recursiveUpdate { language = cfg.language; } cfg.customSentences
  );
in
{
  options.alanix.home-assistant.assist = {
    enable = lib.mkEnableOption "declarative Home Assistant Assist sentences";

    language = lib.mkOption {
      type = lib.types.strMatching "^[A-Za-z0-9_-]+$";
      default = "en";
      description = "Language directory and language identifier for custom Assist sentences.";
    };

    customSentences = lib.mkOption {
      type = yamlFormat.type;
      default = { };
      description = ''
        Custom Home Assistant Assist sentence definitions. These are rendered
        to custom_sentences/<language>/alanix.yaml in the Home Assistant
        configuration directory.
      '';
    };

    intentScripts = lib.mkOption {
      type = yamlFormat.type;
      default = { };
      description = ''
        Declarative handlers for custom Assist intents. These are merged into
        Home Assistant's intent_script configuration.
      '';
    };
  };

  config = lib.mkIf (homeAssistantCfg.enable && cfg.enable) {
    alanix.home-assistant.config.intent_script = cfg.intentScripts;

    systemd.tmpfiles.rules = [
      "d ${homeAssistantCfg.configDir}/custom_sentences 0750 hass hass - -"
      "d ${homeAssistantCfg.configDir}/custom_sentences/${cfg.language} 0750 hass hass - -"
      "L+ ${homeAssistantCfg.configDir}/custom_sentences/${cfg.language}/alanix.yaml - - - - ${customSentencesFile}"
    ];
  };
}
