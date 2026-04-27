{ config, lib, pkgs, ... }:
let
  cfg = config.alanix.navidrome;
  clusterCfg = cfg.cluster;
  serviceExposure = import ../../lib/mkServiceExposure.nix { inherit lib pkgs; };

  exposeCfg = cfg.expose;

  hasValue = value: value != null && value != "";
  sanitizeUserKey = name: lib.replaceStrings [ "-" "." "@" "+" " " ] [ "_" "_" "_" "_" "_" ] name;

  endpoint = {
    address = cfg.listenAddress;
    port = cfg.port;
    protocol = "http";
  };

  baseConfigReady =
    hasValue cfg.listenAddress
    && cfg.port != null
    && cfg.mediaFolders ? music;

  adminUsers = lib.filterAttrs (_: userCfg: userCfg.admin) cfg.users;
  adminUserNames = builtins.attrNames adminUsers;
  bootstrapAdminName = if adminUserNames == [ ] then null else builtins.head adminUserNames;
  bootstrapAdminSecret =
    if bootstrapAdminName != null
    then adminUsers.${bootstrapAdminName}.passwordSecret
    else null;

  reconcileEnabled = cfg.users != { };

  sanitizedUsersForRestart =
    lib.mapAttrs (_: userCfg: { inherit (userCfg) admin passwordSecret; }) cfg.users;

  templateEnvContent =
    if bootstrapAdminName != null && bootstrapAdminSecret != null
    then ''
      ND_DEFAULTADMINUSERNAME=${bootstrapAdminName}
      ND_DEFAULTADMINPASSWORD=${config.sops.placeholder.${bootstrapAdminSecret}}
    ''
    else "";

  adminPassfilePath =
    if bootstrapAdminSecret != null
    then config.sops.secrets.${bootstrapAdminSecret}.path
    else "";

  passfileLines =
    lib.concatStringsSep "\n"
      (lib.mapAttrsToList
        (uname: userCfg:
          let var = "PASSFILE_" + sanitizeUserKey uname;
          in ''${var}=${lib.escapeShellArg config.sops.secrets.${userCfg.passwordSecret}.path}'')
        cfg.users);

  ensureUserLines =
    lib.concatStringsSep "\n"
      (lib.mapAttrsToList
        (uname: userCfg:
          let
            var = "PASSFILE_" + sanitizeUserKey uname;
            wantAdmin = if userCfg.admin then "true" else "false";
          in
          ''ensure_user ${lib.escapeShellArg uname} "${"$"}${var}" ${wantAdmin}'')
        cfg.users);

  mediaTmpfilesRules =
    lib.unique (
      lib.flatten (
        lib.mapAttrsToList
          (_: folderCfg:
            lib.optional folderCfg.create
              "d ${folderCfg.path} ${folderCfg.mode} ${folderCfg.user} ${folderCfg.group} - -")
          cfg.mediaFolders
      )
    );
