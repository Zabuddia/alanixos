{ config, lib, ... }:

let
  cfg = config.alanix.home-assistant.assist.kodi;
  entityId = builtins.toJSON cfg.mediaPlayerEntityId;
  hasActiveVideoExpression = ''
    states(${entityId}) in ['playing', 'paused']
    and state_attr(${entityId}, 'media_content_type')
      in ['movie', 'tvshow', 'episode', 'video', 'channel']
  '';
  hasActiveVideo = "{{ ${hasActiveVideoExpression} }}";
in
{
  options.alanix.home-assistant.assist.kodi = {
    enable = lib.mkEnableOption "local Assist intents for Kodi";

    mediaPlayerEntityId = lib.mkOption {
      type = lib.types.strMatching "^media_player\\.[a-z0-9_]+$";
      default = "media_player.living_room_kodi";
      description = "Kodi media-player entity targeted by local Assist intents.";
    };
  };

  config = lib.mkIf cfg.enable {
    alanix.home-assistant.assist = {
      enable = true;

      customSentences.intents = {
        AlanixKodiGetNowPlaying.data = [
          {
            sentences = [
              "what is [currently] playing [on (kodi|cody)]"
              "what's [currently] playing [on (kodi|cody)]"
            ];
          }
        ];

        AlanixKodiSubtitlesOn.data = [
          {
            sentences = [
              "turn on [the] subtitles"
              "enable [the] subtitles"
            ];
          }
        ];

        AlanixKodiSubtitlesOff.data = [
          {
            sentences = [
              "turn off [the] subtitles"
              "disable [the] subtitles"
            ];
          }
        ];
      };

      intentScripts = {
        AlanixKodiGetNowPlaying.speech.text = ''
          {% set status = states(${entityId}) %}
          {% set title = state_attr(${entityId}, 'media_title') %}
          {% set artist = state_attr(${entityId}, 'media_artist') %}
          {% set series = state_attr(${entityId}, 'media_series_title') %}
          {% set season = state_attr(${entityId}, 'media_season') %}
          {% set episode = state_attr(${entityId}, 'media_episode') %}
          {% if status in ['unknown', 'unavailable'] %}
            Kodi is unavailable.
          {% elif status not in ['playing', 'paused'] %}
            Nothing is playing on Kodi.
          {% elif not title %}
            Kodi is {{ status }} media, but no title is available.
          {% elif series %}
            {% if season is not none and episode is not none %}
              {{ series }}, season {{ season }}, episode {{ episode }}, {{ title }}, is {{ status }} on Kodi.
            {% else %}
              {{ series }}, {{ title }}, is {{ status }} on Kodi.
            {% endif %}
          {% elif artist %}
            {{ title }} by {{ artist }} is {{ status }} on Kodi.
          {% else %}
            {{ title }} is {{ status }} on Kodi.
          {% endif %}
        '';

        AlanixKodiSubtitlesOn = {
          action = [
            {
              choose = [
                {
                  conditions = [
                    {
                      condition = "template";
                      value_template = hasActiveVideo;
                    }
                  ];
                  sequence = [
                    {
                      action = "kodi.call_method";
                      target.entity_id = cfg.mediaPlayerEntityId;
                      data = {
                        method = "Player.SetSubtitle";
                        playerid = 1;
                        subtitle = "on";
                      };
                    }
                  ];
                }
              ];
            }
          ];
          speech.text = ''
            {% if ${hasActiveVideoExpression} %}
              Subtitles are on.
            {% else %}
              There is no active video on Kodi.
            {% endif %}
          '';
        };

        AlanixKodiSubtitlesOff = {
          action = [
            {
              choose = [
                {
                  conditions = [
                    {
                      condition = "template";
                      value_template = hasActiveVideo;
                    }
                  ];
                  sequence = [
                    {
                      action = "kodi.call_method";
                      target.entity_id = cfg.mediaPlayerEntityId;
                      data = {
                        method = "Player.SetSubtitle";
                        playerid = 1;
                        subtitle = "off";
                      };
                    }
                  ];
                }
              ];
            }
          ];
          speech.text = ''
            {% if ${hasActiveVideoExpression} %}
              Subtitles are off.
            {% else %}
              There is no active video on Kodi.
            {% endif %}
          '';
        };
      };
    };
  };
}
