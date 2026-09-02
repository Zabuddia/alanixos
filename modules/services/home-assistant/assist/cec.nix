{ config, lib, ... }:

let
  cfg = config.alanix.home-assistant.assist.cec;
in
{
  options.alanix.home-assistant.assist.cec.enable =
    lib.mkEnableOption "local Home Assistant Assist commands for the alan-tv HDMI-CEC bridge";

  config = lib.mkIf cfg.enable {
    alanix.home-assistant.assist = {
      customSentences.intents = {
        HassTurnOn.data = [
          {
            sentences = [ "turn on [the] tv" "turn [the] tv on" ];
            slots.name = "alan-tv Power";
          }
        ];

        HassTurnOff.data = [
          {
            sentences = [ "turn off [the] tv" "turn [the] tv off" ];
            slots.name = "alan-tv Power";
          }
        ];

        AlanixSwitchTvInput.data = [
          {
            sentences = [
              "switch [the] [tv] input [to alan-tv]"
              "switch [to] alan-tv"
            ];
          }
        ];
      };

      intentScripts.AlanixSwitchTvInput = {
        speech.text = "Switching the TV input";
        action = [
          {
            action = "button.press";
            target.entity_id = "button.alan_tv_switch_input";
          }
        ];
      };
    };
  };
}
