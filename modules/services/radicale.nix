{ config, lib, pkgs, ... }:
let
  cfg = config.alanix.radicale;
  clusterCfg = cfg.cluster;
  serviceExposure = import ../../lib/mkServiceExposure.nix { inherit lib pkgs; };

  exposeCfg = cfg.expose;

  hasValue = value: value != null && value != "";

  endpoint = {
    address = cfg.listenAddress;
    port = cfg.port;
    protocol = "http";
  };

  baseConfigReady =
    hasValue cfg.listenAddress
    && cfg.port != null
    && hasValue cfg.storageDir;

  declaredCalendars =
    lib.flatten (
      lib.mapAttrsToList
        (owner: calendars:
          lib.mapAttrsToList
            (name: calendarCfg: {
              inherit owner name;
              displayName = calendarCfg.displayName;
              description = calendarCfg.description;
              color =
                if calendarCfg.color == null then
                  null
                else
                  "${calendarCfg.color}ff";
              components = calendarCfg.components;
            })
            calendars
        )
        cfg.calendars
    );

  declaredCalendarsJson = pkgs.writeText "alanix-radicale-calendars.json" (builtins.toJSON declaredCalendars);

  htpasswdContent =
    lib.concatStringsSep "\n" (
      lib.mapAttrsToList
        (username: userCfg: "${username}:${config.sops.placeholder.${userCfg.passwordSecret}}")
        cfg.users
    )
    + "\n";

  defaultRights = {
    root = {
      user = ".+";
      collection = "";
      permissions = "R";
    };

    principal = {
      user = ".+";
      collection = "{user}";
      permissions = "RW";
    };

    calendars = {
      user = ".+";
      collection = "{user}/[^/]+";
      permissions = "rw";
    };
  };

  defaultSettings = {
    server.hosts = [ "${cfg.listenAddress}:${toString cfg.port}" ];

    auth = {
      type = "htpasswd";
      htpasswd_filename = config.sops.templates."alanix-radicale-users".path;
      htpasswd_encryption = "plain";
    };

    storage.filesystem_folder = cfg.storageDir;
  };
