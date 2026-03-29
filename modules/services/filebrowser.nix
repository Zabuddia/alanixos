{ config, lib, pkgs, ... }:
let
  cfg = config.alanix.filebrowser;

  dbPath = cfg.database;

  declaredUsernames = builtins.attrNames cfg.users;
  declaredUsersList = lib.concatStringsSep " " declaredUsernames;
  hasValue = value: value != null && value != "";
  baseConfigReady =
    hasValue cfg.listenAddress
    && cfg.port != null
    && hasValue cfg.root
    && hasValue cfg.database;
  declaredScopes =
    lib.filter (scope: scope != null) (lib.mapAttrsToList (_: userCfg: userCfg.scope) cfg.users);
  sanitizedUsersForRestart =
    lib.mapAttrs
      (_: userCfg:
        userCfg
        // {
          password =
            if userCfg.password == null then
              null
            else
              builtins.hashString "sha256" userCfg.password;
        })
      cfg.users;
in
{
  options.alanix.filebrowser = {
    enable = lib.mkEnableOption "File Browser (Alanix)";

    listenAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };

    port = lib.mkOption {
      type = lib.types.nullOr lib.types.port;
      default = null;
    };

    root = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };

    database = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };

    users = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
        options = {
          admin = lib.mkOption {
            type = lib.types.bool;
            default = false;
          };

          scope = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
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
    assertions =
      [
        {
          assertion = cfg.users != { };
          message = "alanix.filebrowser: users must not be empty when enable = true.";
        }
        {
          assertion = hasValue cfg.listenAddress;
          message = "alanix.filebrowser.listenAddress must be set when alanix.filebrowser.enable = true.";
        }
        {
          assertion = cfg.port != null;
          message = "alanix.filebrowser.port must be set when alanix.filebrowser.enable = true.";
        }
        {
          assertion = hasValue cfg.root;
          message = "alanix.filebrowser.root must be set when alanix.filebrowser.enable = true.";
        }
        {
          assertion = hasValue cfg.database;
          message = "alanix.filebrowser.database must be set when alanix.filebrowser.enable = true.";
        }
        {
          assertion = cfg.root == null || lib.hasPrefix "/" cfg.root;
          message = "alanix.filebrowser.root must be an absolute path.";
        }
        {
          assertion = cfg.database == null || lib.hasPrefix "/" cfg.database;
          message = "alanix.filebrowser.database must be an absolute path.";
        }
        {
          assertion = lib.length declaredScopes == lib.length (lib.unique declaredScopes);
          message = "alanix.filebrowser.users.*.scope must be unique.";
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
            assertion = builtins.match "^[A-Za-z0-9._-]+$" uname != null;
            message = "alanix.filebrowser.users.${uname}: usernames may contain only letters, digits, dot, underscore, and hyphen.";
          }
          {
            assertion = (builtins.length chosen) == 1;
            message = "alanix.filebrowser.users.${uname}: set exactly one of password, passwordFile, or passwordSecret.";
          }
          {
            assertion = hasValue u.scope;
            message = "alanix.filebrowser.users.${uname}.scope must be set.";
          }
          {
            assertion = u.scope == null || !lib.hasPrefix "/" u.scope;
            message = "alanix.filebrowser.users.${uname}.scope must be relative to alanix.filebrowser.root.";
          }
          {
            assertion = u.passwordSecret == null || lib.hasAttrByPath [ "sops" "secrets" u.passwordSecret ] config;
            message = "alanix.filebrowser.users.${uname}.passwordSecret must reference a declared sops secret.";
          }
        ]
      ) cfg.users);

    services.filebrowser = lib.mkIf baseConfigReady {
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

    systemd.tmpfiles.rules = lib.mkIf baseConfigReady (
      [
        "d /var/lib/filebrowser 0750 filebrowser filebrowser - -"
        "d ${cfg.root} 0770 filebrowser filebrowser - -"
        "d ${cfg.root}/users 0770 filebrowser filebrowser - -"
      ]
      ++ (lib.mapAttrsToList (uname: u:
        "d ${cfg.root}/${u.scope} 0770 filebrowser filebrowser - -"
      ) cfg.users)
    );

    environment.systemPackages = [ pkgs.filebrowser ];

    systemd.services.filebrowser-reconcile-users = lib.mkIf (cfg.users != {} && baseConfigReady) {
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
          passfileLines =
            lib.concatStringsSep "\n"
              (lib.mapAttrsToList (uname: u:
                let
                  var = "PASSFILE_" + lib.replaceStrings [ "-" "." ] [ "_" "_" ] uname;
                  runtimePassfile = "$RUNTIME_DIRECTORY/${lib.replaceStrings [ "-" "." ] [ "_" "_" ] uname}.pass";
                in
                if u.passwordFile != null then
                  ''${var}=${lib.escapeShellArg (toString u.passwordFile)}''
                else if u.passwordSecret != null then
                  ''${var}=${lib.escapeShellArg config.sops.secrets.${u.passwordSecret}.path}''
                else
                  ''${var}=${lib.escapeShellArg runtimePassfile}; ensure_runtime_passfile "${"$"}${var}" ${lib.escapeShellArg u.password}''
              ) cfg.users);

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
          ADDRESS=${lib.escapeShellArg cfg.listenAddress}
          PORT=${lib.escapeShellArg (toString cfg.port)}
          ROOT=${lib.escapeShellArg cfg.root}

          ensure_database_initialized() {
            if [ -f "$DB" ]; then
              return 0
            fi

            echo "Initializing File Browser database: $DB"
            mkdir -p "$(dirname "$DB")"
            filebrowser config init \
              --database "$DB" \
              --address "$ADDRESS" \
              --port "$PORT" \
              --root "$ROOT"
          }

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

          ensure_database_initialized

          ${ensureLines}

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

    systemd.services.filebrowser.restartTriggers = [
      (builtins.toJSON sanitizedUsersForRestart)
    ];

  };
}
