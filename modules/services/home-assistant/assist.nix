{ config, lib, ... }:

let
  cfg = config.alanix.home-assistant.assist;
in
{
  options.alanix.home-assistant.assist = {
    enable = lib.mkEnableOption "Alanix Home Assistant Assist enhancements";

    weatherEntity = lib.mkOption {
      type = lib.types.str;
      default = "weather.forecast_home";
      description = "Weather entity whose forecast is made available to the LLM.";
    };

    alanTvMediaPlayer = lib.mkOption {
      type = lib.types.str;
      default = "media_player.alan_tv";
      description = "Kodi media player entity controlled by local voice commands.";
    };

    alanTvApplicationSelect = lib.mkOption {
      type = lib.types.str;
      default = "select.alan_tv_application";
      description = "MQTT application selector for alan-tv.";
    };

    alanTvCloseButton = lib.mkOption {
      type = lib.types.str;
      default = "button.alan_tv_close_current_app";
      description = "MQTT button that closes the focused alan-tv application.";
    };

    alanTvTypeText = lib.mkOption {
      type = lib.types.str;
      default = "text.alan_tv_type_text";
      description = "MQTT text entity used to type on alan-tv.";
    };
  };

  config = lib.mkIf (config.alanix.home-assistant.enable && cfg.enable) {
    alanix.home-assistant.config = {
      automation = [
        {
          id = "alan_tv_local_media_controls";
          alias = "Local voice controls for alan-tv media";
          description = ''
            Handle simple alan-tv transport and volume commands locally so
            they do not need the LLM conversation agent.
          '';
          triggers = [
            {
              trigger = "conversation";
              id = "pause";
              command = [
                "(pause|freeze) [the] (movie|video|show) [on (alan|allen) tv]"
              ];
            }
            {
              trigger = "conversation";
              id = "resume";
              command = [
                "(play|resume|continue|unpause) [the] (movie|video|show) [on (alan|allen) tv]"
              ];
            }
            {
              trigger = "conversation";
              id = "stop";
              command = [
                "(stop|end) [the] (movie|video|show) [on (alan|allen) tv]"
              ];
            }
            {
              trigger = "conversation";
              id = "volume_up";
              command = [
                "(turn|raise) [the] volume up [on (alan|allen) tv]"
                "volume up [on (alan|allen) tv]"
              ];
            }
            {
              trigger = "conversation";
              id = "volume_down";
              command = [
                "(turn|lower) [the] volume down [on (alan|allen) tv]"
                "volume down [on (alan|allen) tv]"
              ];
            }
            {
              trigger = "conversation";
              id = "mute";
              command = [
                "mute [the] (movie|tv|television) [on (alan|allen) tv]"
              ];
            }
            {
              trigger = "conversation";
              id = "unmute";
              command = [
                "unmute [the] (movie|tv|television) [on (alan|allen) tv]"
              ];
            }
            {
              trigger = "conversation";
              id = "subtitles_on";
              command = [
                "(turn|switch) [the] subtitles on [for [the] (movie|video|show)] [on (alan|allen) tv]"
                "(turn|switch) on [the] subtitles [for [the] (movie|video|show)] [on (alan|allen) tv]"
                "enable [the] subtitles [for [the] (movie|video|show)] [on (alan|allen) tv]"
              ];
            }
            {
              trigger = "conversation";
              id = "subtitles_off";
              command = [
                "(turn|switch) [the] subtitles off [for [the] (movie|video|show)] [on (alan|allen) tv]"
                "(turn|switch) off [the] subtitles [for [the] (movie|video|show)] [on (alan|allen) tv]"
                "disable [the] subtitles [for [the] (movie|video|show)] [on (alan|allen) tv]"
              ];
            }
            {
              trigger = "conversation";
              id = "subtitles_next";
              command = [
                "(next|change) [the] subtitle [track] [on (alan|allen) tv]"
              ];
            }
            {
              trigger = "conversation";
              id = "subtitles_previous";
              command = [
                "previous subtitle [track] [on (alan|allen) tv]"
              ];
            }
          ];
          actions = [
            {
              choose = [
                {
                  conditions = [ "{{ trigger.id == 'pause' }}" ];
                  sequence = [
                    {
                      action = "media_player.media_pause";
                      target.entity_id = cfg.alanTvMediaPlayer;
                    }
                    { set_conversation_response = "Paused."; }
                  ];
                }
                {
                  conditions = [ "{{ trigger.id == 'resume' }}" ];
                  sequence = [
                    {
                      action = "media_player.media_play";
                      target.entity_id = cfg.alanTvMediaPlayer;
                    }
                    { set_conversation_response = "Playing."; }
                  ];
                }
                {
                  conditions = [ "{{ trigger.id == 'stop' }}" ];
                  sequence = [
                    {
                      action = "media_player.media_stop";
                      target.entity_id = cfg.alanTvMediaPlayer;
                    }
                    { set_conversation_response = "Stopped."; }
                  ];
                }
                {
                  conditions = [ "{{ trigger.id == 'volume_up' }}" ];
                  sequence = [
                    {
                      action = "media_player.volume_up";
                      target.entity_id = cfg.alanTvMediaPlayer;
                    }
                    { set_conversation_response = "Volume raised."; }
                  ];
                }
                {
                  conditions = [ "{{ trigger.id == 'volume_down' }}" ];
                  sequence = [
                    {
                      action = "media_player.volume_down";
                      target.entity_id = cfg.alanTvMediaPlayer;
                    }
                    { set_conversation_response = "Volume lowered."; }
                  ];
                }
                {
                  conditions = [ "{{ trigger.id == 'mute' }}" ];
                  sequence = [
                    {
                      action = "media_player.volume_mute";
                      target.entity_id = cfg.alanTvMediaPlayer;
                      data.is_volume_muted = true;
                    }
                    { set_conversation_response = "Muted."; }
                  ];
                }
                {
                  conditions = [ "{{ trigger.id == 'unmute' }}" ];
                  sequence = [
                    {
                      action = "media_player.volume_mute";
                      target.entity_id = cfg.alanTvMediaPlayer;
                      data.is_volume_muted = false;
                    }
                    { set_conversation_response = "Unmuted."; }
                  ];
                }
                {
                  conditions = [
                    "{{ trigger.id in ['subtitles_on', 'subtitles_off', 'subtitles_next', 'subtitles_previous'] }}"
                  ];
                  sequence = [
                    {
                      action = "kodi.call_method";
                      target.entity_id = cfg.alanTvMediaPlayer;
                      data = {
                        method = "Player.SetSubtitle";
                        playerid = 1;
                        subtitle = ''
                          {{ {
                            "subtitles_on": "on",
                            "subtitles_off": "off",
                            "subtitles_next": "next",
                            "subtitles_previous": "previous"
                          }[trigger.id] }}
                        '';
                      };
                    }
                    {
                      set_conversation_response = ''
                        {{ {
                          "subtitles_on": "Subtitles on.",
                          "subtitles_off": "Subtitles off.",
                          "subtitles_next": "Changed to the next subtitle track.",
                          "subtitles_previous": "Changed to the previous subtitle track."
                        }[trigger.id] }}
                      '';
                    }
                  ];
                }
              ];
            }
          ];
          mode = "restart";
        }
        {
          id = "alan_tv_local_application_launch";
          alias = "Local voice application launcher for alan-tv";
          description = ''
            Send simple application-launch requests directly to the generic
            alan-tv launcher without involving the LLM.
          '';
          triggers = [
            {
              trigger = "conversation";
              command = [
                "(open|launch|start) {application} [on (alan|allen) tv]"
              ];
            }
          ];
          actions = [
            {
              action = "script.launch_alan_tv_application";
              data.application = "{{ trigger.slots.application }}";
            }
            {
              set_conversation_response = "Opening {{ trigger.slots.application }} on alan-tv.";
            }
          ];
          mode = "single";
        }
        {
          id = "alan_tv_local_close_application";
          alias = "Local voice close command for alan-tv";
          description = "Close the focused alan-tv application without using the LLM.";
          triggers = [
            {
              trigger = "conversation";
              command = [
                "(close|quit|exit) [the] (app|application) [on (alan|allen) tv]"
                "(close|quit|exit) (kodi|cody|kody|codey) [on (alan|allen) tv]"
              ];
            }
          ];
          actions = [
            { action = "script.close_alan_tv_application"; }
            { set_conversation_response = "Closed."; }
          ];
          mode = "single";
        }
        {
          id = "alan_tv_local_type_text";
          alias = "Local voice typing for alan-tv";
          description = "Type dictated text on alan-tv without using the LLM.";
          triggers = [
            {
              trigger = "conversation";
              command = [
                "(type|enter|write) {text} on (alan|allen) tv"
              ];
            }
          ];
          actions = [
            {
              action = "script.type_on_alan_tv";
              data.text = "{{ trigger.slots.text }}";
            }
            { set_conversation_response = "Typed."; }
          ];
          mode = "single";
        }
      ];

      script = {
        get_weather_forecast = {
          alias = "Get weather forecast";
          description = ''
            Get the daily weather forecast. Use this whenever the user asks
            about future weather, including tomorrow or a named day.
          '';
          sequence = [
            {
              action = "weather.get_forecasts";
              target.entity_id = cfg.weatherEntity;
              data.type = "daily";
              response_variable = "forecast";
            }
            {
              variables.forecast_for_llm.daily_forecast_json = ''
                {%- set result = namespace(days=[]) -%}
                {%- for day in forecast["${cfg.weatherEntity}"].forecast -%}
                  {%- set local_datetime = as_local(as_datetime(day.datetime)) -%}
                  {%- set result.days = result.days + [{
                    "date": local_datetime.strftime("%Y-%m-%d"),
                    "weekday": local_datetime.strftime("%A"),
                    "condition": day.condition,
                    "temperature": day.temperature,
                    "templow": day.templow | default(none),
                    "precipitation": day.precipitation | default(none),
                    "humidity": day.humidity | default(none)
                  }] -%}
                {%- endfor -%}
                {{- result.days | to_json -}}
              '';
            }
            {
              stop = "Forecast retrieved";
              response_variable = "forecast_for_llm";
            }
          ];
        };

        launch_alan_tv_application = {
          alias = "Launch an application on alan-tv";
          description = ''
            Launch an installed application on the alan-tv media PC. Pass
            the application's canonical display name, such as Kodi,
            Dolphin, Steam, Heroic, Eden, Ryubing, or RetroArch. Correct
            obvious speech-recognition homophones; in particular, Cody,
            Kody, and Codey mean Kodi.
          '';
          fields.application = {
            name = "Application";
            description = ''
              Canonical display name of the application to launch. Use
              Kodi when speech recognition produces Cody, Kody, or Codey.
            '';
            required = true;
            selector.text = { };
          };
          sequence = [
            {
              action = "select.select_option";
              target.entity_id = cfg.alanTvApplicationSelect;
              data.option = ''
                {%- set requested = application | trim -%}
                {%- set aliases = {
                  "cody": "Kodi",
                  "codey": "Kodi",
                  "kody": "Kodi",
                  "kodi media center": "Kodi"
                } -%}
                {%- set corrected = aliases.get(requested | lower, requested) -%}
                {%- set ns = namespace(option=corrected) -%}
                {%- for option in state_attr("${cfg.alanTvApplicationSelect}", "options") or [] -%}
                  {%- if option | lower == corrected | lower -%}
                    {%- set ns.option = option -%}
                  {%- endif -%}
                {%- endfor -%}
                {{- ns.option -}}
              '';
            }
          ];
        };

        close_alan_tv_application = {
          alias = "Close the current application on alan-tv";
          description = ''
            Close the application window currently focused on the alan-tv
            media PC. Use this when asked to close, quit, or exit the current
            TV application.
          '';
          sequence = [
            {
              action = "button.press";
              target.entity_id = cfg.alanTvCloseButton;
            }
          ];
        };

        type_on_alan_tv = {
          alias = "Type text on alan-tv";
          description = ''
            Type text into the application currently focused on the alan-tv
            media PC. Use this when asked to type, enter, or write text on
            alan-tv.
          '';
          fields.text = {
            name = "Text";
            description = "The exact text to type on alan-tv.";
            required = true;
            selector.text = { };
          };
          sequence = [
            {
              action = "text.set_value";
              target.entity_id = cfg.alanTvTypeText;
              data.value = "{{ text }}";
            }
          ];
        };
      };
    };
  };
}
