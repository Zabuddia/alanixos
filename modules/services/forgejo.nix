{ config, lib, pkgs, ... }:
let
  cfg = config.alanix.forgejo;
  serviceExposure = import ../../lib/mkServiceExposure.nix { inherit lib pkgs; };

  exposeCfg = cfg.expose;
  hasValue = value: value != null && value != "";

  endpoint = {
    address = cfg.listenAddress;
    port = cfg.port;
    protocol = "http";
  };

  baseConfigReady = hasValue cfg.listenAddress && cfg.port != null;

  declaredUsernames = builtins.attrNames cfg.users;
  declaredUsersList = lib.concatStringsSep " " declaredUsernames;

  wireguardAddress =
    if exposeCfg.wireguard.address != null then
      exposeCfg.wireguard.address
    else
      config.alanix.wireguard.vpnIP;

  wanPort =
    if exposeCfg.wan.port != null then
      exposeCfg.wan.port
    else if exposeCfg.wan.tls then
      443
    else
      80;

  effectiveDomain =
    if hasValue cfg.domain then
      cfg.domain
    else if exposeCfg.wan.enable && hasValue exposeCfg.wan.domain then
      exposeCfg.wan.domain
    else if exposeCfg.wireguard.enable && hasValue wireguardAddress then
      wireguardAddress
    else
      cfg.listenAddress;

  effectiveRootUrl =
    if hasValue cfg.rootUrl then
      cfg.rootUrl
    else if exposeCfg.wan.enable && hasValue exposeCfg.wan.domain then
      let
        scheme = if exposeCfg.wan.tls then "https" else "http";
        defaultPort = if exposeCfg.wan.tls then 443 else 80;
        portSuffix = if wanPort == defaultPort then "" else ":${toString wanPort}";
      in
      "${scheme}://${exposeCfg.wan.domain}${portSuffix}/"
    else if exposeCfg.wireguard.enable && hasValue wireguardAddress then
      let
        scheme = if exposeCfg.wireguard.tls then "https" else "http";
      in
      "${scheme}://${wireguardAddress}:${toString exposeCfg.wireguard.port}/"
    else
      "http://${cfg.listenAddress}:${toString cfg.port}/";

  defaultSettings = {
    DEFAULT.APP_NAME = cfg.appName;
    server = {
      HTTP_ADDR = cfg.listenAddress;
      HTTP_PORT = cfg.port;
      DOMAIN = effectiveDomain;
      ROOT_URL = effectiveRootUrl;
    };
    service.DISABLE_REGISTRATION = cfg.disableRegistration;
  };

  dbPath = config.services.forgejo.database.path;

  sanitizedUsersForRestart =
    lib.mapAttrs
      (_: userCfg: {
        inherit (userCfg) admin email mustChangePassword passwordSecret;
        password =
          if userCfg.password == null then
            null
          else
            builtins.hashString "sha256" userCfg.password;
        passwordFile =
          if userCfg.passwordFile == null then
            null
          else
            toString userCfg.passwordFile;
      })
      cfg.users;
