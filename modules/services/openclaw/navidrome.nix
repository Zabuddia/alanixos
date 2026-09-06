{ config, lib, pkgs, ... }:

let
  cfg = config.alanix.openclaw.navidrome;
  passwordPath = if cfg.passwordFile != null then cfg.passwordFile else "";

  navidromeControl = pkgs.writeShellApplication {
    name = "navidrome-control";
    runtimeInputs = [ pkgs.coreutils pkgs.curl pkgs.jq pkgs.openssl ];
    text = ''
      umask 0077
      url=${lib.escapeShellArg (lib.removeSuffix "/" cfg.url)}
      username=${lib.escapeShellArg cfg.username}
      password_file=${lib.escapeShellArg passwordPath}

      usage() {
        cat >&2 <<'EOF'
Usage: navidrome-control ACTION [ARGUMENTS]

Actions:
  search-song TITLE ARTIST
  songs-by-artist ARTIST
  albums-by-artist ARTIST
  album ALBUM_ID
  activity
  play-song SONG_ID
  play-album ALBUM_ID
EOF
      }

      [ -r "$password_file" ] || { echo "Navidrome password file is missing or unreadable" >&2; exit 78; }
      password="$(tr -d '\r\n' < "$password_file")"
      salt="$(openssl rand -hex 12)"
      token="$(printf '%s' "$password$salt" | md5sum | cut -d' ' -f1)"
      unset password

      subsonic() {
        local endpoint="$1"
        shift
        [[ "$endpoint" =~ ^[A-Za-z0-9]+$ ]] || { echo "Invalid Subsonic endpoint" >&2; exit 64; }
        response="$(curl -fsS --get "$url/rest/$endpoint.view" \
          --data-urlencode "u=$username" \
          --data-urlencode "t=$token" \
          --data-urlencode "s=$salt" \
          --data-urlencode 'v=1.16.1' \
          --data-urlencode 'c=alanix-openclaw' \
          --data-urlencode 'f=json' \
          "$@")"
        if [ "$(jq -r '.["subsonic-response"].status' <<<"$response")" != ok ]; then
          jq '.["subsonic-response"].error // {message: "Navidrome request failed"}' <<<"$response" >&2
          exit 1
        fi
        jq '.["subsonic-response"]' <<<"$response"
      }

      valid_id() {
        [ -n "$1" ] && [ "''${#1}" -le 512 ] || { echo "Invalid Navidrome item ID" >&2; exit 64; }
      }

      resolve_artist() {
        result="$(subsonic search3 \
          --data-urlencode "query=$1" \
          --data-urlencode 'artistCount=50' \
          --data-urlencode 'albumCount=0' \
          --data-urlencode 'songCount=0')"
        matches="$(jq -c --arg query "$1" '
          def normalized: ascii_downcase | gsub("[^a-z0-9]"; "");
          [.searchResult3.artist[]? | select((.name | normalized) == ($query | normalized))]
        ' <<<"$result")"
        count="$(jq 'length' <<<"$matches")"
        if [ "$count" -ne 1 ]; then
          jq -cn --arg query "$1" --argjson matches "$matches" \
            '{error: "Expected one exact Navidrome artist match", query: $query, candidates: ($matches | map(.name))}' >&2
          exit 1
        fi
        jq -c '.[0]' <<<"$matches"
      }

      artist_albums() {
        artist="$(resolve_artist "$1")"
        artist_id="$(jq -er '.id' <<<"$artist")"
        subsonic getArtist --data-urlencode "id=$artist_id" |
          jq --argjson artist "$artist" '
            {
              artist: {id: $artist.id, name: $artist.name},
              albums: [.artist.album[]? | {
                id,
                title: .name,
                artist,
                year,
                songCount,
                durationSeconds: .duration
              }],
              total: ([.artist.album[]?] | length)
            }
          '
      }

      artist_songs() {
        albums="$(artist_albums "$1")"
        songs='[]'
        while IFS= read -r album_id; do
          album="$(subsonic getAlbum --data-urlencode "id=$album_id")"
          songs="$(jq -cn --argjson current "$songs" --argjson album "$album" \
            '
              $current + [$album.album.song[]? | {
                id,
                title,
                artist,
                album,
                track,
                year,
                durationSeconds: .duration
              }]
            ')"
        done < <(jq -r '.albums[].id' <<<"$albums")
        jq -cn --argjson albums "$albums" --argjson songs "$songs" \
          '{artist: $albums.artist, songs: $songs, total: ($songs | length)}'
      }

      action="''${1:-}"
      if [ "$#" -gt 0 ]; then shift; fi
      case "$action" in
        search-song)
          [ "$#" -eq 2 ] || { usage; exit 2; }
          result="$(artist_songs "$2")"
          jq --arg title "$1" '
            def normalized: ascii_downcase | gsub("[^a-z0-9]"; "");
            .songs |= map(select((.title | normalized) == ($title | normalized))) |
            .total = (.songs | length)
          ' <<<"$result"
          ;;
        songs-by-artist)
          [ "$#" -eq 1 ] || { usage; exit 2; }
          artist_songs "$1" |
            jq '.songs |= map({title, album, track, year})'
          ;;
        albums-by-artist)
          [ "$#" -eq 1 ] || { usage; exit 2; }
          artist_albums "$1"
          ;;
        album)
          [ "$#" -eq 1 ] || { usage; exit 2; }
          valid_id "$1"
          subsonic getAlbum --data-urlencode "id=$1" |
            jq '
              {
                album: {
                  id: .album.id,
                  title: .album.name,
                  artist: .album.artist,
                  year: .album.year,
                  songCount: .album.songCount,
                  durationSeconds: .album.duration
                },
                songs: [.album.song[]? | {
                  id,
                  title,
                  artist,
                  album,
                  track,
                  year,
                  durationSeconds: .duration
                }]
              }
            '
          ;;
        activity)
          [ "$#" -eq 0 ] || { usage; exit 2; }
          subsonic getNowPlaying |
            jq '{active: [.nowPlaying.entry[]? | {id, title, artist, album, user: .username, client: .playerName, minutesAgo}], count: ([.nowPlaying.entry[]?] | length)}'
          ;;
        play-song)
          [ "$#" -eq 1 ] || { usage; exit 2; }
          valid_id "$1"
          song="$(subsonic getSong --data-urlencode "id=$1" | jq -c '
            .song | {
              id,
              title,
              artist,
              album,
              track,
              year,
              durationSeconds: .duration
            }
          ')"
          playback="$(kodi-control play-navidrome-song \
            "$(jq -r '.id' <<<"$song")" \
            "$(jq -r '.title' <<<"$song")" \
            "$(jq -r '.artist' <<<"$song")")"
          jq -cn --argjson item "$song" --argjson playback "$playback" \
            '{item: $item, playback: $playback}'
          ;;
        play-album)
          [ "$#" -eq 1 ] || { usage; exit 2; }
          valid_id "$1"
          album="$(subsonic getAlbum --data-urlencode "id=$1")"
          summary="$(jq -c '
            .album | {
              id,
              title: .name,
              artist,
              year,
              songCount,
              durationSeconds: .duration
            }
          ' <<<"$album")"
          tracks="$(jq -c '[.album.song[]? | {id, title, artist}]' <<<"$album")"
          [ "$(jq 'length' <<<"$tracks")" -gt 0 ] || { echo "Navidrome album has no playable songs" >&2; exit 1; }
          playback="$(printf '%s' "$tracks" | kodi-control play-navidrome-album \
            "$(jq -r '.title' <<<"$summary")")"
          jq -cn --argjson item "$summary" --argjson playback "$playback" \
            '{item: $item, playback: $playback}'
          ;;
        *) usage; exit 2 ;;
      esac
    '';
  };
in
{
  options.alanix.openclaw.navidrome = {
    enable = lib.mkEnableOption "focused Navidrome access for OpenClaw";
    url = lib.mkOption {
      type = lib.types.str;
      default = "https://navidrome.fifefin.com";
      description = "Stable Navidrome base URL.";
    };
    username = lib.mkOption {
      type = lib.types.str;
      default = "buddia";
      description = "Navidrome account used by OpenClaw.";
    };
    passwordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Runtime-only file containing the Navidrome password.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.alanix.openclaw.gateway.enable;
        message = "Navidrome access requires alanix.openclaw.gateway.enable.";
      }
      {
        assertion = config.alanix.openclaw.kodi.enable;
        message = "Navidrome playback requires alanix.openclaw.kodi.enable.";
      }
      {
        assertion = cfg.passwordFile != null;
        message = "alanix.openclaw.navidrome.passwordFile must be set.";
      }
    ];
    alanix.openclaw.packages = [ navidromeControl ];
  };
}
