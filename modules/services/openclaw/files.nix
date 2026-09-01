{ config, lib, pkgs, ... }:

let
  cfg = config.alanix.openclaw.files;

  personalFiles = pkgs.writeShellApplication {
    name = "personal-files";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.ripgrep
    ];
    text = ''
      umask 0002

      root=${lib.escapeShellArg cfg.root}

      usage() {
        cat >&2 <<'EOF'
Usage: personal-files ACTION [ARGUMENTS]

Actions:
  root                         Print the configured personal-files root
  list [PATH]                  List files below PATH (defaults to the root)
  find QUERY [PATH]            Find matching file and directory names
  search QUERY [PATH]          Search file contents with ripgrep
  read PATH                    Write one file to stdout
  write PATH                   Atomically replace a file with stdin
  mkdir PATH                   Create a directory and its parents
  move SOURCE DESTINATION      Move a file or directory within the root
  trash PATH                   Move a file into the root's recoverable trash
EOF
      }

      root="$(${pkgs.coreutils}/bin/realpath -m -- "$root")"

      resolve_path() {
        local relative="''${1:-}"
        local resolved

        case "$relative" in
          /*|..|../*|*/../*|*/..)
            echo "Path must stay inside the personal-files root: $relative" >&2
            return 64
            ;;
        esac

        resolved="$(${pkgs.coreutils}/bin/realpath -m -- "$root/$relative")"
        case "$resolved" in
          "$root"|"$root"/*)
            printf '%s\n' "$resolved"
            ;;
          *)
            echo "Path resolves outside the personal-files root: $relative" >&2
            return 64
            ;;
        esac
      }

      require_root() {
        if [ ! -d "$root" ]; then
          echo "Personal-files root does not exist yet: $root" >&2
          echo "Wait for Syncthing to create filebrowser-buddia-files, then retry." >&2
          exit 69
        fi
      }

      action="''${1:-}"
      if [ "$#" -gt 0 ]; then
        shift
      fi

      case "$action" in
        root)
          [ "$#" -eq 0 ] || { usage; exit 2; }
          printf '%s\n' "$root"
          ;;
        list)
          [ "$#" -le 1 ] || { usage; exit 2; }
          require_root
          target="$(resolve_path "''${1:-}")"
          [ -e "$target" ] || { echo "Path does not exist: ''${1:-}" >&2; exit 66; }
          if [ -d "$target" ]; then
            find "$target" -mindepth 1 -maxdepth 2 -printf '%y\t%P\n' | sort
          else
            printf 'f\t%s\n' "$(basename -- "$target")"
          fi
          ;;
        find)
          [ "$#" -ge 1 ] && [ "$#" -le 2 ] || { usage; exit 2; }
          require_root
          query="$1"
          target="$(resolve_path "''${2:-}")"
          [ -d "$target" ] || { echo "Search path is not a directory: ''${2:-}" >&2; exit 66; }
          find "$target" -mindepth 1 -printf '%P\n' | rg --ignore-case --fixed-strings -- "$query"
          ;;
        search)
          [ "$#" -ge 1 ] && [ "$#" -le 2 ] || { usage; exit 2; }
          require_root
          query="$1"
          target="$(resolve_path "''${2:-}")"
          [ -d "$target" ] || { echo "Search path is not a directory: ''${2:-}" >&2; exit 66; }
          rg --line-number --ignore-case --hidden --glob '!.stfolder/**' -- "$query" "$target"
          ;;
        read)
          [ "$#" -eq 1 ] || { usage; exit 2; }
          require_root
          target="$(resolve_path "$1")"
          [ -f "$target" ] || { echo "Not a regular file: $1" >&2; exit 66; }
          cat -- "$target"
          ;;
        write)
          [ "$#" -eq 1 ] || { usage; exit 2; }
          require_root
          target="$(resolve_path "$1")"
          parent="$(dirname -- "$target")"
          mkdir -p -- "$parent"
          temporary="$(mktemp --tmpdir="$parent" .openclaw-write.XXXXXX)"
          trap 'rm -f -- "$temporary"' EXIT
          cat > "$temporary"
          chmod 0664 "$temporary"
          mv -f -- "$temporary" "$target"
          trap - EXIT
          ;;
        mkdir)
          [ "$#" -eq 1 ] || { usage; exit 2; }
          require_root
          target="$(resolve_path "$1")"
          mkdir -p -- "$target"
          chmod 0775 "$target"
          ;;
        move)
          [ "$#" -eq 2 ] || { usage; exit 2; }
          require_root
          source="$(resolve_path "$1")"
          destination="$(resolve_path "$2")"
          [ -e "$source" ] || { echo "Source does not exist: $1" >&2; exit 66; }
          mkdir -p -- "$(dirname -- "$destination")"
          mv -- "$source" "$destination"
          ;;
        trash)
          [ "$#" -eq 1 ] || { usage; exit 2; }
          require_root
          source="$(resolve_path "$1")"
          [ "$source" != "$root" ] || { echo "Refusing to trash the personal-files root" >&2; exit 64; }
          [ -e "$source" ] || { echo "Path does not exist: $1" >&2; exit 66; }
          trash_dir="$root/.openclaw-trash/$(date -u +%Y%m%dT%H%M%SZ)"
          mkdir -p -- "$trash_dir"
          destination="$trash_dir/$(basename -- "$source")"
          if [ -e "$destination" ]; then
            destination="$destination.$RANDOM"
          fi
          mv -- "$source" "$destination"
          printf '%s\n' "''${destination#"$root"/}"
          ;;
        *)
          usage
          exit 2
          ;;
      esac
    '';
  };
in
{
  options.alanix.openclaw.files = {
    enable = lib.mkEnableOption "personal files backed by the File Browser Syncthing folder";

    root = lib.mkOption {
      type = lib.types.str;
      description = "Absolute path to the personal-files root exposed to OpenClaw.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.alanix.openclaw.gateway.enable;
        message = "alanix.openclaw.files requires alanix.openclaw.gateway.enable.";
      }
      {
        assertion = lib.hasPrefix "/" cfg.root;
        message = "alanix.openclaw.files.root must be an absolute path.";
      }
    ];

    alanix.openclaw.packages = [ personalFiles ];
  };
}
