{ config, lib, pkgs, ... }:

let
  cfg = config.alanix.openclaw.audiobookshelf;
  passwordPath = if cfg.passwordFile != null then cfg.passwordFile else "";

  audiobookshelfControl = pkgs.writeShellApplication {
    name = "audiobookshelf-control";
    runtimeInputs = [ pkgs.coreutils pkgs.curl pkgs.jq ];
    text = ''
      umask 0077
      url=${lib.escapeShellArg (lib.removeSuffix "/" cfg.url)}
      username=${lib.escapeShellArg cfg.username}
      password_file=${lib.escapeShellArg passwordPath}

      usage() {
        cat >&2 <<'EOF'
Usage: audiobookshelf-control ACTION [ARGUMENTS]

Actions:
  search-books QUERY
  books
  book ITEM_ID
  in-progress
  progress ITEM_ID
  play ITEM_ID
EOF
      }

      [ -r "$password_file" ] || { echo "Audiobookshelf password file is missing or unreadable" >&2; exit 78; }
      password="$(tr -d '\r\n' < "$password_file")"
      login_body="$(jq -cn --arg username "$username" --arg password "$password" '{username: $username, password: $password}')"
      login="$(printf '%s' "$login_body" | curl -fsS \
        --header 'Content-Type: application/json' \
        --header 'x-return-tokens: true' \
        --data-binary @- "$url/login")"
      unset password
      token="$(jq -er '.accessToken // .user.accessToken // .user.token' <<<"$login")"

      get() {
        curl -fsS --header "Authorization: Bearer $token" --header 'Accept: application/json' "$url$1"
      }

      valid_id() {
        [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "Invalid Audiobookshelf item ID" >&2; exit 64; }
      }

      all_books() {
        libraries="$(get /api/libraries)"
        books='[]'
        while IFS= read -r library_id; do
          page="$(get "/api/libraries/$library_id/items?limit=0&minified=0")"
          books="$(jq -cn --argjson current "$books" --argjson page "$page" \
            '$current + [$page.results[]? | select(.mediaType == "book")]')"
        done < <(jq -r '.libraries[]? | select(.mediaType == "book") | .id' <<<"$libraries")
        printf '%s\n' "$books"
      }

      summarize_books() {
        jq '[.[] | {
          id,
          title: .media.metadata.title,
          author: .media.metadata.authorName,
          narrator: .media.metadata.narratorName,
          series: .media.metadata.seriesName,
          publishedYear: .media.metadata.publishedYear
        }]'
      }

      progress_for() {
        item_id="$1"
        item="$2"
        response="$(curl -sS --header "Authorization: Bearer $token" \
          --header 'Accept: application/json' \
          --write-out $'\n%{http_code}' "$url/api/me/progress/$item_id")"
        status="''${response##*$'\n'}"
        body="''${response%$'\n'*}"
        case "$status" in
          200) progress="$body" ;;
          404) progress='null' ;;
          *) echo "Audiobookshelf progress request failed with HTTP $status" >&2; exit 1 ;;
        esac
        jq -cn --argjson item "$item" --argjson progress "$progress" '
          ($progress.duration // $item.media.duration // 0) as $duration |
          ($progress.currentTime // 0) as $current |
          {
            id: $item.id,
            title: $item.media.metadata.title,
            author: $item.media.metadata.authorName,
            progressFraction: (if $duration > 0 then $current / $duration else 0 end),
            currentTimeSeconds: $current,
            durationSeconds: $duration,
            remainingSeconds: ([$duration - $current, 0] | max),
            isFinished: ($progress.isFinished // false),
            lastUpdateEpochMilliseconds: $progress.lastUpdate
          }
        '
      }

      action="''${1:-}"
      if [ "$#" -gt 0 ]; then shift; fi
      case "$action" in
        search-books)
          [ "$#" -eq 1 ] || { usage; exit 2; }
          all_books | summarize_books | jq --arg query "$1" '
            def normalized: ascii_downcase | gsub("[^a-z0-9]"; "");
            [.[] | select((.title | normalized) | contains($query | normalized))] |
            {books: ., total: length}
          '
          ;;
        books)
          [ "$#" -eq 0 ] || { usage; exit 2; }
          all_books | summarize_books |
            jq '{books: [.[] | {title, author, narrator, series, publishedYear}], total: length}'
          ;;
        book)
          [ "$#" -eq 1 ] || { usage; exit 2; }
          valid_id "$1"
          get "/api/items/$1?expanded=1" |
            jq '{
              id,
              title: .media.metadata.title,
              author: .media.metadata.authorName,
              narrator: .media.metadata.narratorName,
              series: .media.metadata.seriesName,
              publishedYear: .media.metadata.publishedYear,
              durationSeconds: .media.duration
            }'
          ;;
        in-progress)
          [ "$#" -eq 0 ] || { usage; exit 2; }
          items="$(get /api/me/items-in-progress)"
          results='[]'
          while IFS= read -r item; do
            item_id="$(jq -er '.id' <<<"$item")"
            progress="$(progress_for "$item_id" "$item")"
            results="$(jq -cn --argjson current "$results" --argjson progress "$progress" '$current + [$progress]')"
          done < <(jq -c '.libraryItems[]? | select(.mediaType == "book")' <<<"$items")
          jq -cn --argjson books "$results" '{books: $books, total: ($books | length)}'
          ;;
        progress)
          [ "$#" -eq 1 ] || { usage; exit 2; }
          valid_id "$1"
          item="$(get "/api/items/$1?expanded=1")"
          progress_for "$1" "$item"
          ;;
        play)
          [ "$#" -eq 1 ] || { usage; exit 2; }
          valid_id "$1"
          item="$(get "/api/items/$1?expanded=1")"
          [ "$(jq -r '.mediaType' <<<"$item")" = book ] || { echo "Audiobookshelf playback currently supports books" >&2; exit 64; }
          title="$(jq -er '.media.metadata.title' <<<"$item")"
          progress="$(progress_for "$1" "$item")"
          current_time="$(jq -er '.currentTimeSeconds | floor' <<<"$progress")"
          duration="$(jq -er '.durationSeconds' <<<"$progress")"
          is_finished="$(jq -r '.isFinished' <<<"$progress")"
          if [ "$is_finished" = true ]; then
            current_time=0
          fi
          target="$(jq -cer --argjson position "$current_time" '
            [.media.audioFiles[]?] | sort_by(.index // 0) |
            reduce .[] as $file (
              {offset: 0, target: null};
              if .target == null and $position < (.offset + ($file.duration // 0)) then
                .target = {
                  fileIno: $file.ino,
                  seekTimeSeconds: (($position - .offset) | floor)
                }
              else
                .offset += ($file.duration // 0)
              end
            ) |
            (.target // error("Audiobook has no audio file for its saved position"))
          ' <<<"$item")"
          file_ino="$(jq -er '.fileIno | tostring' <<<"$target")"
          seek_time="$(jq -er '.seekTimeSeconds' <<<"$target")"
          if ! playback="$(kodi-control play-audiobookshelf \
            "$1" "$title" "$file_ino" "$seek_time" "$current_time")"; then
            restore_body="$(jq -cn \
              --argjson currentTime "$current_time" \
              --argjson duration "$duration" \
              --argjson isFinished "$is_finished" \
              '{
                currentTime: $currentTime,
                duration: $duration,
                isFinished: $isFinished,
                progress: (if $duration > 0 then $currentTime / $duration else 0 end)
              }')"
            printf '%s' "$restore_body" | curl -fsS --request PATCH \
              --header "Authorization: Bearer $token" \
              --header 'Content-Type: application/json' \
              --data-binary @- "$url/api/me/progress/$1" >/dev/null || true
            printf '%s\n' "$playback"
            exit 1
          fi
          jq -cn --arg id "$1" --arg title "$title" --argjson playback "$playback" \
            '{item: {id: $id, title: $title}, playback: $playback}'
          ;;
        *) usage; exit 2 ;;
      esac
    '';
  };
in
{
  options.alanix.openclaw.audiobookshelf = {
    enable = lib.mkEnableOption "focused Audiobookshelf access for OpenClaw";
    url = lib.mkOption {
      type = lib.types.str;
      default = "https://audiobookshelf.fifefin.com";
      description = "Stable Audiobookshelf base URL.";
    };
    username = lib.mkOption {
      type = lib.types.str;
      default = "buddia";
      description = "Audiobookshelf account used by OpenClaw.";
    };
    passwordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Runtime-only file containing the Audiobookshelf password.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.alanix.openclaw.gateway.enable;
        message = "Audiobookshelf access requires alanix.openclaw.gateway.enable.";
      }
      {
        assertion = config.alanix.openclaw.kodi.enable;
        message = "Audiobookshelf playback requires alanix.openclaw.kodi.enable.";
      }
      {
        assertion = cfg.passwordFile != null;
        message = "alanix.openclaw.audiobookshelf.passwordFile must be set.";
      }
    ];
    alanix.openclaw.packages = [ audiobookshelfControl ];
  };
}