in
{
  options.alanix.forgejo = {
    enable = lib.mkEnableOption "Forgejo (Alanix)";

    appName = lib.mkOption {
      type = lib.types.str;
      default = "Alanix Forgejo";
    };

    listenAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };

    port = lib.mkOption {
      type = lib.types.nullOr lib.types.port;
      default = null;
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/forgejo";
    };

    domain = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional public domain or address advertised by Forgejo.";
    };

    rootUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional public root URL advertised by Forgejo.";
    };

    disableRegistration = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };

    pruneUndeclaredUsers = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Delete Forgejo users that are not present in alanix.forgejo.users.";
    };

    settings = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = "Extra services.forgejo.settings merged on top of the Alanix defaults.";
    };

    users = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
        options = {
          admin = lib.mkOption {
            type = lib.types.bool;
            default = false;
          };

          email = lib.mkOption {
            type = lib.types.str;
            description = "Email address for the Forgejo user.";
          };

          mustChangePassword = lib.mkOption {
            type = lib.types.bool;
            default = false;
          };

          password = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Plaintext password (simple, not recommended).";
          };

          passwordFile = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = "Path to a file containing the plaintext password.";
          };

          passwordSecret = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Name of a sops secret containing the plaintext password.";
          };
        };
      }));
      default = { };
      description = "Declarative Forgejo users.";
    };

    expose = serviceExposure.mkOptions {
      serviceName = "forgejo";
      serviceDescription = "Forgejo";
      defaultPublicPort = 80;
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions =
        [
          {
            assertion = cfg.users != { };
            message = "alanix.forgejo: users must not be empty when enable = true.";
          }
          {
            assertion = hasValue cfg.listenAddress;
            message = "alanix.forgejo.listenAddress must be set when alanix.forgejo.enable = true.";
          }
          {
            assertion = cfg.port != null;
            message = "alanix.forgejo.port must be set when alanix.forgejo.enable = true.";
          }
          {
            assertion = lib.hasPrefix "/" cfg.stateDir;
            message = "alanix.forgejo.stateDir must be an absolute path.";
          }
          {
            assertion = config.services.forgejo.database.type == "sqlite3";
            message = "alanix.forgejo declarative users currently support only Forgejo's default sqlite3 database.";
          }
        ]
        ++ serviceExposure.mkAssertions {
          inherit config endpoint exposeCfg;
          optionPrefix = "alanix.forgejo.expose";
        }
        ++ lib.flatten (lib.mapAttrsToList (uname: u:
          let
            chosen = lib.filter (x: x) [
              (u.password != null)
              (u.passwordFile != null)
              (u.passwordSecret != null)
            ];
          in
          [
            {
              assertion = builtins.match "^[A-Za-z0-9._-]+$" uname != null;
              message = "alanix.forgejo.users.${uname}: usernames may contain only letters, digits, dot, underscore, and hyphen.";
            }
            {
              assertion = hasValue u.email;
              message = "alanix.forgejo.users.${uname}.email must be set.";
            }
            {
              assertion = (builtins.length chosen) == 1;
              message = "alanix.forgejo.users.${uname}: set exactly one of password, passwordFile, or passwordSecret.";
            }
            {
              assertion = u.passwordSecret == null || lib.hasAttrByPath [ "sops" "secrets" u.passwordSecret ] config;
              message = "alanix.forgejo.users.${uname}.passwordSecret must reference a declared sops secret.";
            }
          ]
        ) cfg.users);

      services.forgejo = lib.mkIf baseConfigReady {
        enable = true;
        stateDir = cfg.stateDir;
        settings = lib.recursiveUpdate defaultSettings cfg.settings;
      };

      systemd.services.forgejo-reconcile-users = lib.mkIf (cfg.users != { } && baseConfigReady) {
        description = "Reconcile Forgejo users (create declared; optionally prune undeclared)";
        after = [ "forgejo.service" "sops-nix.service" ];
        wants = [ "forgejo.service" "sops-nix.service" ];
        partOf = [ "forgejo.service" ];
        wantedBy = [ "forgejo.service" ];

        serviceConfig = {
          Type = "oneshot";
          User = config.services.forgejo.user;
          Group = config.services.forgejo.group;
          WorkingDirectory = cfg.stateDir;
          RuntimeDirectory = "alanix-forgejo";
          RuntimeDirectoryMode = "0700";
          UMask = "0077";
        };

        environment = {
          USER = config.services.forgejo.user;
          HOME = cfg.stateDir;
          FORGEJO_WORK_DIR = cfg.stateDir;
          FORGEJO_CUSTOM = config.services.forgejo.customDir;
        };

        path = [
          config.services.forgejo.package
          pkgs.coreutils
          pkgs.gawk
          pkgs.gnugrep
          pkgs.gnused
          pkgs.sqlite
        ];

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
                    mustChangeFlag = if u.mustChangePassword then "1" else "0";
                  in
                  ''ensure_user ${lib.escapeShellArg uname} ${lib.escapeShellArg u.email} "${"$"}${var}" ${adminFlag} ${mustChangeFlag}''
                ) cfg.users);
          in
          ''
            set -euo pipefail

            DB=${lib.escapeShellArg dbPath}
            DECLARED=${lib.escapeShellArg declaredUsersList}
            PRUNE=${if cfg.pruneUndeclaredUsers then "1" else "0"}

            have_user() {
              forgejo admin user list | awk 'NR>1 {print $2}' | grep -qx -- "$1"
            }

            ensure_runtime_passfile() {
              local path="$1"
              local value="$2"
              umask 077
              printf '%s' "$value" > "$path"
            }

            sql_quote() {
              printf '%s' "$1" | awk '{ gsub(/\047/, "\047\047"); print }'
            }

            update_user_metadata() {
              local name="$1"
              local email="$2"
              local is_admin="$3"
              local must_change="$4"
              local qname
              local qemail

              qname="$(sql_quote "$name")"
              qemail="$(sql_quote "$email")"

              sqlite3 "$DB" \
                "UPDATE user SET email = '$qemail', is_admin = $is_admin, must_change_password = $must_change WHERE lower_name = lower('$qname');"
            }

            ensure_user() {
              local name="$1"
              local email="$2"
              local passfile="$3"
              local is_admin="$4"
              local must_change="$5"
              local pw
              local must_change_flag

              pw="$(tr -d '\r\n' < "$passfile")"
              must_change_flag=true
              if [ "$must_change" = "0" ]; then
                must_change_flag=false
              fi

              if have_user "$name"; then
                forgejo admin user change-password \
                  --username "$name" \
                  --password "$pw" \
                  --must-change-password="$must_change_flag"
                update_user_metadata "$name" "$email" "$is_admin" "$must_change"
                return 0
              fi

              if [ "$is_admin" = "1" ]; then
                forgejo admin user create \
                  --username "$name" \
                  --password "$pw" \
                  --email "$email" \
                  --admin \
                  --must-change-password="$must_change_flag"
              else
                forgejo admin user create \
                  --username "$name" \
                  --password "$pw" \
                  --email "$email" \
                  --must-change-password="$must_change_flag"
              fi

              update_user_metadata "$name" "$email" "$is_admin" "$must_change"
            }

            ${passfileLines}

            ${ensureLines}

            if [ "$PRUNE" = "1" ]; then
              forgejo admin user list | awk 'NR>1 {print $2}' | while read -r u; do
                [ -n "$u" ] || continue
                keep=0
                for d in $DECLARED; do
                  if [ "$u" = "$d" ]; then
                    keep=1
                    break
                  fi
                done
                if [ "$keep" -eq 0 ]; then
                  echo "Removing undeclared user: $u"
                  forgejo admin user delete --username "$u"
                fi
              done
            fi
          '';

        restartTriggers = [
          (builtins.toJSON sanitizedUsersForRestart)
        ];
      };
    }

    (lib.mkIf baseConfigReady (
      serviceExposure.mkConfig {
        inherit config endpoint exposeCfg;
        serviceName = "forgejo";
        serviceDescription = "Forgejo";
      }
    ))
  ]);
}