in
{
  options.alanix.navidrome = {
    enable = lib.mkEnableOption "Navidrome (Alanix)";

    listenAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Bind address for Navidrome.";
    };

    port = lib.mkOption {
      type = lib.types.nullOr lib.types.port;
      default = null;
      description = "HTTP port for Navidrome.";
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/navidrome";
      description = "Navidrome data/state directory.";
    };

    backupDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Cluster backup staging directory. Required when cluster.enable = true.";
    };

    users = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({ ... }: {
        options = {
          admin = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Whether this user has Navidrome admin privileges.";
          };

          passwordSecret = lib.mkOption {
            type = lib.types.str;
            description = "Name of a sops secret containing the user's plaintext password.";
          };
        };
      }));
      default = { };
      description = ''
        Declarative Navidrome users. Passwords are read from sops secrets and
        enforced on every service restart via the Subsonic API.
        The first declared admin user is used to bootstrap the initial admin account.
      '';
    };

    mediaFolders = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({ ... }: {
        options = {
          path = lib.mkOption {
            type = lib.types.str;
            description = "Absolute filesystem path.";
          };

          create = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Whether to create the directory via systemd-tmpfiles.";
          };

          user = lib.mkOption {
            type = lib.types.str;
            default = "root";
            description = "Owner used when create = true.";
          };

          group = lib.mkOption {
            type = lib.types.str;
            default = "root";
            description = "Group used when create = true.";
          };

          mode = lib.mkOption {
            type = lib.types.strMatching "^[0-7]{4}$";
            default = "0755";
            description = "Mode used when create = true.";
          };
        };
      }));
      default = { };
      description = "Filesystem directories made available to Navidrome. Must include a 'music' entry.";
    };

    cluster = {
      enable = lib.mkEnableOption "cluster-manage Navidrome through alanix.cluster";

      backupInterval = lib.mkOption {
        type = lib.types.str;
        default = "12h";
      };

      maxBackupAge = lib.mkOption {
        type = lib.types.str;
        default = "48h";
      };
    };

    expose = serviceExposure.mkOptions {
      serviceName = "navidrome";
      serviceDescription = "Navidrome";
      defaultPublicPort = 80;
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions =
        [
          {
            assertion = hasValue cfg.listenAddress;
            message = "alanix.navidrome.listenAddress must be set when alanix.navidrome.enable = true.";
          }
          {
            assertion = cfg.port != null;
            message = "alanix.navidrome.port must be set when alanix.navidrome.enable = true.";
          }
          {
            assertion = lib.hasPrefix "/" cfg.dataDir;
            message = "alanix.navidrome.dataDir must be an absolute path.";
          }
          {
            assertion = cfg.backupDir == null || lib.hasPrefix "/" cfg.backupDir;
            message = "alanix.navidrome.backupDir must be an absolute path when set.";
          }
          {
            assertion = !clusterCfg.enable || cfg.backupDir != null;
            message = "alanix.navidrome.cluster.enable requires alanix.navidrome.backupDir to be set.";
          }
          {
            assertion = cfg.mediaFolders ? music;
            message = "alanix.navidrome.mediaFolders must include a 'music' entry (used as MusicFolder).";
          }
          {
            assertion = !baseConfigReady || bootstrapAdminName != null;
            message = "alanix.navidrome.users must include at least one admin user.";
          }
        ]
        ++ lib.flatten (
          lib.mapAttrsToList
            (uname: userCfg: [
              {
                assertion = lib.hasAttrByPath [ "sops" "secrets" userCfg.passwordSecret ] config;
                message = "alanix.navidrome.users.${uname}.passwordSecret '${userCfg.passwordSecret}' must be declared as a sops secret.";
              }
            ])
            cfg.users
        )
        ++ serviceExposure.mkAssertions {
          inherit config endpoint exposeCfg;
          optionPrefix = "alanix.navidrome.expose";
        }
        ++ lib.flatten (
          lib.mapAttrsToList
            (folderName: folderCfg: [
              {
                assertion = lib.hasPrefix "/" folderCfg.path;
                message = "alanix.navidrome.mediaFolders.${folderName}.path must be an absolute path.";
              }
            ])
            cfg.mediaFolders
        );

      services.navidrome = lib.mkIf baseConfigReady {
        enable = true;
        settings = {
          Address = cfg.listenAddress;
          Port = cfg.port;
          DataFolder = cfg.dataDir;
          MusicFolder = cfg.mediaFolders.music.path;
          LogLevel = "info";
          EnableInsightsCollector = false;
        };
        openFirewall = false;
      };

      sops.templates."alanix-navidrome-env" = lib.mkIf (bootstrapAdminName != null) {
        content = templateEnvContent;
        owner = "navidrome";
        group = "navidrome";
        mode = "0400";
      };

      systemd.services.navidrome = lib.mkIf baseConfigReady (lib.mkMerge [
        (lib.mkIf (bootstrapAdminName != null) {
          after = [ "sops-nix.service" ];
          wants = [ "sops-nix.service" ];
          serviceConfig.EnvironmentFile = config.sops.templates."alanix-navidrome-env".path;
        })
        (lib.mkIf reconcileEnabled {
          serviceConfig.ExecStartPost =
            "+${pkgs.writeShellScript "alanix-navidrome-trigger-reconcile" ''
              ${config.systemd.package}/bin/systemctl --no-block start navidrome-reconcile-users.service >/dev/null 2>&1 || true
            ''}";
        })
      ]);

      systemd.services.navidrome-reconcile-users =
        lib.mkIf (reconcileEnabled && baseConfigReady) {
          description = "Reconcile Navidrome users";
          after = [ "navidrome.service" "sops-nix.service" ];
          wants = [ "sops-nix.service" ];

          serviceConfig = {
            Type = "oneshot";
            User = "root";
            Group = "root";
            UMask = "0077";
            SuccessExitStatus = [ "SIGTERM" ];
          };

          path = [ pkgs.coreutils pkgs.curl pkgs.jq ];

          script = ''
            set -euo pipefail

            BASE_URL=${lib.escapeShellArg "http://${cfg.listenAddress}:${toString cfg.port}"}
            ADMIN_USER=${lib.escapeShellArg (if bootstrapAdminName == null then "" else bootstrapAdminName)}
            ADMIN_PASSFILE=${lib.escapeShellArg adminPassfilePath}

            ${passfileLines}

            hex_encode() {
              printf '%s' "$1" | od -An -tx1 | tr -d ' \n'
            }

            subsonic_get() {
              local endpoint="$1"; shift
              local pass hex
              pass="$(tr -d '\r\n' < "$ADMIN_PASSFILE")"
              hex="$(hex_encode "$pass")"
              curl -sf --get "$BASE_URL/rest/$endpoint.view" \
                -d "u=$ADMIN_USER" \
                -d "p=enc:$hex" \
                -d "v=1.16.1" -d "c=alanix-reconcile" -d "f=json" "$@"
            }

            check_ok() {
              [ "$(printf '%s' "$1" | jq -r '."subsonic-response".status')" = "ok" ]
            }

            wait_for_server() {
              local attempts=120 response
              while [ "$attempts" -gt 0 ]; do
                response="$(subsonic_get ping 2>/dev/null || true)"
                if check_ok "$response" 2>/dev/null; then return 0; fi
                sleep 1
                attempts=$((attempts - 1))
              done
              echo "Timed out waiting for Navidrome to become ready." >&2
              return 1
            }

            ensure_user() {
              local username="$1"
              local passfile="$2"
              local want_admin="$3"
              local pass hex users_response user_exists

              pass="$(tr -d '\r\n' < "$passfile")"
              hex="$(hex_encode "$pass")"

              users_response="$(subsonic_get getUsers)"
              user_exists="$(
                printf '%s' "$users_response" | jq -r --arg u "$username" '
                  ."subsonic-response".users.user // [] |
                  if type == "array" then . else [.] end |
                  any(.username == $u)
                '
              )"

              if [ "$user_exists" = "false" ]; then
                echo "Creating Navidrome user: $username"
                subsonic_get createUser \
                  --data-urlencode "username=$username" \
                  -d "password=enc:$hex" \
                  -d "adminRole=$want_admin" \
                  -d "email=" >/dev/null
              else
                echo "Reconciling Navidrome user: $username"
                subsonic_get changePassword \
                  --data-urlencode "username=$username" \
                  -d "password=enc:$hex" >/dev/null
                subsonic_get updateUser \
                  --data-urlencode "username=$username" \
                  -d "adminRole=$want_admin" >/dev/null
              fi
            }

            wait_for_server

            response="$(subsonic_get ping 2>/dev/null || true)"
            if ! check_ok "$response" 2>/dev/null; then
              echo "Warning: Cannot authenticate to Navidrome as $ADMIN_USER." >&2
              echo "If the password diverged from the declared value, remove ${cfg.dataDir} to reset." >&2
              exit 0
            fi

            ${ensureUserLines}

            echo "Navidrome user reconciliation complete."
          '';

          restartTriggers = [ (builtins.toJSON sanitizedUsersForRestart) ];
        };

      systemd.tmpfiles.rules = lib.mkIf baseConfigReady mediaTmpfilesRules;
    }

    (lib.mkIf (baseConfigReady && !clusterCfg.enable) (
      serviceExposure.mkConfig {
        inherit config endpoint exposeCfg;
        serviceName = "navidrome";
        serviceDescription = "Navidrome";
      }
    ))
  ]);
}