in
{
  options.alanix.radicale = {
    enable = lib.mkEnableOption "Radicale (Alanix)";

    listenAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };

    port = lib.mkOption {
      type = lib.types.nullOr lib.types.port;
      default = null;
    };

    storageDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "/var/lib/radicale/collections";
      description = "Directory where Radicale stores calendars and address books.";
    };

    backupDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional Radicale cluster backup staging directory.";
    };

    cluster = {
      enable = lib.mkEnableOption "cluster-manage Radicale through alanix.cluster";

      backupInterval = lib.mkOption {
        type = lib.types.str;
        default = "15m";
      };

      maxBackupAge = lib.mkOption {
        type = lib.types.str;
        default = "1h";
      };
    };

    users = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
        options.passwordSecret = lib.mkOption {
          type = lib.types.str;
          description = "SOPS secret containing the plaintext password for Radicale user ${name}.";
        };
      }));
      default = { };
      description = "Declarative Radicale users written to the htpasswd authentication file.";
    };

    calendars = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
        options = {
          displayName = lib.mkOption {
            type = lib.types.str;
            default = name;
            description = "Human-readable display name for this calendar.";
          };

          description = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Optional CalDAV calendar description.";
          };

          color = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Optional calendar color as #RRGGBB.";
          };

          components = lib.mkOption {
            type = lib.types.listOf (lib.types.enum [ "VEVENT" "VTODO" "VJOURNAL" ]);
            default = [ "VEVENT" ];
            description = "CalDAV component types this calendar should advertise.";
          };
        };
      })));
      default = { };
      description = ''
        Declarative Radicale calendars keyed by owner and collection name.
        Reconciliation creates missing collections and updates collection metadata,
        but never deletes calendars or event files.
      '';
      example = {
        buddia.personal = {
          displayName = "Personal";
          description = "Personal calendar";
          color = "#3b82f6";
        };
      };
    };

    rights = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = "Extra services.radicale.rights merged over the Alanix owner-only defaults.";
    };

    settings = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = "Extra services.radicale.settings merged over the Alanix defaults.";
    };

    expose = serviceExposure.mkOptions {
      serviceName = "radicale";
      serviceDescription = "Radicale";
      defaultPublicPort = 80;
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions =
        [
          {
            assertion = cfg.users != { };
            message = "alanix.radicale: users must not be empty when enable = true.";
          }
          {
            assertion = hasValue cfg.listenAddress;
            message = "alanix.radicale.listenAddress must be set when alanix.radicale.enable = true.";
          }
          {
            assertion = cfg.port != null;
            message = "alanix.radicale.port must be set when alanix.radicale.enable = true.";
          }
          {
            assertion = cfg.storageDir == null || lib.hasPrefix "/" cfg.storageDir;
            message = "alanix.radicale.storageDir must be an absolute path.";
          }
          {
            assertion = cfg.backupDir == null || lib.hasPrefix "/" cfg.backupDir;
            message = "alanix.radicale.backupDir must be an absolute path when set.";
          }
          {
            assertion = !clusterCfg.enable || cfg.backupDir != null;
            message = "alanix.radicale.cluster.enable requires alanix.radicale.backupDir to be set.";
          }
        ]
        ++ (lib.mapAttrsToList (username: userCfg: {
          assertion = builtins.match "^[A-Za-z0-9._-]+$" username != null;
          message = "alanix.radicale.users.${username}: usernames may contain only letters, digits, dot, underscore, and hyphen.";
        }) cfg.users)
        ++ (lib.mapAttrsToList (username: userCfg: {
          assertion = lib.hasAttrByPath [ "sops" "secrets" userCfg.passwordSecret ] config;
          message = "alanix.radicale.users.${username}.passwordSecret must reference a declared sops secret.";
        }) cfg.users)
        ++ (lib.mapAttrsToList (owner: calendars: {
          assertion = lib.hasAttr owner cfg.users;
          message = "alanix.radicale.calendars.${owner}: calendar owners must be declared in alanix.radicale.users.";
        }) cfg.calendars)
        ++ (lib.flatten (
          lib.mapAttrsToList
            (owner: calendars:
              lib.mapAttrsToList
                (calendarName: calendarCfg: {
                  assertion = builtins.match "^[A-Za-z0-9._-]+$" calendarName != null;
                  message = "alanix.radicale.calendars.${owner}.${calendarName}: calendar names may contain only letters, digits, dot, underscore, and hyphen.";
                })
                calendars
            )
            cfg.calendars
        ))
        ++ (lib.flatten (
          lib.mapAttrsToList
            (owner: calendars:
              lib.mapAttrsToList
                (calendarName: calendarCfg: {
                  assertion = calendarCfg.color == null || builtins.match "^#[0-9A-Fa-f]{6}$" calendarCfg.color != null;
                  message = "alanix.radicale.calendars.${owner}.${calendarName}.color must be null or #RRGGBB.";
                })
                calendars
            )
            cfg.calendars
        ))
        ++ serviceExposure.mkAssertions {
          inherit config endpoint exposeCfg;
          optionPrefix = "alanix.radicale.expose";
        };

      sops.templates."alanix-radicale-users" = {
        content = htpasswdContent;
        owner = "radicale";
        group = "radicale";
        mode = "0400";
      };

      services.radicale = lib.mkIf baseConfigReady {
        enable = true;
        settings = lib.recursiveUpdate defaultSettings cfg.settings;
        rights = lib.recursiveUpdate defaultRights cfg.rights;
      };

      systemd.services.radicale = {
        after = [ "sops-nix.service" ];
        wants = [ "sops-nix.service" ];
      };

      systemd.services.radicale-reconcile-calendars = lib.mkIf (cfg.calendars != { } && baseConfigReady) {
        description = "Reconcile Radicale calendars";
        before = [ "radicale.service" ];
        requiredBy = [ "radicale.service" ];

        after = [ "systemd-tmpfiles-setup.service" ];
        wants = [ "systemd-tmpfiles-setup.service" ];

        serviceConfig = {
          Type = "oneshot";
          User = "radicale";
          Group = "radicale";
        };

        path = [ pkgs.coreutils ];

        script = ''
          set -euo pipefail

          STORAGE_DIR=${lib.escapeShellArg cfg.storageDir}
          DECLARED_CALENDARS=${lib.escapeShellArg declaredCalendarsJson}

          ${pkgs.python3}/bin/python3 - "$STORAGE_DIR" "$DECLARED_CALENDARS" <<'PY'
          import json
          import os
          import sys

          storage_dir, declared_path = sys.argv[1], sys.argv[2]

          with open(declared_path, encoding="utf-8") as handle:
              declared_calendars = json.load(handle)

          def write_json_atomic(path, value):
              tmp_path = f"{path}.tmp"
              with open(tmp_path, "w", encoding="utf-8") as handle:
                  json.dump(value, handle, sort_keys=True)
              os.replace(tmp_path, path)

          for calendar in declared_calendars:
              owner = calendar["owner"]
              name = calendar["name"]
              owner_dir = os.path.join(storage_dir, owner)
              calendar_dir = os.path.join(owner_dir, name)
              props_path = os.path.join(calendar_dir, ".Radicale.props")

              os.makedirs(calendar_dir, mode=0o750, exist_ok=True)
              os.chmod(owner_dir, 0o750)
              os.chmod(calendar_dir, 0o750)

              props = {}
              try:
                  with open(props_path, encoding="utf-8") as handle:
                      loaded = json.load(handle)
                  if isinstance(loaded, dict):
                      props.update(loaded)
              except FileNotFoundError:
                  pass

              props["tag"] = "VCALENDAR"
              props["D:displayname"] = calendar["displayName"]
              props["C:supported-calendar-component-set"] = ",".join(calendar["components"])

              if calendar["description"] is not None:
                  props["C:calendar-description"] = calendar["description"]
              if calendar["color"] is not None:
                  props["ICAL:calendar-color"] = calendar["color"]

              write_json_atomic(props_path, props)
              os.chmod(props_path, 0o640)
              print(f"ensured Radicale calendar {owner}/{name}")
          PY
        '';
      };

      systemd.tmpfiles.rules = lib.mkIf baseConfigReady [
        "d ${cfg.storageDir} 0750 radicale radicale - -"
      ];
    }

    (lib.mkIf (baseConfigReady && !clusterCfg.enable) (
      serviceExposure.mkConfig {
        inherit config endpoint exposeCfg;
        serviceName = "radicale";
        serviceDescription = "Radicale";
      }
    ))
  ]);
}
