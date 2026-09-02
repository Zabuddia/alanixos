{ config, lib, pkgs, ... }:

let
  cfg = config.alanix.openclaw.radicale;
  openclawCfg = config.alanix.openclaw;
  openclawUser =
    if openclawCfg.user != null then
      lib.attrByPath [ "alanix" "users" "accounts" openclawCfg.user ] null config
    else
      null;
  openclawHome =
    if openclawUser != null && openclawUser.home.enable then
      openclawUser.home.directory
    else
      null;
  dataDir =
    if lib.hasPrefix "/" cfg.dataDir then
      cfg.dataDir
    else if openclawHome != null then
      "${openclawHome}/${cfg.dataDir}"
    else
      cfg.dataDir;
  passwordFile = if cfg.passwordFile != null then cfg.passwordFile else "";
  radicalePython = pkgs.python3.withPackages (pythonPackages: [
    pythonPackages.icalendar
    pythonPackages.vobject
  ]);

  vdirsyncerConfig = pkgs.writeText "openclaw-vdirsyncer.conf" ''
    [general]
    status_path = "${dataDir}/status/"

    [pair radicale_calendars]
    a = "radicale_calendars_remote"
    b = "radicale_calendars_local"
    collections = ["from a", "from b"]
    metadata = ["displayname", "color"]

    [storage radicale_calendars_remote]
    type = "caldav"
    url = "${cfg.url}"
    username = "${cfg.username}"
    password.fetch = ["command", "${pkgs.coreutils}/bin/cat", "${passwordFile}"]

    [storage radicale_calendars_local]
    type = "filesystem"
    path = "${dataDir}/calendars/"
    fileext = ".ics"

    [pair radicale_contacts]
    a = "radicale_contacts_remote"
    b = "radicale_contacts_local"
    collections = ["from a", "from b"]

    [storage radicale_contacts_remote]
    type = "carddav"
    url = "${cfg.url}"
    username = "${cfg.username}"
    password.fetch = ["command", "${pkgs.coreutils}/bin/cat", "${passwordFile}"]

    [storage radicale_contacts_local]
    type = "filesystem"
    path = "${dataDir}/contacts/"
    fileext = ".vcf"
  '';

  khalConfig = pkgs.writeText "openclaw-khal.conf" ''
    [calendars]
    [[radicale]]
    path = ${dataDir}/calendars/*
    type = discover

    [locale]
    local_timezone = ${config.time.timeZone}
    default_timezone = ${config.time.timeZone}
    timeformat = %H:%M
    dateformat = %Y-%m-%d
    longdateformat = %Y-%m-%d
    datetimeformat = %Y-%m-%d %H:%M
    longdatetimeformat = %Y-%m-%d %H:%M
  '';

  khardConfig = pkgs.writeText "openclaw-khard.conf" ''
    [addressbooks]
    [[radicale]]
    path = ${dataDir}/contacts/*
    type = discover

    [general]
    default_action = list

    [contact table]
    display = formatted_name
    group_by_addressbook = yes
    show_uids = yes
    sort = formatted_name

    [vcard]
    preferred_version = 4.0
    skip_unparsable = no
  '';

  syncCommand = pkgs.writeShellScript "openclaw-radicale-sync-command" ''
    set -euo pipefail

    if [[ ! -r ${lib.escapeShellArg passwordFile} ]]; then
      echo "Radicale password file is missing or unreadable" >&2
      exit 78
    fi

    ${pkgs.coreutils}/bin/mkdir -p \
      ${lib.escapeShellArg "${dataDir}/status"} \
      ${lib.escapeShellArg "${dataDir}/calendars"} \
      ${lib.escapeShellArg "${dataDir}/contacts"}

    exec ${pkgs.util-linux}/bin/flock \
      ${lib.escapeShellArg "${dataDir}/sync.lock"} \
      ${pkgs.bash}/bin/bash -c '
        set -euo pipefail
        # Dynamic CalDAV/CardDAV discovery asks before creating a newly found
        # collection in the local filesystem storage.  Feed affirmative
        # answers so the first unattended sync can bootstrap its local vdirs.
        set +o pipefail
        ${pkgs.coreutils}/bin/yes | ${lib.getExe pkgs.vdirsyncer} -c ${lib.escapeShellArg vdirsyncerConfig} discover
        discover_status="''${PIPESTATUS[1]}"
        set -o pipefail
        [ "$discover_status" -eq 0 ]
        ${lib.getExe pkgs.vdirsyncer} -c ${lib.escapeShellArg vdirsyncerConfig} sync
      '
  '';

  radicaleSync = pkgs.writeShellApplication {
    name = "radicale-sync";
    text = ''
      exec ${syncCommand}
    '';
  };

  radicaleCalendar = pkgs.writeShellApplication {
    name = "radicale-calendar";
    text = ''
      ${syncCommand}
      set +e
      ${radicalePython}/bin/python ${./radicale-control/radicale_control.py} \
        --calendar-root ${lib.escapeShellArg "${dataDir}/calendars"} \
        --contact-root ${lib.escapeShellArg "${dataDir}/contacts"} \
        calendar "$@"
      status=$?
      set -e
      case "''${1:-}:$status" in create:0|update:0|delete:0) ${syncCommand} ;; esac
      exit "$status"
    '';
  };

  radicaleContacts = pkgs.writeShellApplication {
    name = "radicale-contacts";
    text = ''
      ${syncCommand}
      set +e
      ${radicalePython}/bin/python ${./radicale-control/radicale_control.py} \
        --calendar-root ${lib.escapeShellArg "${dataDir}/calendars"} \
        --contact-root ${lib.escapeShellArg "${dataDir}/contacts"} \
        contact "$@"
      status=$?
      set -e
      case "''${1:-}:$status" in create:0|update:0|delete:0) ${syncCommand} ;; esac
      exit "$status"
    '';
  };

  radicaleCalendarRaw = pkgs.writeShellApplication {
    name = "radicale-calendar-raw";
    text = ''
      ${syncCommand}
      exec ${lib.getExe' pkgs.khal "khal"} --config ${lib.escapeShellArg khalConfig} "$@"
    '';
  };

  radicaleContactsRaw = pkgs.writeShellApplication {
    name = "radicale-contacts-raw";
    text = ''
      ${syncCommand}
      exec ${lib.getExe pkgs.khard} --config ${lib.escapeShellArg khardConfig} "$@"
    '';
  };
in
{
  options.alanix.openclaw.radicale = {
    enable = lib.mkEnableOption "Radicale calendar and contact access for OpenClaw";

    url = lib.mkOption {
      type = lib.types.str;
      default = "https://radicale.fifefin.com/";
      description = "Radicale CalDAV and CardDAV base URL.";
    };

    username = lib.mkOption {
      type = lib.types.str;
      default = "buddia";
      description = "Radicale user synchronized into OpenClaw's local vdirs.";
    };

    passwordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Runtime-only file containing the Radicale password.";
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = ".local/state/openclaw-radicale";
      description = "Local DAV cache; relative paths are resolved inside the OpenClaw user's home.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = openclawCfg.gateway.enable;
        message = "alanix.openclaw.radicale requires alanix.openclaw.gateway.enable.";
      }
      {
        assertion = openclawHome != null;
        message = "alanix.openclaw.radicale requires an OpenClaw user with home.enable = true.";
      }
      {
        assertion = cfg.passwordFile != null;
        message = "alanix.openclaw.radicale.passwordFile must be set.";
      }
    ];

    alanix.openclaw.packages = [
      radicaleSync
      radicaleCalendar
      radicaleContacts
      radicaleCalendarRaw
      radicaleContactsRaw
    ];
  };
}
