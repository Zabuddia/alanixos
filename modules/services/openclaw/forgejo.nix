{ config, lib, pkgs, ... }:

let
  cfg = config.alanix.openclaw.forgejo;
  passwordFile = if cfg.passwordFile != null then cfg.passwordFile else "";

  forgejoControl = pkgs.writeShellApplication {
    name = "forgejo-control";
    runtimeInputs = [ pkgs.coreutils pkgs.curl pkgs.jq ];
    text = ''
      umask 0077

      url=${lib.escapeShellArg (lib.removeSuffix "/" cfg.url)}
      username=${lib.escapeShellArg cfg.username}
      password_file=${lib.escapeShellArg passwordFile}

      usage() {
        cat >&2 <<'EOF'
Usage: forgejo-control ACTION [ARGUMENTS]

Actions:
  me
  repos
  repo OWNER REPO
  issues OWNER REPO [STATE]
  pulls OWNER REPO [STATE]
  issue OWNER REPO NUMBER
  create-issue OWNER REPO TITLE [BODY]
  comment OWNER REPO NUMBER BODY
  create-pr OWNER REPO TITLE HEAD BASE [BODY]
  api METHOD /API/PATH [JSON]
EOF
      }

      if [ ! -r "$password_file" ]; then
        echo "Forgejo password file is missing or unreadable" >&2
        exit 78
      fi
      password="$(tr -d '\r\n' < "$password_file")"

      validate_name() {
        [[ "$1" =~ ^[A-Za-z0-9_.-]+$ ]] || {
          echo "Invalid Forgejo owner or repository name: $1" >&2
          exit 64
        }
      }

      validate_number() {
        [[ "$1" =~ ^[0-9]+$ ]] || {
          echo "Expected a numeric issue or pull-request number: $1" >&2
          exit 64
        }
      }

      request() {
        local method="$1"
        local path="$2"
        local body="''${3:-}"
        local arguments=(-fsS --request "$method" --user "$username:$password" --header 'Accept: application/json')

        case "$path" in
          /api/*) ;;
          *) echo "Forgejo API paths must begin with /api/: $path" >&2; exit 64 ;;
        esac

        if [ -n "$body" ]; then
          arguments+=(--header 'Content-Type: application/json' --data-binary @-)
          printf '%s' "$body" | curl "''${arguments[@]}" "$url$path" | jq .
        else
          curl "''${arguments[@]}" "$url$path" | jq .
        fi
      }

      action="''${1:-}"
      if [ "$#" -gt 0 ]; then shift; fi

      case "$action" in
        me)
          [ "$#" -eq 0 ] || { usage; exit 2; }
          request GET /api/v1/user
          ;;
        repos)
          [ "$#" -eq 0 ] || { usage; exit 2; }
          request GET '/api/v1/user/repos?limit=100&sort=updated'
          ;;
        repo)
          [ "$#" -eq 2 ] || { usage; exit 2; }
          validate_name "$1"; validate_name "$2"
          request GET "/api/v1/repos/$1/$2"
          ;;
        issues|pulls)
          [ "$#" -ge 2 ] && [ "$#" -le 3 ] || { usage; exit 2; }
          validate_name "$1"; validate_name "$2"
          state="''${3:-open}"
          case "$state" in open|closed|all) ;; *) echo "State must be open, closed, or all" >&2; exit 64 ;; esac
          if [ "$action" = issues ]; then
            request GET "/api/v1/repos/$1/$2/issues?state=$state&limit=100"
          else
            request GET "/api/v1/repos/$1/$2/pulls?state=$state&limit=100"
          fi
          ;;
        issue)
          [ "$#" -eq 3 ] || { usage; exit 2; }
          validate_name "$1"; validate_name "$2"; validate_number "$3"
          request GET "/api/v1/repos/$1/$2/issues/$3"
          ;;
        create-issue)
          [ "$#" -ge 3 ] && [ "$#" -le 4 ] || { usage; exit 2; }
          validate_name "$1"; validate_name "$2"
          body="$(jq -cn --arg title "$3" --arg body "''${4:-}" '{title: $title, body: $body}')"
          request POST "/api/v1/repos/$1/$2/issues" "$body"
          ;;
        comment)
          [ "$#" -eq 4 ] || { usage; exit 2; }
          validate_name "$1"; validate_name "$2"; validate_number "$3"
          body="$(jq -cn --arg body "$4" '{body: $body}')"
          request POST "/api/v1/repos/$1/$2/issues/$3/comments" "$body"
          ;;
        create-pr)
          [ "$#" -ge 5 ] && [ "$#" -le 6 ] || { usage; exit 2; }
          validate_name "$1"; validate_name "$2"
          body="$(jq -cn --arg title "$3" --arg head "$4" --arg base "$5" --arg body "''${6:-}" \
            '{title: $title, head: $head, base: $base, body: $body}')"
          request POST "/api/v1/repos/$1/$2/pulls" "$body"
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
in
{
  options.alanix.openclaw.forgejo = {
    enable = lib.mkEnableOption "Forgejo API access for OpenClaw";

    url = lib.mkOption {
      type = lib.types.str;
      default = "https://forgejo.fifefin.com";
      description = "Stable Forgejo base URL.";
    };

    username = lib.mkOption {
      type = lib.types.str;
      default = "buddia";
      description = "Forgejo account used by OpenClaw.";
    };

    passwordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Runtime-only file containing the Forgejo password.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.alanix.openclaw.gateway.enable;
        message = "alanix.openclaw.forgejo requires alanix.openclaw.gateway.enable.";
      }
      {
        assertion = cfg.passwordFile != null;
        message = "alanix.openclaw.forgejo.passwordFile must be set.";
      }
    ];

    alanix.openclaw.packages = [ forgejoControl ];
  };
}
