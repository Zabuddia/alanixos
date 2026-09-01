{ config, lib, ... }:

let
  cfg = config.alanix.home-assistant.assist.kodi;
in
{
  options.alanix.home-assistant.assist.kodi.enable =
    lib.mkEnableOption "local Home Assistant Assist commands for Kodi";

  config = lib.mkIf cfg.enable {
    alanix.home-assistant.assist = {
      customSentences.intents = {
        HassTurnOn.data = [
          {
            sentences = [
              "(open|launch|start|run) [the] cody [app]"
            ];
            slots.name = "alan-tv Launch Kodi";
          }
        ];

        AlanixCloseCurrentApp.data = [
          {
            sentences = [
              "(close|quit|exit|stop) [the] current app"
              "(close|quit|exit|stop) [the] (kodi|cody) [app]"
            ];
          }
        ];
      };

      intentScripts.AlanixCloseCurrentApp = {
        speech.text = "Closing the current app";
        action = [
          {
            action = "button.press";
            target.entity_id = "button.alan_tv_close_current_app";
          }
        ];
      };
    };
  };
}
