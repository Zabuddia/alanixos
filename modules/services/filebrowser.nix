{ config, lib, pkgs, ... }:
let
  cfg = config.alanix.filebrowser;

  dbPath = cfg.database;

  declaredUsernames = builtins.attrNames cfg.users;

  # Plain list; we'll escape it once inside the script.
  declaredUsersList = lib.concatStringsSep " " declaredUsernames;
in
{
  options.alanix.filebrowser = {
    enable = lib.mkEnableOption "File Browser (Alanix)";

    listenAddress = lib.mkOption {
      type = lib.types.str;
    };

    port = lib.mkOption {
      type = lib.types.port;
    };

    root = lib.mkOption {
      type = lib.types.str;
    };

    database = lib.mkOption {
      type = lib.types.str;
    };

    users = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
        options = {
          admin = lib.mkOption {
            type = lib.types.bool;
          };

          scope = lib.mkOption {
            type = lib.types.str;
            description = "User scope relative to alanix.filebrowser.root (e.g. users/buddia).";
          };

          password = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Plaintext password (simple, not recommended).";
          };

          passwordFile = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = "Path to a file containing the plaintext password (works with or without sops).";
          };

          passwordSecret = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Name of sops secret containing the plaintext password (optional).";
          };
        };
      }));
      default = {};
      description = "Declarative File Browser users. Users get separate directories via per-user scope under root.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Validate that each user has exactly one password source.
    assertions =
      [
        {
          assertion = cfg.users != { };
          message = "alanix.filebrowser: users must not be empty when enable = true.";
        }
      ]
      ++ lib.flatten (lib.mapAttrsToList (uname: u:
        let
          chosen = lib.filter (x: x) [
            (u.password != null)
            (u.passwordFile != null)
            (u.passwordSecret != null)
          ];
        in [
          {
            assertion = (builtins.length chosen) == 1;
            message = "alanix.filebrowser.users.${uname}: set exactly one of password, passwordFile, or passwordSecret.";
          }
        ]
      ) cfg.users);

    services.filebrowser = {
      enable = true;
      user = "filebrowser";
      group = "filebrowser";

      settings = {
        address = cfg.listenAddress;
        port = cfg.port;
        root = cfg.root;
        database = dbPath;
      };
    };

    users.groups.filebrowser = {};
    users.users.filebrowser = {
      isSystemUser = true;
      group = "filebrowser";
      home = "/var/lib/filebrowser";
      createHome = true;
    };

    # Base + per-user directories (owned by filebrowser so uploads work)
    systemd.tmpfiles.rules =
      [
        "d /var/lib/filebrowser 0750 filebrowser filebrowser - -"
        "d ${cfg.root} 0770 filebrowser filebrowser - -"
        "d ${cfg.root}/users 0770 filebrowser filebrowser - -"
      ]
      ++ (lib.mapAttrsToList (uname: u:
        "d ${cfg.root}/${u.scope} 0770 filebrowser filebrowser - -"
      ) cfg.users);

    environment.systemPackages = [ pkgs.filebrowser ];

    # Reconcile users iff users are declared
    systemd.services.filebrowser-reconcile-users = lib.mkIf (cfg.users != {}) {
      description = "Reconcile File Browser users (create declared; remove undeclared)";
      before = [ "filebrowser.service" ];
      requiredBy = [ "filebrowser.service" ];

      after = [ "systemd-tmpfiles-setup.service" "sops-nix.service" ];
      wants = [ "systemd-tmpfiles-setup.service" "sops-nix.service" ];

      serviceConfig = {
        Type = "oneshot";
        User = "filebrowser";
        Group = "filebrowser";
        RuntimeDirectory = "alanix-filebrowser";
        RuntimeDirectoryMode = "0700";
      };

      path = [ pkgs.filebrowser pkgs.coreutils pkgs.gnugrep pkgs.gawk ];

      script =
        let
          # Compute PASSFILE_<user> variables.
          passfileLines =
            lib.concatStringsSep "\n"
              (lib.mapAttrsToList (uname: u:
                let
                  var = "PASSFILE_" + lib.replaceStrings [ "-" "." ] [ "_" "_" ] uname;
                in
                if u.passwordFile != null then
                  ''${var}=${lib.escapeShellArg (toString u.passwordFile)}''
                else if u.passwordSecret != null then
                  ''${var}=${lib.escapeShellArg config.sops.secrets.${u.passwordSecret}.path}''
                else
                  ''${var}="$RUNTIME_DIRECTORY/${lib.escapeShellArg uname}.pass"; ensure_runtime_passfile "${"$"}${var}" ${lib.escapeShellArg u.password}''
              ) cfg.users);

          # Ensure user exists with scope + admin flag.
          ensureLines =
            lib.concatStringsSep "\n"
              (lib.mapAttrsToList (uname: u:
                let
                  var = "PASSFILE_" + lib.replaceStrings [ "-" "." ] [ "_" "_" ] uname;
                  adminFlag = if u.admin then "1" else "0";
                  scopeArg = u.scope;
                in
                ''ensure_user ${lib.escapeShellArg uname} "${"$"}${var}" ${adminFlag} ${lib.escapeShellArg scopeArg}''
              ) cfg.users);
        in
        ''
          set -euo pipefail

          DB=${lib.escapeShellArg dbPath}
          DECLARED=${lib.escapeShellArg declaredUsersList}

          have_user() {
            filebrowser users ls --database "$DB" | awk 'NR>1 {print $2}' | grep -qx "$1"
          }

          ensure_runtime_passfile() {
            local path="$1"
            local value="$2"
            umask 077
            printf '%s' "$value" > "$path"
          }

          ensure_user() {
            local name="$1"
            local passfile="$2"
            local is_admin="$3"
            local scope="$4"

            local pw
            pw="$(cat "$passfile")"

            if have_user "$name"; then
              # Update user to match declared state (including scope/admin/password)
              if [ "$is_admin" = "1" ]; then
                filebrowser users update "$name" \
                  --database "$DB" \
                  --scope "$scope" \
                  --perm.admin \
                  --password "$pw"
              else
                filebrowser users update "$name" \
                  --database "$DB" \
                  --scope "$scope" \
                  --perm.admin=false \
                  --password "$pw"
              fi
              return 0
            fi

            # Create user if missing
            if [ "$is_admin" = "1" ]; then
              filebrowser users add "$name" "$pw" --database "$DB" --scope "$scope" --perm.admin
            else
              filebrowser users add "$name" "$pw" --database "$DB" --scope "$scope"
            fi
          }

          ${passfileLines}

          ${ensureLines}

          # Remove undeclared users (best-effort; File Browser may refuse deleting the first user)
          filebrowser users ls --database "$DB" | awk 'NR>1 {print $2}' | while read -r u; do
            keep=0
            for d in $DECLARED; do
              if [ "$u" = "$d" ]; then keep=1; fi
            done
            if [ "$keep" -eq 0 ]; then
              echo "Removing undeclared user: $u"
              if ! filebrowser users rm "$u" --database "$DB"; then
                echo "Could not remove undeclared user: $u (File Browser may refuse deleting the first user). Leaving it."
              fi
            fi
          done
        '';
    };

    # Make the filebrowser service restart whenever the user config is changed
    systemd.services.filebrowser.restartTriggers = [
      (builtins.toJSON cfg.users)
    ];

  };
}
