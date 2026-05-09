{ config, lib, pkgs, ... }:
let
  cfg = config.alanix.openwebrx;
  serviceExposure = import ../../lib/mkServiceExposure.nix { inherit lib pkgs; };

  endpoint = {
    address = cfg.listenAddress;
    port = cfg.port;
    protocol = "http";
  };

  hasValue = value: value != null && value != "";
  sanitizeUserKey = name: lib.replaceStrings [ "-" "." "@" "+" " " ] [ "_" "_" "_" "_" "_" ] name;

  dataDir = "/var/lib/openwebrx";

  rtlSdrSettings =
    {
      name = cfg.rtlSdr.name;
      type = "rtl_sdr";
      profiles =
        lib.mapAttrs
          (_: profileCfg:
            {
              name = profileCfg.name;
              center_freq = profileCfg.centerFreq;
              rf_gain = profileCfg.rfGain;
              samp_rate = profileCfg.sampleRate;
              start_freq = profileCfg.startFreq;
              start_mod = profileCfg.startMod;
            }
            // lib.optionalAttrs (profileCfg.biasTee != null) { bias_tee = profileCfg.biasTee; }
            // lib.optionalAttrs (profileCfg.directSampling != null) {
              direct_sampling = profileCfg.directSampling;
            })
          cfg.rtlSdr.profiles;
    }
    // lib.optionalAttrs (cfg.rtlSdr.device != null) { device = cfg.rtlSdr.device; }
    // lib.optionalAttrs (cfg.rtlSdr.biasTee != null) { bias_tee = cfg.rtlSdr.biasTee; }
    // lib.optionalAttrs (cfg.rtlSdr.directSampling != null) {
      direct_sampling = cfg.rtlSdr.directSampling;
    };

  baseSettings =
    {
      version = 7;
      receiver_name = cfg.receiverName;
      receiver_location = cfg.receiverLocation;
      receiver_admin = cfg.receiverAdmin;
      receiver_asl = cfg.receiverAsl;
      sdrs = {
        rtlsdr = rtlSdrSettings;
      };
    }
    // lib.optionalAttrs (cfg.receiverGps != null) {
      receiver_gps = {
        lat = cfg.receiverGps.lat;
        lon = cfg.receiverGps.lon;
      };
    };

  effectiveSettings = lib.recursiveUpdate baseSettings cfg.extraSettings;

  openwebrxSettingsJson = pkgs.writeText "alanix-openwebrx-settings.json" (builtins.toJSON effectiveSettings);

  openwebrxConfFile = pkgs.writeText "alanix-openwebrx.conf" ''
    [core]
    data_directory = ${dataDir}
    temporary_directory = ${cfg.temporaryDirectory}

    [web]
    port = ${toString cfg.port}
  '';

  openwebrxConfigFile = pkgs.writeText "alanix-config_webrx.py" ''
    import json

    with open(${builtins.toJSON openwebrxSettingsJson}, "r", encoding="utf-8") as settings_file:
        globals().update(json.load(settings_file))
  '';

  passfileLines =
    lib.concatStringsSep "\n"
      (lib.mapAttrsToList
        (uname: userCfg:
          let
            var = "PASSFILE_" + sanitizeUserKey uname;
          in
          ''${var}=${lib.escapeShellArg config.sops.secrets.${userCfg.passwordSecret}.path}'')
        cfg.users);

  usersForRestart = lib.mapAttrs (_: userCfg: { inherit (userCfg) passwordSecret; }) cfg.users;
