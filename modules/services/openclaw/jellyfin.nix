{ config, lib, pkgs, ... }:

let
  cfg = config.alanix.openclaw.jellyfin;
  passwordPath = if cfg.passwordFile != null then cfg.passwordFile else "";

  jellyfinControl = pkgs.writeShellApplication {
    name = "jellyfin-control";
    runtimeInputs = [ pkgs.coreutils pkgs.curl pkgs.jq ];
    text = ''
      umask 0077
      url=${lib.escapeShellArg (lib.removeSuffix "/" cfg.url)}
      username=${lib.escapeShellArg cfg.username}
      password_file=${lib.escapeShellArg passwordPath}

      usage() {
        cat >&2 <<'EOF'
Usage: jellyfin-control ACTION [ARGUMENTS]

Actions:
  search-movies QUERY
  search-series QUERY
  episodes SERIES_ID SEASON
  item ITEM_ID
  activity
  play ITEM_ID
EOF
      }

      [ -r "$password_file" ] || { echo "Jellyfin password file is missing or unreadable" >&2; exit 78; }
      password="$(tr -d '\r\n' < "$password_file")"
      auth_body="$(jq -cn --arg Username "$username" --arg Pw "$password" '{Username: $Username, Pw: $Pw}')"
      auth="$(printf '%s' "$auth_body" | curl -fsS \
        --header 'Content-Type: application/json' \
        --header 'X-Emby-Authorization: MediaBrowser Client="alanix-openclaw", Device="alan-framework", DeviceId="alanix-openclaw", Version="1"' \
        --data-binary @- "$url/Users/AuthenticateByName")"
      unset password
      token="$(jq -er '.AccessToken' <<<"$auth")"
      user_id="$(jq -er '.User.Id' <<<"$auth")"

      get() {
        curl -fsS --header "X-Emby-Token: $token" --header 'Accept: application/json' "$url$1"
      }

      valid_id() {
        [[ "$1" =~ ^[A-Za-z0-9-]+$ ]] || { echo "Invalid Jellyfin item ID" >&2; exit 64; }
      }

      search() {
        query="$(jq -rn --arg value "$1" '$value|@uri')"
        get "/Users/$user_id/Items?Recursive=true&Limit=50&Fields=Overview&SearchTerm=$query&IncludeItemTypes=$2" |
          jq '{items: [.Items[] | {id: .Id, title: .Name, type: .Type, year: .ProductionYear, series: .SeriesName, season: .ParentIndexNumber, episode: .IndexNumber, overview: .Overview}], total: .TotalRecordCount}'
      }

      action="''${1:-}"
      if [ "$#" -gt 0 ]; then shift; fi
      case "$action" in
        search-movies)
          [ "$#" -eq 1 ] || { usage; exit 2; }
          search "$1" Movie
          ;;
        search-series)
          [ "$#" -eq 1 ] || { usage; exit 2; }
          search "$1" Series
          ;;
        episodes)
          [ "$#" -eq 2 ] || { usage; exit 2; }
          valid_id "$1"
          [[ "$2" =~ ^[0-9]+$ ]] || { echo "Season must be a non-negative integer" >&2; exit 64; }
          get "/Shows/$1/Episodes?UserId=$user_id&Season=$2&Fields=Overview" |
            jq '{items: [.Items[] | {id: .Id, title: .Name, series: .SeriesName, season: .ParentIndexNumber, episode: .IndexNumber, overview: .Overview}], total: .TotalRecordCount}'
          ;;
        item)
          [ "$#" -eq 1 ] || { usage; exit 2; }
          valid_id "$1"
          get "/Users/$user_id/Items/$1" |
            jq '{id: .Id, title: .Name, type: .Type, year: .ProductionYear, series: .SeriesName, season: .ParentIndexNumber, episode: .IndexNumber, overview: .Overview}'
          ;;
        activity)
          [ "$#" -eq 0 ] || { usage; exit 2; }
          get "/Sessions" |
            jq '{active: [.[] | select(.NowPlayingItem != null) | {user: .UserName, client: .Client, device: .DeviceName, title: .NowPlayingItem.Name, type: .NowPlayingItem.Type, series: .NowPlayingItem.SeriesName, season: .NowPlayingItem.ParentIndexNumber, episode: .NowPlayingItem.IndexNumber, paused: .PlayState.IsPaused}], count: ([.[] | select(.NowPlayingItem != null)] | length)}'
          ;;
        play)
          [ "$#" -eq 1 ] || { usage; exit 2; }
          valid_id "$1"
          item="$(get "/Users/$user_id/Items/$1")"
          item_type="$(jq -r '.Type' <<<"$item")"
          title="$(jq -er '.Name' <<<"$item")"
          case "$item_type" in
            Movie)
              year="$(jq -er '.ProductionYear' <<<"$item")"
              playback="$(kodi-control play-jellyfin-movie "$title" "$year")"
              ;;
            Episode)
              series="$(jq -er '.SeriesName' <<<"$item")"
              season="$(jq -er '.ParentIndexNumber' <<<"$item")"
              episode="$(jq -er '.IndexNumber' <<<"$item")"
              playback="$(kodi-control play-jellyfin-episode "$series" "$season" "$episode")"
              ;;
            *)
              echo "Jellyfin playback supports movies and episodes; received $item_type" >&2
              exit 64
              ;;
          esac
          jq -cn --arg id "$1" --arg title "$title" --arg type "$item_type" --argjson playback "$playback" \
            '{item: {id: $id, title: $title, type: $type}, playback: $playback}'
          ;;
        *) usage; exit 2 ;;
      esac
    '';
  };
in
{
  options.alanix.openclaw.jellyfin = {
    enable = lib.mkEnableOption "focused Jellyfin access for OpenClaw";
    url = lib.mkOption {
      type = lib.types.str;
      default = "https://jellyfin.fifefin.com";
      description = "Stable Jellyfin base URL.";
    };
    username = lib.mkOption {
      type = lib.types.str;
      default = "buddia";
      description = "Jellyfin account used by OpenClaw.";
    };
    passwordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Runtime-only file containing the Jellyfin password.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.alanix.openclaw.gateway.enable;
        message = "Jellyfin access requires alanix.openclaw.gateway.enable.";
      }
      {
        assertion = config.alanix.openclaw.kodi.enable;
        message = "Jellyfin playback requires alanix.openclaw.kodi.enable.";
      }
      {
        assertion = cfg.passwordFile != null;
        message = "alanix.openclaw.jellyfin.passwordFile must be set.";
      }
    ];
    alanix.openclaw.packages = [ jellyfinControl ];
  };
}
