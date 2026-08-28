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

    calendarEntity = lib.mkOption {
      type = lib.types.str;
      default = "calendar.alancalendar";
      description = "Personal calendar queried and updated by Jarvis.";
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

    voiceSatellite = lib.mkOption {
      type = lib.types.str;
      default = "assist_satellite.home_assistant_voice_0a946b_assist_satellite";
      description = "Assist satellite on which alarms are announced.";
    };

    invidiousUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://invidious.fifefin.com";
      description = "Invidious instance used to find YouTube videos for Kodi.";
    };
  };

  config = lib.mkIf (config.alanix.home-assistant.enable && cfg.enable) {
    alanix.home-assistant.config = {
      input_boolean.jarvis_alarm_enabled = {
        name = "Jarvis alarm enabled";
        icon = "mdi:alarm";
      };

      input_datetime.jarvis_alarm = {
        name = "Jarvis alarm";
        has_date = true;
        has_time = true;
        icon = "mdi:alarm";
      };

      rest_command = {
        search_invidious_videos = {
          url = "${cfg.invidiousUrl}/api/v1/search?q={{ query | urlencode }}&type=video&sort_by=relevance";
          method = "get";
          timeout = 15;
        };

        search_invidious_channels = {
          url = "${cfg.invidiousUrl}/api/v1/search?q={{ channel | urlencode }}&type=channel";
          method = "get";
          timeout = 15;
        };

        get_invidious_channel_videos = {
          url = "${cfg.invidiousUrl}/api/v1/channels/{{ channel_id | urlencode }}/videos";
          method = "get";
          timeout = 15;
        };
      };

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
                "(turn|raise) [the] volume up [on] (alan|allen) tv"
                "volume up [on] (alan|allen) tv"
              ];
            }
            {
              trigger = "conversation";
              id = "volume_down";
              command = [
                "(turn|lower) [the] volume down [on] (alan|allen) tv"
                "volume down [on] (alan|allen) tv"
              ];
            }
            {
              trigger = "conversation";
              id = "volume_set";
              command = [
                "set [the] volume to {volume} [percent] on (alan|allen) tv"
                "set [the] volume [on] (alan|allen) tv to {volume} [percent]"
                "set (alan|allen) tv [volume] to {volume} [percent]"
                "turn [the] volume [on] (alan|allen) tv to {volume} [percent]"
              ];
            }
            {
              trigger = "conversation";
              id = "mute";
              command = [
                "mute [the] (movie|tv|television) [on] (alan|allen) tv"
                "mute [the] volume [on] (alan|allen) tv"
                "mute (alan|allen) tv"
              ];
            }
            {
              trigger = "conversation";
              id = "unmute";
              command = [
                "unmute [the] (movie|tv|television) [on] (alan|allen) tv"
                "unmute [the] volume [on] (alan|allen) tv"
                "unmute (alan|allen) tv"
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
            {
              trigger = "conversation";
              id = "navigate_up";
              command = [
                "(go|move|navigate) up [on (alan|allen) tv]"
                "(press|hit) [the] up [arrow|key] [on (alan|allen) tv]"
              ];
            }
            {
              trigger = "conversation";
              id = "navigate_down";
              command = [
                "(go|move|navigate) down [on (alan|allen) tv]"
                "(press|hit) [the] down [arrow|key] [on (alan|allen) tv]"
              ];
            }
            {
              trigger = "conversation";
              id = "navigate_left";
              command = [
                "(go|move|navigate) left [on (alan|allen) tv]"
                "(press|hit) [the] left [arrow|key] [on (alan|allen) tv]"
              ];
            }
            {
              trigger = "conversation";
              id = "navigate_right";
              command = [
                "(go|move|navigate) right [on (alan|allen) tv]"
                "(press|hit) [the] right [arrow|key] [on (alan|allen) tv]"
              ];
            }
            {
              trigger = "conversation";
              id = "navigate_select";
              command = [
                "(press|hit) (enter|select|okay|ok) [on (alan|allen) tv]"
                "select (this|that) [on (alan|allen) tv]"
              ];
            }
            {
              trigger = "conversation";
              id = "navigate_back";
              command = [
                "go back [on (alan|allen) tv]"
                "(press|hit) [the] back [button|key] [on (alan|allen) tv]"
              ];
            }
            {
              trigger = "conversation";
              id = "navigate_home";
              command = [
                "go [to] [the] (kodi|cody|kody|codey) home [screen] [on (alan|allen) tv]"
                "(press|hit) [the] home [button|key] [on (alan|allen) tv]"
              ];
            }
            {
              trigger = "conversation";
              id = "navigate_menu";
              command = [
                "(open|show) [the] context menu [on (alan|allen) tv]"
                "(press|hit) [the] menu [button|key] [on (alan|allen) tv]"
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
                  conditions = [ "{{ trigger.id == 'volume_set' }}" ];
                  sequence = [
                    {
                      variables.requested_volume = ''
                        {{ trigger.slots.volume | string | replace("%", "") | trim | int(-1) }}
                      '';
                    }
                    {
                      action = "script.set_kodi_volume_on_alan_tv";
                      data.volume = "{{ requested_volume }}";
                    }
                    {
                      set_conversation_response = ''
                        Volume set to {{ requested_volume }} percent.
                      '';
                    }
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
                {
                  conditions = [
                    "{{ trigger.id in ['navigate_up', 'navigate_down', 'navigate_left', 'navigate_right', 'navigate_select', 'navigate_back', 'navigate_home', 'navigate_menu'] }}"
                  ];
                  sequence = [
                    {
                      action = "script.control_kodi_ui_on_alan_tv";
                      data.command = "{{ trigger.id | replace('navigate_', '') }}";
                    }
                    {
                      set_conversation_response = ''
                        {{ {
                          "navigate_up": "Up.",
                          "navigate_down": "Down.",
                          "navigate_left": "Left.",
                          "navigate_right": "Right.",
                          "navigate_select": "Selected.",
                          "navigate_back": "Back.",
                          "navigate_home": "Home.",
                          "navigate_menu": "Menu."
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
          id = "local_basic_voice_queries";
          alias = "Local voice answers for basic information";
          description = ''
            Answer common time, date, and now-playing questions locally so
            they remain fast and reliable without the LLM.
          '';
          triggers = [
            {
              trigger = "conversation";
              id = "time";
              command = [
                "what time is it"
                "what is [the] time"
                "tell me [the] time"
              ];
            }
            {
              trigger = "conversation";
              id = "date";
              command = [
                "what day is it"
                "what is [the] date [today]"
                "what is todays date"
                "tell me [the] date"
              ];
            }
            {
              trigger = "conversation";
              id = "now_playing";
              command = [
                "what is playing [on (alan|allen) tv]"
                "what am i watching [on (alan|allen) tv]"
                "what is [the] title [of [the] (movie|video|show)]"
                "what title is it"
              ];
            }
          ];
          actions = [
            {
              choose = [
                {
                  conditions = [ "{{ trigger.id == 'time' }}" ];
                  sequence = [
                    {
                      set_conversation_response = ''
                        It is {{ now().strftime("%-I:%M %p") }}.
                      '';
                    }
                  ];
                }
                {
                  conditions = [ "{{ trigger.id == 'date' }}" ];
                  sequence = [
                    {
                      set_conversation_response = ''
                        Today is {{ now().strftime("%A, %B %-d") }}.
                      '';
                    }
                  ];
                }
                {
                  conditions = [ "{{ trigger.id == 'now_playing' }}" ];
                  sequence = [
                    {
                      set_conversation_response = ''
                        {%- set title = state_attr("${cfg.alanTvMediaPlayer}", "media_title") -%}
                        {%- if title -%}
                          You are watching {{ title }}.
                        {%- else -%}
                          Nothing is currently playing on alan-tv.
                        {%- endif -%}
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
          id = "jarvis_local_calendar_queries";
          alias = "Local voice queries for AlanCalendar";
          description = ''
            Read common calendar ranges directly with Home Assistant's native
            calendar action instead of asking the LLM to infer calendar state.
          '';
          triggers = [
            {
              trigger = "conversation";
              id = "today";
              command = [
                "what is on [my] calendar today"
                "what do i have on [my] calendar today"
                "what [calendar] events do i have today"
                "tell me [my] calendar [events] for today"
              ];
            }
            {
              trigger = "conversation";
              id = "tomorrow";
              command = [
                "what is on [my] calendar tomorrow"
                "what do i have on [my] calendar tomorrow"
                "what [calendar] events do i have tomorrow"
                "tell me [my] calendar [events] for tomorrow"
              ];
            }
            {
              trigger = "conversation";
              id = "week";
              command = [
                "what is on [my] calendar this week"
                "what do i have on [my] calendar this week"
                "what [calendar] events do i have this week"
                "tell me [my] calendar [events] for this week"
              ];
            }
          ];
          actions = [
            {
              variables = {
                calendar_start = ''
                  {% if trigger.id == "tomorrow" %}
                    {{ today_at() + timedelta(days=1) }}
                  {% else %}
                    {{ now() }}
                  {% endif %}
                '';
                calendar_end = ''
                  {% if trigger.id == "today" %}
                    {{ today_at() + timedelta(days=1) }}
                  {% elif trigger.id == "tomorrow" %}
                    {{ today_at() + timedelta(days=2) }}
                  {% else %}
                    {{ today_at() + timedelta(days=7) }}
                  {% endif %}
                '';
              };
            }
            {
              action = "calendar.get_events";
              target.entity_id = cfg.calendarEntity;
              data = {
                start_date_time = "{{ calendar_start }}";
                end_date_time = "{{ calendar_end }}";
              };
              response_variable = "calendar_agenda";
            }
            {
              set_conversation_response = ''
                {%- set events = calendar_agenda["${cfg.calendarEntity}"]["events"] -%}
                {%- if events | count == 0 -%}
                  You have nothing on your calendar {{ {"today": "today", "tomorrow": "tomorrow", "week": "this week"}[trigger.id] }}.
                {%- else -%}
                  {%- set answer = namespace(parts=[]) -%}
                  {%- for event in events -%}
                    {%- if "T" in event.start -%}
                      {%- set start = event.start | as_datetime | as_local -%}
                      {%- set when = start.strftime("%A at %-I:%M %p") -%}
                    {%- else -%}
                      {%- set start = strptime(event.start, "%Y-%m-%d") -%}
                      {%- set when = start.strftime("all day on %A") -%}
                    {%- endif -%}
                    {%- set answer.parts = answer.parts + [event.summary ~ " " ~ when] -%}
                  {%- endfor -%}
                  You have {{ answer.parts | join(", and ") }}.
                {%- endif -%}
              '';
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
        {
          id = "alan_tv_local_invidious_controls";
          alias = "Local voice controls for Invidious on alan-tv";
          description = ''
            Open Invidious pages and play requested YouTube videos without
            sending predictable commands through the LLM.
          '';
          triggers = [
            {
              trigger = "conversation";
              id = "play_video";
              command = [
                "(play|watch) {youtube_query} (on|from) (youtube|invidious) [on (alan|allen) tv]"
                "(play|watch) [(a|the)] (youtube|invidious) video {youtube_query} [on (alan|allen) tv]"
              ];
            }
            {
              trigger = "conversation";
              id = "latest_channel_video";
              command = [
                "(play|watch) [the] latest [youtube] video (from|by) {channel} [on (alan|allen) tv]"
              ];
            }
            {
              trigger = "conversation";
              id = "feed";
              command = [
                "(open|show|go to) [(my|the)] (youtube|invidious) (feed|subscriptions) [page] [on (alan|allen) tv]"
                "(open|show) [my] latest (youtube|invidious) videos [on (alan|allen) tv]"
              ];
            }
            {
              trigger = "conversation";
              id = "popular";
              command = [
                "(open|show|go to) [the] (youtube|invidious) popular [page] [on (alan|allen) tv]"
              ];
            }
            {
              trigger = "conversation";
              id = "home";
              command = [
                "(open|show|go to) (youtube|invidious) [on (alan|allen) tv]"
              ];
            }
          ];
          actions = [
            {
              choose = [
                {
                  conditions = [ "{{ trigger.id == 'play_video' }}" ];
                  sequence = [
                    {
                      action = "script.play_youtube_video_on_alan_tv";
                      data.query = "{{ trigger.slots.youtube_query }}";
                    }
                    { set_conversation_response = "Playing {{ trigger.slots.youtube_query }}."; }
                  ];
                }
                {
                  conditions = [ "{{ trigger.id == 'latest_channel_video' }}" ];
                  sequence = [
                    {
                      action = "script.play_latest_youtube_video_from_channel";
                      data.channel = "{{ trigger.slots.channel }}";
                    }
                    { set_conversation_response = "Playing the latest video from {{ trigger.slots.channel }}."; }
                  ];
                }
                {
                  conditions = [ "{{ trigger.id in ['feed', 'popular', 'home'] }}" ];
                  sequence = [
                    {
                      action = "script.open_invidious_on_alan_tv";
                      data.page = "{{ trigger.id }}";
                    }
                    {
                      set_conversation_response = ''
                        {{ {"feed": "Opening your YouTube feed.", "popular": "Opening YouTube Popular.", "home": "Opening Invidious."}[trigger.id] }}
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
          id = "jarvis_alarm_ringing";
          alias = "Ring the Jarvis alarm";
          description = "Announce the configured clock-time alarm on the Voice PE.";
          triggers = [
            {
              trigger = "time";
              at = "input_datetime.jarvis_alarm";
            }
          ];
          conditions = [
            {
              condition = "state";
              entity_id = "input_boolean.jarvis_alarm_enabled";
              state = "on";
            }
          ];
          actions = [
            {
              action = "input_boolean.turn_off";
              target.entity_id = "input_boolean.jarvis_alarm_enabled";
            }
            {
              action = "assist_satellite.announce";
              target.entity_id = cfg.voiceSatellite;
              data = {
                message = "Your alarm is going off.";
                preannounce = true;
              };
            }
          ];
          mode = "single";
        }
        {
          id = "jarvis_local_alarm_controls";
          alias = "Local voice controls for the Jarvis alarm";
          description = "Cancel or inspect the clock-time alarm without using the LLM.";
          triggers = [
            {
              trigger = "conversation";
              id = "cancel";
              command = [
                "(cancel|disable|turn off) [(my|the)] alarm"
                "delete [(my|the)] alarm"
              ];
            }
            {
              trigger = "conversation";
              id = "status";
              command = [
                "when is [(my|the)] alarm"
                "what time is [(my|the)] alarm [set for]"
                "do i have an alarm [set]"
              ];
            }
          ];
          actions = [
            {
              choose = [
                {
                  conditions = [ "{{ trigger.id == 'cancel' }}" ];
                  sequence = [
                    { action = "script.cancel_jarvis_alarm"; }
                    { set_conversation_response = "Alarm canceled."; }
                  ];
                }
                {
                  conditions = [ "{{ trigger.id == 'status' }}" ];
                  sequence = [
                    {
                      set_conversation_response = ''
                        {%- if is_state("input_boolean.jarvis_alarm_enabled", "on") -%}
                          Your alarm is set for {{ as_datetime(states("input_datetime.jarvis_alarm")).strftime("%-I:%M %p on %A, %B %-d") }}.
                        {%- else -%}
                          You do not have an alarm set.
                        {%- endif -%}
                      '';
                    }
                  ];
                }
              ];
            }
          ];
          mode = "restart";
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
            media PC. Use this only for literal text entry. Never use it for
            arrow keys, Enter, Back, navigation, or other control keys.
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

        control_kodi_ui_on_alan_tv = {
          alias = "Control the Kodi interface on alan-tv";
          description = ''
            Navigate Kodi on alan-tv. Use this for arrow directions, selecting
            an item, going back or home, and opening the context menu. Do not
            use the text-entry tool for these controls.
          '';
          fields.command = {
            name = "Navigation command";
            description = "The Kodi interface command to perform.";
            required = true;
            selector.select.options = [
              "up"
              "down"
              "left"
              "right"
              "select"
              "back"
              "home"
              "menu"
            ];
          };
          sequence = [
            {
              action = "kodi.call_method";
              target.entity_id = cfg.alanTvMediaPlayer;
              data.method = ''
                {{ {
                  "up": "Input.Up",
                  "down": "Input.Down",
                  "left": "Input.Left",
                  "right": "Input.Right",
                  "select": "Input.Select",
                  "back": "Input.Back",
                  "home": "Input.Home",
                  "menu": "Input.ContextMenu"
                }[command | lower] }}
              '';
            }
          ];
        };

        set_kodi_volume_on_alan_tv = {
          alias = "Set Kodi volume on alan-tv";
          description = ''
            Set Kodi's volume on alan-tv to an exact percentage from 0 through
            100. Use this when the user requests a specific volume level.
          '';
          fields.volume = {
            name = "Volume";
            description = "The requested volume percentage from 0 through 100.";
            required = true;
            selector.number = {
              min = 0;
              max = 100;
              step = 1;
              mode = "box";
              unit_of_measurement = "%";
            };
          };
          sequence = [
            {
              variables.requested_volume = ''
                {{ volume | string | replace("%", "") | trim | float(-1) }}
              '';
            }
            {
              "if" = [ "{{ requested_volume < 0 or requested_volume > 100 }}" ];
              "then" = [
                {
                  stop = "Volume must be between 0 and 100 percent";
                  error = true;
                }
              ];
            }
            {
              action = "media_player.volume_set";
              target.entity_id = cfg.alanTvMediaPlayer;
              data.volume_level = "{{ requested_volume / 100 }}";
            }
          ];
        };

        ensure_kodi_on_alan_tv = {
          alias = "Ensure Kodi is running on alan-tv";
          description = "Start Kodi when necessary and wait for its Home Assistant media player.";
          sequence = [
            {
              "if" = [
                {
                  condition = "template";
                  value_template = ''
                    {{ states("${cfg.alanTvMediaPlayer}") in ["off", "unknown", "unavailable"] }}
                  '';
                }
              ];
              "then" = [
                {
                  action = "script.launch_alan_tv_application";
                  data.application = "Kodi";
                }
                {
                  wait_template = ''
                    {{ states("${cfg.alanTvMediaPlayer}") not in ["off", "unknown", "unavailable"] }}
                  '';
                  timeout = "00:00:30";
                  continue_on_timeout = false;
                }
              ];
            }
          ];
        };

        open_invidious_on_alan_tv = {
          alias = "Open Invidious on alan-tv";
          description = ''
            Open the Invidious Kodi add-on. The feed page contains the newest
            videos from subscribed channels; popular is the instance-wide
            popular page; subscriptions lists subscribed channels.
          '';
          fields.page = {
            name = "Page";
            description = "The Invidious page to open.";
            required = true;
            selector.select.options = [ "home" "feed" "popular" "subscriptions" ];
          };
          sequence = [
            { action = "script.ensure_kodi_on_alan_tv"; }
            {
              action = "kodi.call_method";
              target.entity_id = cfg.alanTvMediaPlayer;
              data = {
                method = "GUI.ActivateWindow";
                window = "videos";
                parameters = [
                  ''
                    {{ {
                      "home": "plugin://plugin.video.invidious/",
                      "feed": "plugin://plugin.video.invidious/?action=user_feed",
                      "popular": "plugin://plugin.video.invidious/?action=popular",
                      "subscriptions": "plugin://plugin.video.invidious/?action=user_subscriptions"
                    }[page | lower] }}
                  ''
                  "return"
                ];
              };
            }
          ];
        };

        play_youtube_video_on_alan_tv = {
          alias = "Play a YouTube video on alan-tv";
          description = ''
            Search YouTube through Invidious and play the best matching video
            in Kodi on alan-tv. The query may be a title, description, or a
            YouTube URL.
          '';
          fields.query = {
            name = "Video search";
            description = ''
              Required and never blank. Pass the requested YouTube video title,
              search terms, or URL without phrases such as "play a YouTube video".
            '';
            required = true;
            selector.text = { };
          };
          sequence = [
            { action = "script.ensure_kodi_on_alan_tv"; }
            {
              action = "rest_command.search_invidious_videos";
              data.query = "{{ query }}";
              response_variable = "invidious_search";
            }
            {
              variables.youtube_videos = ''
                {{ invidious_search.content | selectattr("type", "equalto", "video") | list }}
              '';
            }
            {
              "if" = [ "{{ youtube_videos | count == 0 }}" ];
              "then" = [
                {
                  stop = "No matching YouTube video was found";
                  error = true;
                }
              ];
            }
            {
              variables.youtube_video = "{{ youtube_videos | first }}";
            }
            {
              action = "kodi.call_method";
              target.entity_id = cfg.alanTvMediaPlayer;
              data = {
                method = "Player.Open";
                item.file = ''
                  plugin://plugin.video.invidious/?action=play_video&video_id={{ youtube_video.videoId }}
                '';
              };
            }
            {
              variables.youtube_result = {
                title = "{{ youtube_video.title }}";
                channel = "{{ youtube_video.author }}";
              };
            }
            {
              stop = "YouTube video started";
              response_variable = "youtube_result";
            }
          ];
        };

        play_latest_youtube_video_from_channel = {
          alias = "Play the latest YouTube video from a channel";
          description = ''
            Find a YouTube channel through Invidious and play its newest video
            in Kodi on alan-tv.
          '';
          fields.channel = {
            name = "Channel";
            description = "The YouTube channel name.";
            required = true;
            selector.text = { };
          };
          sequence = [
            { action = "script.ensure_kodi_on_alan_tv"; }
            {
              action = "rest_command.search_invidious_channels";
              data.channel = "{{ channel }}";
              response_variable = "invidious_channel_search";
            }
            {
              variables.youtube_channels = ''
                {{ invidious_channel_search.content | selectattr("type", "equalto", "channel") | list }}
              '';
            }
            {
              "if" = [ "{{ youtube_channels | count == 0 }}" ];
              "then" = [
                {
                  stop = "No matching YouTube channel was found";
                  error = true;
                }
              ];
            }
            {
              variables.youtube_channel = "{{ youtube_channels | first }}";
            }
            {
              action = "rest_command.get_invidious_channel_videos";
              data.channel_id = "{{ youtube_channel.authorId }}";
              response_variable = "invidious_channel_videos";
            }
            {
              variables.youtube_videos = "{{ invidious_channel_videos.content.videos }}";
            }
            {
              "if" = [ "{{ youtube_videos | count == 0 }}" ];
              "then" = [
                {
                  stop = "The YouTube channel has no playable videos";
                  error = true;
                }
              ];
            }
            {
              variables.youtube_video = "{{ youtube_videos | first }}";
            }
            {
              action = "kodi.call_method";
              target.entity_id = cfg.alanTvMediaPlayer;
              data = {
                method = "Player.Open";
                item.file = ''
                  plugin://plugin.video.invidious/?action=play_video&video_id={{ youtube_video.videoId }}
                '';
              };
            }
            {
              variables.youtube_result = {
                title = "{{ youtube_video.title }}";
                channel = "{{ youtube_video.author }}";
              };
            }
            {
              stop = "Latest YouTube video started";
              response_variable = "youtube_result";
            }
          ];
        };

        add_timed_event_to_alan_calendar = {
          alias = "Add an event today or tomorrow to AlanCalendar";
          description = ''
            Add a timed event today or tomorrow. Prefer this tool whenever the
            user says today or tomorrow because Home Assistant computes the
            date without asking the LLM to calculate a calendar date.
          '';
          fields = {
            summary = {
              name = "Event title";
              description = "A short title for the calendar event.";
              required = true;
              selector.text = { };
            };
            day = {
              name = "Day";
              description = "Whether the event is today or tomorrow.";
              required = true;
              selector.select.options = [ "today" "tomorrow" ];
            };
            start_time = {
              name = "Start time";
              description = "The local clock time at which the event starts.";
              required = true;
              selector.time = { };
            };
            duration_minutes = {
              name = "Duration";
              description = "Event length in minutes. Use 60 when the user does not specify a duration.";
              default = 60;
              selector.number = {
                min = 1;
                max = 1440;
                step = 1;
                mode = "box";
                unit_of_measurement = "minutes";
              };
            };
            description = {
              name = "Description";
              description = "Optional details about the event.";
              selector.text = { };
            };
            location = {
              name = "Location";
              description = "Optional event location.";
              selector.text = { };
            };
          };
          sequence = [
            {
              variables = {
                event_start = ''
                  {{ today_at(start_time) + timedelta(days=1 if day == "tomorrow" else 0) }}
                '';
                event_end = ''
                  {{ today_at(start_time) + timedelta(days=1 if day == "tomorrow" else 0, minutes=duration_minutes | int(60)) }}
                '';
              };
            }
            {
              "if" = [ "{{ event_start | as_datetime <= now() }}" ];
              "then" = [
                {
                  stop = "The requested event time has already passed";
                  error = true;
                }
              ];
            }
            {
              action = "calendar.create_event";
              target.entity_id = cfg.calendarEntity;
              data = {
                summary = "{{ summary }}";
                start_date_time = "{{ event_start }}";
                end_date_time = "{{ event_end }}";
                description = "{{ description | default('', true) }}";
                location = "{{ location | default('', true) }}";
              };
            }
          ];
        };

        add_dated_timed_event_to_alan_calendar = {
          alias = "Add a dated timed event to AlanCalendar";
          description = ''
            Add a timed event on an explicit calendar date other than today
            or tomorrow. Use local Home Assistant time.
          '';
          fields = {
            summary = {
              name = "Event title";
              description = "A short title for the calendar event.";
              required = true;
              selector.text = { };
            };
            start_time = {
              name = "Start";
              description = "The local date and time at which the event starts.";
              required = true;
              selector.datetime = { };
            };
            end_time = {
              name = "End";
              description = "The local date and time at which the event ends.";
              required = true;
              selector.datetime = { };
            };
            description = {
              name = "Description";
              description = "Optional details about the event.";
              selector.text = { };
            };
            location = {
              name = "Location";
              description = "Optional event location.";
              selector.text = { };
            };
          };
          sequence = [
            {
              "if" = [
                "{{ start_time | as_timestamp(0) <= now() | as_timestamp }}"
                "{{ end_time | as_timestamp(0) <= start_time | as_timestamp(0) }}"
              ];
              "then" = [
                {
                  stop = "The event must start in the future and end after it starts";
                  error = true;
                }
              ];
            }
            {
              action = "calendar.create_event";
              target.entity_id = cfg.calendarEntity;
              data = {
                summary = "{{ summary }}";
                start_date_time = "{{ start_time }}";
                end_date_time = "{{ end_time }}";
                description = "{{ description | default('', true) }}";
                location = "{{ location | default('', true) }}";
              };
            }
          ];
        };

        add_all_day_event_to_alan_calendar = {
          alias = "Add an all-day event to AlanCalendar";
          description = ''
            Add a single-day all-day event to the user's personal
            AlanCalendar calendar.
          '';
          fields = {
            summary = {
              name = "Event title";
              description = "A short title for the calendar event.";
              required = true;
              selector.text = { };
            };
            event_date = {
              name = "Date";
              description = "The local date of the all-day event.";
              required = true;
              selector.date = { };
            };
            description = {
              name = "Description";
              description = "Optional details about the event.";
              selector.text = { };
            };
            location = {
              name = "Location";
              description = "Optional event location.";
              selector.text = { };
            };
          };
          sequence = [
            {
              action = "calendar.create_event";
              target.entity_id = cfg.calendarEntity;
              data = {
                summary = "{{ summary }}";
                start_date = "{{ event_date }}";
                end_date = "{{ (event_date | as_datetime + timedelta(days=1)).date() }}";
                description = "{{ description | default('', true) }}";
                location = "{{ location | default('', true) }}";
              };
            }
          ];
        };

        set_jarvis_alarm = {
          alias = "Set the Jarvis alarm";
          description = ''
            Set a clock-time alarm on the Home Assistant Voice PE. Use this
            for requests such as "set an alarm for 7 AM". Supply alarm_time
            as a local time. If that time has passed today, the alarm is set
            for tomorrow.
          '';
          fields.alarm_time = {
            name = "Alarm time";
            description = "The requested local clock time, such as 07:00:00 or 19:30:00.";
            required = true;
            selector.time = { };
          };
          sequence = [
            {
              action = "input_datetime.set_datetime";
              target.entity_id = "input_datetime.jarvis_alarm";
              data.datetime = ''
                {%- set requested = today_at(alarm_time) -%}
                {%- if requested <= now() -%}
                  {%- set requested = requested + timedelta(days=1) -%}
                {%- endif -%}
                {{- requested.strftime("%Y-%m-%d %H:%M:%S") -}}
              '';
            }
            {
              action = "input_boolean.turn_on";
              target.entity_id = "input_boolean.jarvis_alarm_enabled";
            }
          ];
        };

        cancel_jarvis_alarm = {
          alias = "Cancel the Jarvis alarm";
          description = "Cancel the currently configured clock-time alarm.";
          sequence = [
            {
              action = "input_boolean.turn_off";
              target.entity_id = "input_boolean.jarvis_alarm_enabled";
            }
          ];
        };
      };
    };
  };
}
