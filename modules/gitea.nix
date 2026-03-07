{ config, lib, pkgs, ... }:
let
  cfg = config.alanix.gitea;
  hasSopsSecrets = lib.hasAttrByPath [ "sops" "secrets" ] config;
  torSecretKeyPath =
    if cfg.torAccess.secretKeySecret == null then
      null
    else
      config.sops.secrets.${cfg.torAccess.secretKeySecret}.path;
  declaredUsernames = builtins.attrNames cfg.users;
  declaredUsersList = lib.concatStringsSep " " declaredUsernames;
  anySopsPassword = lib.any (u: u.passwordSecret != null) (lib.attrValues cfg.users);
in
{
  options.alanix.gitea = {
    enable = lib.mkEnableOption "Gitea (Alanix)";

    active = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether this node actively runs the Gitea service.";
    };

    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 3000;
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open the direct Gitea backend port in the firewall.";
    };

    firewallInterfaces = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = ''
        Optional interface allowlist for the direct Gitea backend port.
        Empty means open globally via networking.firewall.allowedTCPPorts.
      '';
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/gitea";
      description = "State directory containing repositories and sqlite database.";
    };

    uid = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.positive;
      default = null;
      description = "Pinned UID for the gitea system user. Set with gid for multi-node consistency.";
    };

    gid = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.positive;
      default = null;
      description = "Pinned GID for the gitea system group. Set with uid for multi-node consistency.";
    };

    wanAccess = {
      enable = lib.mkEnableOption "WAN/public access path for Gitea via Caddy";

      domain = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Public DNS name served by Caddy for Gitea (for example git.example.com).";
      };

      openFirewall = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Open TCP 80/443 for Caddy when WAN access is enabled.";
      };
    };

    wireguardAccess = {
      enable = lib.mkEnableOption "WireGuard-only access path for Gitea";

      listenAddress = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "WireGuard-side address to bind for internal access (for example 10.100.0.2).";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 8090;
        description = "WireGuard-only Caddy listener port.";
      };

      interface = lib.mkOption {
        type = lib.types.str;
        default = "wg0";
        description = "Firewall interface for WireGuard-only access.";
      };
    };

    torAccess = {
      enable = lib.mkEnableOption "Tor onion-service access path for Gitea";

      serviceName = lib.mkOption {
        type = lib.types.str;
        default = "gitea";
        description = "Tor onion service name key under services.tor.relay.onionServices.";
      };

      localPort = lib.mkOption {
        type = lib.types.port;
        default = 13000;
        description = "Local Caddy listener used as Tor hidden-service backend.";
      };

      virtualPort = lib.mkOption {
        type = lib.types.port;
        default = 80;
        description = "Virtual onion service port exposed to Tor clients.";
      };

      version = lib.mkOption {
        type = lib.types.enum [ 2 3 ];
        default = 3;
        description = "Tor hidden-service version.";
      };

      secretKeySecret = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional sops secret containing a Tor hidden-service secret key for stable onion address.";
      };
    };

    settings = lib.mkOption {
      type = lib.types.attrs;
      default = {};
      description = "Additional Gitea app.ini settings merged over sane defaults.";
    };

    allowRegistration = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Allow new user self-registration. Disable later once an admin account exists.";
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
            default = "${name}@local.invalid";
          };

          fullName = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
          };

          userType = lib.mkOption {
            type = lib.types.enum [ "individual" "bot" ];
            default = "individual";
          };

          restricted = lib.mkOption {
            type = lib.types.bool;
            default = false;
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
            description = "Path to file containing plaintext password.";
          };

          passwordSecret = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Name of sops secret containing plaintext password.";
          };
        };
      }));
      default = {};
      description = "Declarative Gitea users.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions =
      (lib.flatten (lib.mapAttrsToList (uname: u:
        let
          chosen = lib.filter (x: x) [
            (u.password != null)
            (u.passwordFile != null)
            (u.passwordSecret != null)
          ];
        in [
          {
            assertion = (builtins.length chosen) == 1;
            message = "alanix.gitea.users.${uname}: set exactly one of password, passwordFile, or passwordSecret.";
          }
          {
            assertion = lib.match "^[A-Za-z0-9][A-Za-z0-9._-]{0,38}$" uname != null;
            message = "alanix.gitea.users.${uname}: username must match ^[A-Za-z0-9][A-Za-z0-9._-]{0,38}$.";
          }
        ]
      ) cfg.users))
      ++ [
        {
          assertion = !(cfg.wanAccess.enable && cfg.wanAccess.domain == null);
          message = "alanix.gitea.wanAccess.domain must be set when wanAccess is enabled.";
        }
        {
          assertion = !(cfg.wireguardAccess.enable && cfg.wireguardAccess.listenAddress == null);
          message = "alanix.gitea.wireguardAccess.listenAddress must be set when wireguardAccess is enabled.";
        }
        {
          assertion = !(cfg.torAccess.enable && cfg.torAccess.secretKeySecret != null && !hasSopsSecrets);
          message = "alanix.gitea.torAccess.secretKeySecret requires sops-nix configuration.";
        }
        {
          assertion = (cfg.uid == null) == (cfg.gid == null);
          message = "alanix.gitea.uid and alanix.gitea.gid must either both be set or both be null.";
        }
        {
          assertion = !(anySopsPassword && !hasSopsSecrets);
          message = "alanix.gitea.users.*.passwordSecret requires sops-nix configuration.";
        }
      ];

    networking.firewall = lib.mkMerge [
      (lib.mkIf (cfg.active && cfg.openFirewall && cfg.firewallInterfaces == []) {
        allowedTCPPorts = [ cfg.port ];
      })
      (lib.mkIf (cfg.active && cfg.openFirewall && cfg.firewallInterfaces != []) {
        interfaces =
          lib.genAttrs cfg.firewallInterfaces (_: { allowedTCPPorts = [ cfg.port ]; });
      })
      (lib.mkIf (cfg.wanAccess.enable && cfg.wanAccess.openFirewall) {
        allowedTCPPorts = [ 80 443 ];
      })
      (lib.mkIf cfg.wireguardAccess.enable {
        interfaces =
          lib.genAttrs [ cfg.wireguardAccess.interface ] (_: { allowedTCPPorts = [ cfg.wireguardAccess.port ]; });
      })
    ];

    services.gitea = {
      enable = true;
      user = "gitea";
      group = "gitea";
      stateDir = cfg.stateDir;
      database.type = "sqlite3";
      settings = lib.recursiveUpdate {
        service.DISABLE_REGISTRATION = !cfg.allowRegistration;
        security.INSTALL_LOCK = true;
        server = {
          HTTP_ADDR = cfg.listenAddress;
          HTTP_PORT = cfg.port;
          PROTOCOL = "http";
          START_SSH_SERVER = false;
          DISABLE_SSH = true;
        }
        // lib.optionalAttrs (cfg.wanAccess.enable && cfg.wanAccess.domain != null) {
          DOMAIN = cfg.wanAccess.domain;
          ROOT_URL = "https://${cfg.wanAccess.domain}/";
        };
      } cfg.settings;
    };

    systemd.services.gitea.wantedBy = lib.mkIf (!cfg.active) (lib.mkForce []);
    systemd.services.gitea.restartTriggers = [
      (builtins.toJSON cfg.users)
    ];

    users.groups.gitea = lib.mkMerge [
      {}
      (lib.mkIf (cfg.gid != null) { gid = cfg.gid; })
    ];
    users.users.gitea = {
      isSystemUser = true;
      group = "gitea";
      home = cfg.stateDir;
      createHome = true;
    } // lib.optionalAttrs (cfg.uid != null) {
      uid = cfg.uid;
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0750 gitea gitea - -"
    ];

    systemd.services.gitea-reconcile-users = lib.mkIf (cfg.users != {}) {
      description = "Reconcile Gitea users (create/update declared users)";
      wantedBy = [ "gitea.service" ];
      after = [ "gitea.service" ] ++ lib.optional anySopsPassword "sops-install-secrets.service";
      wants = lib.optional anySopsPassword "sops-install-secrets.service";
      partOf = [ "gitea.service" ];

      serviceConfig = {
        Type = "oneshot";
        User = "root";
        Group = "root";
      };

      path = [ pkgs.gitea pkgs.coreutils pkgs.gnugrep pkgs.gawk pkgs.util-linux pkgs.sqlite ];

      script =
        let
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
                  let
                    pwFile = "/run/gitea-reconcile-users/" + uname + ".pw";
                  in
                  ''${var}=${lib.escapeShellArg pwFile}''
              ) cfg.users);

          plainWriteLines =
            lib.concatStringsSep "\n"
              (lib.mapAttrsToList (uname: u:
                if u.password == null then
                  ""
                else
                  let
                    pwFile = "/run/gitea-reconcile-users/" + uname + ".pw";
                  in
                  ''
                    cat > ${lib.escapeShellArg pwFile} <<'EOF'
                    ${u.password}
                    EOF
                    chmod 0600 ${lib.escapeShellArg pwFile}
                  ''
              ) cfg.users);

          ensureLines =
            lib.concatStringsSep "\n"
              (lib.mapAttrsToList (uname: u:
                let
                  var = "PASSFILE_" + lib.replaceStrings [ "-" "." ] [ "_" "_" ] uname;
                  fullNameArg = if u.fullName == null then "''" else lib.escapeShellArg u.fullName;
                in
                ''
                  ensure_user \
                    ${lib.escapeShellArg uname} \
                    ${lib.escapeShellArg u.email} \
                    ${fullNameArg} \
                    ${lib.boolToString u.admin} \
                    "$${var}" \
                    ${lib.escapeShellArg u.userType} \
                    ${lib.boolToString u.restricted} \
                    ${lib.boolToString u.mustChangePassword}
                ''
              ) cfg.users);
        in
        ''
          set -euo pipefail

          APP_INI=${lib.escapeShellArg "${cfg.stateDir}/custom/conf/app.ini"}
          DB_PATH_DEFAULT=${lib.escapeShellArg "${cfg.stateDir}/data/gitea.db"}
          GITEA_HOME=${lib.escapeShellArg cfg.stateDir}
          GITEA_CUSTOM=${lib.escapeShellArg "${cfg.stateDir}/custom"}
          DECLARED=${lib.escapeShellArg declaredUsersList}

          mkdir -p /run/gitea-reconcile-users

          ${passfileLines}
          ${plainWriteLines}

          if [ -r "$APP_INI" ]; then
            DB_PATH="$(awk -F= '/^PATH[[:space:]]*=/ { gsub(/[[:space:]]/, "", $2); print $2; exit }' "$APP_INI")"
          else
            DB_PATH=""
          fi
          if [ -z "$DB_PATH" ]; then
            DB_PATH="$DB_PATH_DEFAULT"
          fi

          run_as_gitea() {
            env HOME="$GITEA_HOME" GITEA_WORK_DIR="$GITEA_HOME" GITEA_CUSTOM="$GITEA_CUSTOM" \
              runuser -u gitea -- gitea "$@"
          }

          sql_quote() {
            printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\"'\"'/g")"
          }

          user_type_code() {
            case "$1" in
              individual) echo 0 ;;
              bot) echo 4 ;;
              *)
                echo "Unsupported user type: $1" >&2
                return 1
                ;;
            esac
          }

          user_exists() {
            local name="$1"
            local name_q
            name_q="$(sql_quote "$name")"
            sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM user WHERE lower_name = lower($name_q);" | grep -qx '[1-9][0-9]*'
          }

          ensure_user() {
            local name="$1"
            local email="$2"
            local fullname="$3"
            local admin="$4"
            local passfile="$5"
            local usertype="$6"
            local restricted="$7"
            local must_change="$8"

            [ -r "$passfile" ] || { echo "Missing password file for $name: $passfile" >&2; exit 1; }
            local pw
            pw="$(tr -d '\n' < "$passfile")"
            [ -n "$pw" ] || { echo "Empty password for $name (from $passfile)" >&2; exit 1; }

            if user_exists "$name"; then
              run_as_gitea admin user change-password \
                --username "$name" \
                --password "$pw" \
                --must-change-password="$must_change"
            else
              args=(admin user create
                --username "$name"
                --email "$email"
                --password "$pw"
                --user-type "$usertype"
                --must-change-password="$must_change"
              )
              [ "$admin" = "true" ] && args+=(--admin)
              [ "$restricted" = "true" ] && args+=(--restricted)
              [ -n "$fullname" ] && args+=(--fullname "$fullname")
              run_as_gitea "''${args[@]}"
            fi

            # Enforce declared profile/admin/type/restriction declaratively for sqlite backend.
            local name_q email_q fullname_q type_code admin_i restricted_i
            name_q="$(sql_quote "$name")"
            email_q="$(sql_quote "$email")"
            fullname_q="$(sql_quote "$fullname")"
            type_code="$(user_type_code "$usertype")"

            if [ "$admin" = "true" ]; then admin_i=1; else admin_i=0; fi
            if [ "$restricted" = "true" ]; then restricted_i=1; else restricted_i=0; fi

            sqlite3 "$DB_PATH" "
              UPDATE user
              SET
                email = $email_q,
                full_name = $fullname_q,
                is_admin = $admin_i,
                is_restricted = $restricted_i,
                type = $type_code
              WHERE lower_name = lower($name_q);
            "
          }

          ${ensureLines}
        '';
    };

    services.caddy = lib.mkIf (cfg.wanAccess.enable || cfg.wireguardAccess.enable || cfg.torAccess.enable) {
      enable = true;
      virtualHosts = lib.mkMerge [
        (lib.mkIf cfg.wanAccess.enable {
          "${cfg.wanAccess.domain}".extraConfig = ''
            encode zstd gzip
            reverse_proxy 127.0.0.1:${toString cfg.port}
          '';
        })
        (lib.mkIf cfg.wireguardAccess.enable {
          "http://${cfg.wireguardAccess.listenAddress}:${toString cfg.wireguardAccess.port}".extraConfig = ''
            encode zstd gzip
            reverse_proxy 127.0.0.1:${toString cfg.port}
          '';
        })
        (lib.mkIf cfg.torAccess.enable {
          ":${toString cfg.torAccess.localPort}".extraConfig = ''
            bind 127.0.0.1
            encode zstd gzip
            reverse_proxy 127.0.0.1:${toString cfg.port}
          '';
        })
      ];
    };

    services.tor = lib.mkIf cfg.torAccess.enable {
      enable = true;
      relay.onionServices.${cfg.torAccess.serviceName} =
        {
          version = cfg.torAccess.version;
          map = [
            {
              port = cfg.torAccess.virtualPort;
              target = {
                addr = "127.0.0.1";
                port = cfg.torAccess.localPort;
              };
            }
          ];
        }
        // lib.optionalAttrs (torSecretKeyPath != null) {
          secretKey = torSecretKeyPath;
        };
    };
  };
}