in
{
  options.alanix.openwebrx = {
    enable = lib.mkEnableOption "OpenWebRX (Alanix)";

    package = lib.mkPackageOption pkgs "openwebrx" { };

    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = ''
        Address used by Alanix exposure backends to reach OpenWebRX locally.
        Upstream OpenWebRX itself binds 0.0.0.0 internally, so this value is
        primarily for reverse proxies and generated links.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8073;
      description = "HTTP port used by OpenWebRX.";
    };

    temporaryDirectory = lib.mkOption {
      type = lib.types.str;
      default = "/tmp";
      description = "Writable temporary directory advertised to OpenWebRX.";
    };

    extraGroups = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "video" ];
      description = "Extra groups granted to the OpenWebRX service user for SDR device access.";
    };

    receiverName = lib.mkOption {
      type = lib.types.str;
      default = "${config.networking.hostName} OpenWebRX";
      description = "Receiver name shown in the OpenWebRX UI.";
    };

    receiverLocation = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      description = "Human-friendly receiver location shown in the UI.";
    };

    receiverAdmin = lib.mkOption {
      type = lib.types.str;
      default = "admin@localhost";
      description = "Contact string shown as the receiver admin in the UI.";
    };

    receiverAsl = lib.mkOption {
      type = lib.types.int;
      default = 0;
      description = "Receiver altitude above sea level, in meters.";
    };

    receiverGps = lib.mkOption {
      type = lib.types.nullOr (lib.types.submodule {
        options = {
          lat = lib.mkOption {
            type = lib.types.float;
          };
          lon = lib.mkOption {
            type = lib.types.float;
          };
        };
      });
      default = null;
      description = "Optional receiver GPS coordinates.";
    };

    users = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({ ... }: {
        options = {
          passwordSecret = lib.mkOption {
            type = lib.types.str;
            description = "Name of a sops secret containing the user's plaintext password.";
          };
        };
      }));
      default = { };
      description = ''
        OpenWebRX login users to bootstrap or reconcile at service start. Users
        removed from this set are not deleted automatically.
      '';
    };

    rtlSdr = {
      name = lib.mkOption {
        type = lib.types.str;
        default = "RTL-SDR Blog";
        description = "Display name for the default RTL-SDR source.";
      };

      device = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional RTL-SDR device serial or index.";
      };

      biasTee = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
        description = "Whether to enable the RTL-SDR bias tee at the device level.";
      };

      directSampling = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional direct sampling mode passed through to OpenWebRX.";
      };

      profiles = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
          options = {
            name = lib.mkOption {
              type = lib.types.str;
              default = name;
              description = "Display name for this profile.";
            };

            centerFreq = lib.mkOption {
              type = lib.types.int;
              description = "Center frequency in Hz.";
            };

            sampleRate = lib.mkOption {
              type = lib.types.int;
              description = "Sample rate in samples per second.";
            };

            startFreq = lib.mkOption {
              type = lib.types.int;
              description = "Initial tuned frequency in Hz.";
            };

            startMod = lib.mkOption {
              type = lib.types.str;
              description = "Initial modulation mode (for example: wfm, nfm, am, usb, lsb).";
            };

            rfGain = lib.mkOption {
              type = lib.types.oneOf [ lib.types.int lib.types.float lib.types.str ];
              default = 29;
              description = "RF gain passed to the SDR connector.";
            };

            biasTee = lib.mkOption {
              type = lib.types.nullOr lib.types.bool;
              default = null;
              description = "Optional bias tee override for this profile.";
            };

            directSampling = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Optional direct sampling override for this profile.";
            };
          };
        }));
        default = { };
        description = ''
          RTL-SDR profiles made available in OpenWebRX. Define these per-host so
          each receiver can expose profiles that match its SDR hardware,
          antenna, and local bands of interest.
        '';
      };
    };

    extraSettings = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "Additional OpenWebRX settings merged into config_webrx.py.";
    };

    expose = serviceExposure.mkOptions {
      serviceName = "openwebrx";
      serviceDescription = "OpenWebRX";
      defaultPublicPort = 80;
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions =
        [
          {
            assertion = hasValue cfg.listenAddress;
            message = "alanix.openwebrx.listenAddress must be set when alanix.openwebrx.enable = true.";
          }
          {
            assertion = lib.hasPrefix "/" cfg.temporaryDirectory;
            message = "alanix.openwebrx.temporaryDirectory must be an absolute path.";
          }
          {
            assertion = cfg.rtlSdr.profiles != { };
            message = "alanix.openwebrx.rtlSdr.profiles must include at least one host-defined profile.";
          }
          {
            assertion = !(cfg.expose.tailscale.enable && cfg.expose.tailscale.port == cfg.port);
            message = "alanix.openwebrx.expose.tailscale.port must differ from alanix.openwebrx.port because OpenWebRX binds 0.0.0.0 on its local port.";
          }
          {
            assertion = !(cfg.expose.wireguard.enable && cfg.expose.wireguard.port == cfg.port);
            message = "alanix.openwebrx.expose.wireguard.port must differ from alanix.openwebrx.port because OpenWebRX binds 0.0.0.0 on its local port.";
          }
        ]
        ++ lib.flatten (
          lib.mapAttrsToList
            (uname: userCfg: [
              {
                assertion = lib.hasAttrByPath [ "sops" "secrets" userCfg.passwordSecret ] config;
                message = "alanix.openwebrx.users.${uname}.passwordSecret '${userCfg.passwordSecret}' must be declared as a sops secret.";
              }
            ])
            cfg.users
        )
        ++ serviceExposure.mkAssertions {
          inherit config endpoint;
          exposeCfg = cfg.expose;
          optionPrefix = "alanix.openwebrx.expose";
        };

      environment.etc."openwebrx/openwebrx.conf".source = openwebrxConfFile;
      environment.etc."openwebrx/config_webrx.py".source = openwebrxConfigFile;

      services.openwebrx = {
        enable = true;
        package = cfg.package;
      };

      hardware.rtl-sdr = {
        enable = true;
        package = pkgs.rtl-sdr-blog;
      };

      # Some kernels also expose RTL2832 sticks through the V4L2 SDR path, which
      # can race with librtlsdr users even when the DVB stack is blacklisted.
      boot.blacklistedKernelModules = [ "rtl2832_sdr" ];

      users.groups.openwebrx = { };
      users.users.openwebrx = {
        isSystemUser = true;
        group = "openwebrx";
        home = dataDir;
        extraGroups = lib.unique (cfg.extraGroups ++ [ "plugdev" ]);
      };

      systemd.services.openwebrx = {
        after = lib.optionals (cfg.users != { }) [ "sops-nix.service" ];
        wants = lib.optionals (cfg.users != { }) [ "sops-nix.service" ];
        path = lib.mkAfter [ pkgs.coreutils pkgs.kmod pkgs.util-linux ];
        preStart = ''
          set -euo pipefail

          # Re-apply rtl-sdr udev permissions for already-plugged USB dongles.
          ${pkgs.systemd}/bin/udevadm trigger --subsystem-match=usb --attr-match=idVendor=0bda --attr-match=idProduct=2838 || true
          ${pkgs.systemd}/bin/udevadm settle || true

          # If the dongle was already claimed by a kernel DVB/SDR driver before
          # this generation became active, unbind it so rtl_connector can take
          # over without requiring a reboot or replug.
          for devpath in /sys/bus/usb/devices/*; do
            [ -f "$devpath/idVendor" ] || continue
            [ -f "$devpath/idProduct" ] || continue
            [ "$(${pkgs.coreutils}/bin/cat "$devpath/idVendor")" = "0bda" ] || continue
            [ "$(${pkgs.coreutils}/bin/cat "$devpath/idProduct")" = "2838" ] || continue

            for iface in "$devpath":*; do
              [ -e "$iface" ] || continue
              [ -L "$iface/driver" ] || continue

              driver_path="$(${pkgs.coreutils}/bin/readlink -f "$iface/driver")"
              driver_name="$(${pkgs.coreutils}/bin/basename "$driver_path")"

              case "$driver_name" in
                dvb_usb_rtl28xxu|rtl2832_sdr)
                  iface_name="$(${pkgs.coreutils}/bin/basename "$iface")"
                  echo "Unbinding $iface_name from $driver_name for OpenWebRX"
                  printf '%s' "$iface_name" > "$driver_path/unbind" || true
                  ;;
              esac
            done
          done

          # Blacklisting prevents the next boot from loading these drivers
          # again, but during the current boot we also want them gone so a
          # later replug does not immediately reclaim the stick.
          ${pkgs.kmod}/bin/modprobe -r dvb_usb_rtl28xxu rtl2832_sdr rtl2832 >/dev/null 2>&1 || true

          ${lib.optionalString (cfg.users != { }) ''
            ${passfileLines}

            ensure_user() {
              local username="$1"
              local passfile="$2"
              local password

              password="$(tr -d '\r\n' < "$passfile")"

              if ${pkgs.util-linux}/bin/runuser -u openwebrx -- \
                ${pkgs.coreutils}/bin/env HOME=${dataDir} \
                ${cfg.package}/bin/openwebrx admin --noninteractive --silent hasuser "$username" >/dev/null 2>&1; then
                echo "Reconciling OpenWebRX user: $username"
                ${pkgs.util-linux}/bin/runuser -u openwebrx -- \
                  ${pkgs.coreutils}/bin/env HOME=${dataDir} OWRX_PASSWORD="$password" \
                  ${cfg.package}/bin/openwebrx admin --noninteractive resetpassword "$username"
              else
                echo "Creating OpenWebRX user: $username"
                ${pkgs.util-linux}/bin/runuser -u openwebrx -- \
                  ${pkgs.coreutils}/bin/env HOME=${dataDir} OWRX_PASSWORD="$password" \
                  ${cfg.package}/bin/openwebrx admin --noninteractive adduser "$username"
              fi

              ${pkgs.util-linux}/bin/runuser -u openwebrx -- \
                ${pkgs.coreutils}/bin/env HOME=${dataDir} \
                ${cfg.package}/bin/openwebrx admin --noninteractive --silent enableuser "$username" >/dev/null 2>&1 || true
            }

            ${lib.concatStringsSep "\n"
              (lib.mapAttrsToList
                (uname: _:
                  let
                    var = "PASSFILE_" + sanitizeUserKey uname;
                  in
                  ''ensure_user ${lib.escapeShellArg uname} "${"$"}${var}"'')
                cfg.users)}
          ''}
        '';
        restartTriggers = [ openwebrxConfFile openwebrxConfigFile (builtins.toJSON usersForRestart) ];
        serviceConfig = {
          DynamicUser = lib.mkForce false;
          PermissionsStartOnly = true;
          User = "openwebrx";
          Group = "openwebrx";
          UMask = "0077";
        };
      };
    }

    (serviceExposure.mkConfig {
      inherit config endpoint;
      exposeCfg = cfg.expose;
      serviceName = "openwebrx";
      serviceDescription = "OpenWebRX";
    })
  ]);
}
