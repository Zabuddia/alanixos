{ config, lib, pkgs, ... }:

let
  cfg = config.alanix.openclaw.media;
  passwordPath = value: if value != null then value else "";

  jellyfinControl = pkgs.writeShellApplication {
    name = "jellyfin-control";
    runtimeInputs = [ pkgs.coreutils pkgs.curl pkgs.jq ];
    text = ''
      umask 0077
      url=${lib.escapeShellArg (lib.removeSuffix "/" cfg.jellyfin.url)}
      username=${lib.escapeShellArg cfg.jellyfin.username}
      password_file=${lib.escapeShellArg (passwordPath cfg.jellyfin.passwordFile)}
      default_target=${lib.escapeShellArg cfg.defaultTarget}

      usage() {
        cat >&2 <<'EOF'
Usage: jellyfin-control ACTION [ARGUMENTS]

Actions:
  libraries
  search QUERY [ITEM_TYPES]
  item ITEM_ID
  sessions
  play SESSION_ID ITEM_ID
  play-default ITEM_ID [TARGET]
  pause|resume|stop|next|previous SESSION_ID
  api METHOD /API/PATH [JSON]
EOF
      }

      [ -r "$password_file" ] || { echo "Jellyfin password file is missing or unreadable" >&2; exit 78; }
      password="$(tr -d '\r\n' < "$password_file")"
      auth_body="$(jq -cn --arg Username "$username" --arg Pw "$password" '{Username: $Username, Pw: $Pw}')"
      auth="$(printf '%s' "$auth_body" | curl -fsS \
        --header 'Content-Type: application/json' \
        --header 'X-Emby-Authorization: MediaBrowser Client="alanix-openclaw", Device="alan-framework", DeviceId="alanix-openclaw", Version="1"' \
        --data-binary @- "$url/Users/AuthenticateByName")"
      token="$(jq -er '.AccessToken' <<<"$auth")"
      user_id="$(jq -er '.User.Id' <<<"$auth")"

      request() {
        local method="$1" path="$2" body="''${3:-}"
        local arguments=(-fsS --request "$method" --header "X-Emby-Token: $token" --header 'Accept: application/json')
        case "$path" in /*) ;; *) echo "Jellyfin API path must begin with /" >&2; exit 64 ;; esac
        if [ -n "$body" ]; then
          arguments+=(--header 'Content-Type: application/json' --data-binary @-)
          printf '%s' "$body" | curl "''${arguments[@]}" "$url$path" | jq .
        else
          curl "''${arguments[@]}" "$url$path" | jq .
        fi
      }

      action="''${1:-}"; if [ "$#" -gt 0 ]; then shift; fi
      case "$action" in
        libraries)
          [ "$#" -eq 0 ] || { usage; exit 2; }
          request GET /Library/VirtualFolders
          ;;
        search)
          [ "$#" -ge 1 ] && [ "$#" -le 2 ] || { usage; exit 2; }
          query="$(jq -rn --arg v "$1" '$v|@uri')"
          path="/Users/$user_id/Items?Recursive=true&Limit=50&Fields=Path,MediaSources,Overview&SearchTerm=$query"
          if [ "$#" -eq 2 ]; then
            types="$(jq -rn --arg v "$2" '$v|@uri')"
            path="$path&IncludeItemTypes=$types"
          fi
          request GET "$path"
          ;;
        item)
          [ "$#" -eq 1 ] || { usage; exit 2; }
          [[ "$1" =~ ^[A-Za-z0-9-]+$ ]] || { echo "Invalid Jellyfin item ID" >&2; exit 64; }
          request GET "/Users/$user_id/Items/$1"
          ;;
        sessions)
          [ "$#" -eq 0 ] || { usage; exit 2; }
          request GET "/Sessions?ControllableByUserId=$user_id"
          ;;
        play)
          [ "$#" -eq 2 ] || { usage; exit 2; }
          request POST "/Sessions/$1/Playing?ItemIds=$2&PlayCommand=PlayNow" '{}'
          ;;
        play-default)
          [ "$#" -ge 1 ] && [ "$#" -le 2 ] || { usage; exit 2; }
          target="''${2:-$default_target}"
          case "$target" in
            alan-tv-kodi)
              item="$(request GET "/Users/$user_id/Items/$1")"
              item_type="$(jq -r '.Type' <<<"$item")"
              [ "$item_type" = Movie ] || {
                echo "Jellyfin default playback currently supports Movie items; received $item_type" >&2
                exit 64
              }
              title="$(jq -er '.Name' <<<"$item")"
              playback="$(kodi-control play-movie "$title")"
              jq -cn --argjson item "$item" --argjson playback "$playback" --arg target "$target" \
                '{source: "jellyfin", target: $target, item: {id: $item.Id, title: $item.Name, type: $item.Type}, playback: $playback}'
              ;;
            *) echo "Unsupported media target: $target" >&2; exit 64 ;;
          esac
          ;;
        pause|resume|stop|next|previous)
          [ "$#" -eq 1 ] || { usage; exit 2; }
          case "$action" in
            pause) command=Pause ;; resume) command=Unpause ;; stop) command=Stop ;;
            next) command=NextTrack ;; previous) command=PreviousTrack ;;
          esac
          request POST "/Sessions/$1/Playing/$command" '{}'
          ;;
        api)
          [ "$#" -ge 2 ] && [ "$#" -le 3 ] || { usage; exit 2; }
          method="''${1^^}"
          case "$method" in GET|POST|PATCH|PUT|DELETE) ;; *) echo "Unsupported HTTP method: $method" >&2; exit 64 ;; esac
          request "$method" "$2" "''${3:-}"
          ;;
        *) usage; exit 2 ;;
      esac
    '';
  };

  navidromeControl = pkgs.writeShellApplication {
    name = "navidrome-control";
    runtimeInputs = [ pkgs.coreutils pkgs.curl pkgs.jq pkgs.openssl ];
    text = ''
      umask 0077
      url=${lib.escapeShellArg (lib.removeSuffix "/" cfg.navidrome.url)}
      username=${lib.escapeShellArg cfg.navidrome.username}
      password_file=${lib.escapeShellArg (passwordPath cfg.navidrome.passwordFile)}
      default_target=${lib.escapeShellArg cfg.defaultTarget}

      usage() {
        cat >&2 <<'EOF'
Usage: navidrome-control ACTION [ARGUMENTS]

Actions:
  ping
  search QUERY
  albums [TYPE]
  album ID
  song ID
  artists
  artist ID
  playlists
  playlist ID
  now-playing
  starred
  star ID
  unstar ID
  play ID [TARGET]
  call ENDPOINT [KEY=VALUE ...]
EOF
      }

      [ -r "$password_file" ] || { echo "Navidrome password file is missing or unreadable" >&2; exit 78; }
      password="$(tr -d '\r\n' < "$password_file")"
      salt="$(openssl rand -hex 12)"
      token="$(printf '%s' "$password$salt" | md5sum | cut -d' ' -f1)"
      unset password

      subsonic() {
        local endpoint="$1"; shift
        [[ "$endpoint" =~ ^[A-Za-z0-9]+$ ]] || { echo "Invalid Subsonic endpoint: $endpoint" >&2; exit 64; }
        response="$(curl -fsS --get "$url/rest/$endpoint.view" \
          --data-urlencode "u=$username" --data-urlencode "t=$token" \
          --data-urlencode "s=$salt" --data-urlencode 'v=1.16.1' \
          --data-urlencode 'c=alanix-openclaw' --data-urlencode 'f=json' "$@")"
        if [ "$(jq -r '.["subsonic-response"].status' <<<"$response")" != ok ]; then
          jq '.["subsonic-response"]' <<<"$response" >&2
          exit 1
        fi
        jq '.["subsonic-response"]' <<<"$response"
      }

      action="''${1:-}"; if [ "$#" -gt 0 ]; then shift; fi
      case "$action" in
        ping) [ "$#" -eq 0 ] || { usage; exit 2; }; subsonic ping ;;
        search) [ "$#" -eq 1 ] || { usage; exit 2; }; subsonic search3 --data-urlencode "query=$1" ;;
        albums)
          [ "$#" -le 1 ] || { usage; exit 2; }
          subsonic getAlbumList2 --data-urlencode "type=''${1:-recent}" --data-urlencode 'size=100'
          ;;
        album) [ "$#" -eq 1 ] || { usage; exit 2; }; subsonic getAlbum --data-urlencode "id=$1" ;;
        song) [ "$#" -eq 1 ] || { usage; exit 2; }; subsonic getSong --data-urlencode "id=$1" ;;
        artists) [ "$#" -eq 0 ] || { usage; exit 2; }; subsonic getArtists ;;
        artist) [ "$#" -eq 1 ] || { usage; exit 2; }; subsonic getArtist --data-urlencode "id=$1" ;;
        playlists) [ "$#" -eq 0 ] || { usage; exit 2; }; subsonic getPlaylists ;;
        playlist) [ "$#" -eq 1 ] || { usage; exit 2; }; subsonic getPlaylist --data-urlencode "id=$1" ;;
        now-playing) [ "$#" -eq 0 ] || { usage; exit 2; }; subsonic getNowPlaying ;;
        starred) [ "$#" -eq 0 ] || { usage; exit 2; }; subsonic getStarred2 ;;
        star|unstar)
          [ "$#" -eq 1 ] || { usage; exit 2; }
          if [ "$action" = star ]; then endpoint=star; else endpoint=unstar; fi
          subsonic "$endpoint" --data-urlencode "id=$1"
          ;;
        play)
          [ "$#" -ge 1 ] && [ "$#" -le 2 ] || { usage; exit 2; }
          song_id="$1"
          target="''${2:-$default_target}"
          case "$target" in
            alan-tv-kodi)
              song="$(subsonic getSong --data-urlencode "id=$song_id")"
              title="$(jq -er '.song.title' <<<"$song")"
              encoded_username="$(jq -rn --arg value "$username" '$value|@uri')"
              encoded_id="$(jq -rn --arg value "$song_id" '$value|@uri')"
              stream_url="$url/rest/stream.view?u=$encoded_username&t=$token&s=$salt&v=1.16.1&c=alanix-openclaw&id=$encoded_id"
              playback="$(jq -cn --arg url "$stream_url" '[$url]' | kodi-control play-audio-urls "$title")"
              jq -cn --argjson song "$song" --argjson playback "$playback" --arg target "$target" \
                '{source: "navidrome", target: $target, item: $song.song, playback: $playback}'
              ;;
            *) echo "Unsupported media target: $target" >&2; exit 64 ;;
          esac
          ;;
        call)
          [ "$#" -ge 1 ] || { usage; exit 2; }
          endpoint="$1"; shift
          arguments=()
          for argument in "$@"; do
            case "$argument" in *=*) arguments+=(--data-urlencode "$argument") ;; *) echo "Expected KEY=VALUE: $argument" >&2; exit 64 ;; esac
          done
          subsonic "$endpoint" "''${arguments[@]}"
          ;;
        *) usage; exit 2 ;;
      esac
    '';
  };

  audiobookshelfControl = pkgs.writeShellApplication {
    name = "audiobookshelf-control";
    runtimeInputs = [ pkgs.coreutils pkgs.curl pkgs.jq ];
    text = ''
      umask 0077
      url=${lib.escapeShellArg (lib.removeSuffix "/" cfg.audiobookshelf.url)}
      username=${lib.escapeShellArg cfg.audiobookshelf.username}
      password_file=${lib.escapeShellArg (passwordPath cfg.audiobookshelf.passwordFile)}
      default_target=${lib.escapeShellArg cfg.defaultTarget}

      usage() {
        cat >&2 <<'EOF'
Usage: audiobookshelf-control ACTION [ARGUMENTS]

Actions:
  libraries
  search QUERY [LIBRARY_ID]
  item ITEM_ID
  play ITEM_ID [TARGET]
  api METHOD /API/PATH [JSON]
EOF
      }

      [ -r "$password_file" ] || { echo "Audiobookshelf password file is missing or unreadable" >&2; exit 78; }
      password="$(tr -d '\r\n' < "$password_file")"
      login_body="$(jq -cn --arg username "$username" --arg password "$password" '{username: $username, password: $password}')"
      login="$(printf '%s' "$login_body" | curl -fsS --header 'Content-Type: application/json' --data-binary @- "$url/login")"
      token="$(jq -er '.user.token // .user.accessToken // .accessToken' <<<"$login")"
      default_library="$(jq -r '.userDefaultLibraryId // .user.userDefaultLibraryId // empty' <<<"$login")"

      request() {
        local method="$1" path="$2" body="''${3:-}"
        local arguments=(-fsS --request "$method" --header "Authorization: Bearer $token" --header 'Accept: application/json')
        case "$path" in /api/*) ;; *) echo "Audiobookshelf API paths must begin with /api/" >&2; exit 64 ;; esac
        if [ -n "$body" ]; then
          arguments+=(--header 'Content-Type: application/json' --data-binary @-)
          printf '%s' "$body" | curl "''${arguments[@]}" "$url$path" | jq .
        else
          curl "''${arguments[@]}" "$url$path" | jq .
        fi
      }

      action="''${1:-}"; if [ "$#" -gt 0 ]; then shift; fi
      case "$action" in
        libraries)
          [ "$#" -eq 0 ] || { usage; exit 2; }
          request GET /api/libraries
          ;;
        search)
          [ "$#" -ge 1 ] && [ "$#" -le 2 ] || { usage; exit 2; }
          library="''${2:-$default_library}"
          [ -n "$library" ] || { echo "No default Audiobookshelf library; pass LIBRARY_ID" >&2; exit 64; }
          query="$(jq -rn --arg v "$1" '$v|@uri')"
          request GET "/api/libraries/$library/search?q=$query"
          ;;
        item)
          [ "$#" -eq 1 ] || { usage; exit 2; }
          request GET "/api/items/$1?expanded=1"
          ;;
        play)
          [ "$#" -ge 1 ] && [ "$#" -le 2 ] || { usage; exit 2; }
          item_id="$1"
          target="''${2:-$default_target}"
          case "$target" in
            alan-tv-kodi)
              item="$(request GET "/api/items/$item_id?expanded=1")"
              title="$(jq -er '.media.metadata.title' <<<"$item")"
              urls="$(jq -c --arg base "$url" --arg token "$token" '
                [
                  .media.tracks[].contentUrl
                  | (split("/") | map(@uri) | join("/")) as $path
                  | $base + $path + "?token=" + ($token | @uri)
                ]
              ' <<<"$item")"
              [ "$(jq 'length' <<<"$urls")" -gt 0 ] || { echo "Audiobookshelf item has no playable tracks" >&2; exit 64; }
              playback="$(printf '%s' "$urls" | kodi-control play-audio-urls "$title")"
              item_summary="$(jq -c '{id, title: .media.metadata.title, mediaType, tracks: (.media.tracks | length)}' <<<"$item")"
              jq -cn --argjson item "$item_summary" --argjson playback "$playback" --arg target "$target" \
                '{source: "audiobookshelf", target: $target, item: $item, playback: $playback}'
              ;;
            *) echo "Unsupported media target: $target" >&2; exit 64 ;;
          esac
          ;;
        api)
          [ "$#" -ge 2 ] && [ "$#" -le 3 ] || { usage; exit 2; }
          method="''${1^^}"
          case "$method" in GET|POST|PATCH|PUT|DELETE) ;; *) echo "Unsupported HTTP method: $method" >&2; exit 64 ;; esac
          request "$method" "$2" "''${3:-}"
          ;;
        *) usage; exit 2 ;;
      esac
    '';
  };

  serviceOptions = name: defaultUrl: {
    enable = lib.mkEnableOption "${name} access for OpenClaw";
    url = lib.mkOption { type = lib.types.str; default = defaultUrl; description = "Stable ${name} base URL."; };
    username = lib.mkOption { type = lib.types.str; default = "buddia"; description = "${name} account used by OpenClaw."; };
    passwordFile = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; description = "Runtime-only file containing the ${name} password."; };
  };
in
{
  options.alanix.openclaw.media = {
    defaultTarget = lib.mkOption {
      type = lib.types.enum [ "alan-tv-kodi" ];
      default = "alan-tv-kodi";
      description = "Structured playback target used when a media command does not name one.";
    };
    jellyfin = serviceOptions "Jellyfin" "https://jellyfin.fifefin.com";
    navidrome = serviceOptions "Navidrome" "https://navidrome.fifefin.com";
    audiobookshelf = serviceOptions "Audiobookshelf" "https://audiobookshelf.fifefin.com";
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.jellyfin.enable {
      assertions = [
        { assertion = config.alanix.openclaw.gateway.enable; message = "Jellyfin access requires alanix.openclaw.gateway.enable."; }
        { assertion = cfg.jellyfin.passwordFile != null; message = "alanix.openclaw.media.jellyfin.passwordFile must be set."; }
        { assertion = config.alanix.openclaw.kodi.enable; message = "Jellyfin default playback requires alanix.openclaw.kodi.enable."; }
      ];
      alanix.openclaw.packages = [ jellyfinControl ];
    })
    (lib.mkIf cfg.navidrome.enable {
      assertions = [
        { assertion = config.alanix.openclaw.gateway.enable; message = "Navidrome access requires alanix.openclaw.gateway.enable."; }
        { assertion = cfg.navidrome.passwordFile != null; message = "alanix.openclaw.media.navidrome.passwordFile must be set."; }
        { assertion = config.alanix.openclaw.kodi.enable; message = "Navidrome default playback requires alanix.openclaw.kodi.enable."; }
      ];
      alanix.openclaw.packages = [ navidromeControl ];
    })
    (lib.mkIf cfg.audiobookshelf.enable {
      assertions = [
        { assertion = config.alanix.openclaw.gateway.enable; message = "Audiobookshelf access requires alanix.openclaw.gateway.enable."; }
        { assertion = cfg.audiobookshelf.passwordFile != null; message = "alanix.openclaw.media.audiobookshelf.passwordFile must be set."; }
        { assertion = config.alanix.openclaw.kodi.enable; message = "Audiobookshelf default playback requires alanix.openclaw.kodi.enable."; }
      ];
      alanix.openclaw.packages = [ audiobookshelfControl ];
    })
  ];
}
