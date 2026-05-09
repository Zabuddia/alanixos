{ config, lib, pkgs, ... }:
let
  cfg = config.alanix.radioStreams;

  hasValue = value: value != null && value != "";
  sanitizeName = name: lib.replaceStrings [ "-" "." "@" "+" " " "/" ] [ "_" "_" "_" "_" "_" "_" ] name;
  stationNames = builtins.attrNames cfg.stations;
  defaultStationId =
    if cfg.defaultStation != null then
      cfg.defaultStation
    else if stationNames != [ ] then
      builtins.head stationNames
    else
      null;

  liqString = value: builtins.toJSON value;
  currentStationFile = "${cfg.stateDir}/current-station";
  streamUrlLocal = "http://127.0.0.1:${toString cfg.icecastPort}${cfg.liveMount}";
  streamUrlTailscale =
    if config.alanix.icecast.expose.tailscale.enable && config.alanix.icecast.expose.tailscale.port != null then
      "http://${config.alanix.tailscale.address}:${toString config.alanix.icecast.expose.tailscale.port}${cfg.liveMount}"
    else
      null;
  streamUrlWireguard =
    if config.alanix.icecast.expose.wireguard.enable
      && config.alanix.icecast.expose.wireguard.address != null
      && config.alanix.icecast.expose.wireguard.port != null then
      "http://${config.alanix.icecast.expose.wireguard.address}:${toString config.alanix.icecast.expose.wireguard.port}${cfg.liveMount}"
    else
      null;

  stationWithDerived =
    id: station:
    let
      audioRate =
        if station.audioRate != null then
          station.audioRate
        else if station.mode == "wbfm" then
          44100
        else
          24000;

      audioLowPass =
        if station.audioLowPass != null then
          station.audioLowPass
        else if station.mode == "wbfm" then
          15000
        else
          null;

      applyDeemphasis =
        if station.deemphasis != null then station.deemphasis
        else station.mode == "wbfm";

      deemphasisHz = if applyDeemphasis then 2122 else null;

      rtlMode =
        if station.mode == "nfm" then
          "fm"
        else
          station.mode;

      rtlSampleRate =
        if station.sampleRate != null then
          station.sampleRate
        else if station.mode == "wbfm" then
          170000
        else
          audioRate;

      rtlArgs =
        [
          "-d"
          cfg.device
          "-f"
          (toString station.frequency)
          "-M"
          rtlMode
        ]
        ++ lib.optionals (station.gain != "auto") [ "-g" (toString station.gain) ]
        ++ lib.optionals (station.ppm != 0) [ "-p" (toString station.ppm) ]
        ++ lib.optionals (station.biasTee == true) [ "-T" ]
        ++ lib.optionals (rtlSampleRate != null) [ "-s" (toString rtlSampleRate) ]
        ++ [ "-r" (toString audioRate) ]
        ++ lib.optionals (station.mode == "wbfm") [ "-F" "9" ]
        ++ station.extraRtlFmArgs;

      tunerCommand = "${pkgs.rtl-sdr-blog}/bin/rtl_fm ${lib.escapeShellArgs rtlArgs}";
    in
    station
    // {
      inherit audioRate audioLowPass deemphasisHz tunerCommand;
      stationId = id;
    };

  stationsDerived = lib.mapAttrs stationWithDerived cfg.stations;
  stationEntries = lib.sort
    (left: right: left.station.frequency < right.station.frequency)
    (lib.mapAttrsToList (id: station: { inherit id station; }) stationsDerived);

  stationListText = lib.concatStringsSep "\n" (
    map
      ({ id, station }:
        "${id}\t${station.name}\t${toString station.frequency} Hz\t${station.mode}\t${cfg.liveMount}")
      stationEntries
  );

  stationValidationCase = lib.concatStringsSep "\n" (
    lib.mapAttrsToList
      (id: _: ''
        ${lib.escapeShellArg id}) ;;
      '')
      stationsDerived
  );

  stationRuntimeCase = lib.concatStringsSep "\n" (
    lib.mapAttrsToList
      (id: station: ''
        ${lib.escapeShellArg id})
          station_name=${lib.escapeShellArg station.name}
          station_description=${lib.escapeShellArg station.description}
          station_genre=${lib.escapeShellArg station.genre}
          station_audio_rate=${lib.escapeShellArg (toString station.audioRate)}
          station_deemphasis_liq=${lib.escapeShellArg (
            if station.deemphasisHz == null then "" else "radio = filter.iir.butterworth.low(frequency=${toString station.deemphasisHz}., order=1, radio)"
          )}
          station_audio_low_pass_liq=${lib.escapeShellArg (
            if station.audioLowPass == null then "" else "radio = filter.iir.butterworth.low(frequency=${toString station.audioLowPass}., order=6, radio)"
          )}
          station_bitrate=${lib.escapeShellArg (toString station.bitrate)}
          station_name_liq=${lib.escapeShellArg (liqString station.name)}
          station_description_liq=${lib.escapeShellArg (liqString station.description)}
          station_genre_liq=${lib.escapeShellArg (liqString station.genre)}
          station_title_liq=${lib.escapeShellArg (liqString "${station.name} (${id})")}
          station_tuner_command_liq=${lib.escapeShellArg (liqString station.tunerCommand)}
          ;;
      '')
      stationsDerived
  );

  preStartScript = ''
    set -euo pipefail

    ${pkgs.systemd}/bin/udevadm trigger --subsystem-match=usb --attr-match=idVendor=0bda --attr-match=idProduct=2838 || true
    ${pkgs.systemd}/bin/udevadm settle || true

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
            echo "Unbinding $iface_name from $driver_name for SDR radio stream"
            printf '%s' "$iface_name" > "$driver_path/unbind" || true
            ;;
        esac
      done
    done

    ${pkgs.kmod}/bin/modprobe -r dvb_usb_rtl28xxu rtl2832_sdr rtl2832 >/dev/null 2>&1 || true

    install -d -m 0755 -o radio-stream -g radio-stream ${lib.escapeShellArg cfg.stateDir}
    if [ ! -s ${lib.escapeShellArg currentStationFile} ]; then
      printf '%s\n' ${lib.escapeShellArg defaultStationId} > ${lib.escapeShellArg currentStationFile}
      chown radio-stream:radio-stream ${lib.escapeShellArg currentStationFile}
    fi
    chmod 0644 ${lib.escapeShellArg currentStationFile}
  '';

  writeCurrentStation = ''
    write_current_station() {
      local station_id="$1"
      local tmp

      install -d -m 0755 -o radio-stream -g radio-stream ${lib.escapeShellArg cfg.stateDir}
      tmp="$(mktemp ${lib.escapeShellArg "${cfg.stateDir}/current-station.XXXXXX"})"
      printf '%s\n' "$station_id" > "$tmp"
      chown radio-stream:radio-stream "$tmp"
      chmod 0644 "$tmp"
      mv "$tmp" ${lib.escapeShellArg currentStationFile}
    }
  '';

  ensureDefaultStation = ''
    if [ ! -s ${lib.escapeShellArg currentStationFile} ]; then
      write_current_station ${lib.escapeShellArg defaultStationId}
    fi
  '';

  printStreamUrls = ''
    print_stream_urls() {
      printf 'Local URL: %s\n' ${lib.escapeShellArg streamUrlLocal}
      ${lib.optionalString (streamUrlTailscale != null) ''
        printf 'Tailscale name URL: %s\n' ${lib.escapeShellArg streamUrlTailscale}
        tailscale_ip="$(${pkgs.tailscale}/bin/tailscale ip -4 2>/dev/null | ${pkgs.coreutils}/bin/head -n 1 || true)"
        if [ -n "$tailscale_ip" ]; then
          printf 'Tailscale IP URL: http://%s:%s%s\n' "$tailscale_ip" ${lib.escapeShellArg (toString config.alanix.icecast.expose.tailscale.port)} ${lib.escapeShellArg cfg.liveMount}
        fi
      ''}
      ${lib.optionalString (streamUrlWireguard != null) ''
        printf 'WireGuard URL: %s\n' ${lib.escapeShellArg streamUrlWireguard}
      ''}
    }
  '';

  radioList = pkgs.writeShellScriptBin "radio-list" ''
    set -euo pipefail

    printf 'ID\tName\tFrequency\tMode\tStream\n'
    printf '%b\n' ${lib.escapeShellArg stationListText}
    printf '\nStable stream URLs:\n'
    ${printStreamUrls}
    print_stream_urls
  '';

  radioSet = pkgs.writeShellScriptBin "radio-set" ''
    set -euo pipefail

    station_id="''${1:-}"
    if [ -z "$station_id" ]; then
      echo "Usage: sudo alanix-radio set <station-id>" >&2
      echo "Run 'alanix-radio list' to see available stations." >&2
      exit 1
    fi

    case "$station_id" in
    ${stationValidationCase}
      *)
        echo "Unknown station: $station_id" >&2
        echo "Run 'alanix-radio list' to see available stations." >&2
        exit 1
        ;;
    esac

    if ! systemctl is-active --quiet sdr-radio-stream.service; then
      if systemctl is-active --quiet openwebrx.service; then
        echo "Cannot set station while in explore mode." >&2
        echo "Run 'sudo alanix-radio car $station_id' to switch to car mode on this station." >&2
      else
        echo "Cannot set station because car mode is not active." >&2
        echo "Run 'sudo alanix-radio car $station_id' first." >&2
      fi
      exit 1
    fi

    ${writeCurrentStation}
    write_current_station "$station_id"
    systemctl restart sdr-radio-stream.service
    echo "Retuned car-radio stream to $station_id."

    ${printStreamUrls}
    print_stream_urls
  '';

  radioCarMode = pkgs.writeShellScriptBin "radio-car-mode" ''
    set -euo pipefail

    ${writeCurrentStation}

    if [ "''${1:-}" != "" ]; then
      station_id="$1"
      case "$station_id" in
      ${stationValidationCase}
        *)
          echo "Unknown station: $station_id" >&2
          echo "Run 'alanix-radio list' to see available stations." >&2
          exit 1
          ;;
      esac
      write_current_station "$station_id"
      echo "Selected station: $station_id."
    else
      ${ensureDefaultStation}
    fi

    systemctl stop openwebrx.service 2>/dev/null || true
    systemctl reset-failed openwebrx.service 2>/dev/null || true
    systemctl start icecast.service
    systemctl restart sdr-radio-stream.service

    current_station="$(tr -d '\r\n' < ${lib.escapeShellArg currentStationFile})"
    echo "Car-radio mode active on station: $current_station"
    ${printStreamUrls}
    print_stream_urls
  '';

  radioExploreMode = pkgs.writeShellScriptBin "radio-explore-mode" ''
    set -euo pipefail

    systemctl stop sdr-radio-stream.service 2>/dev/null || true
    systemctl reset-failed sdr-radio-stream.service 2>/dev/null || true
    ${lib.optionalString config.alanix.openwebrx.enable ''
      systemctl reset-failed openwebrx.service 2>/dev/null || true
      systemctl start openwebrx.service
      echo "OpenWebRX exploration mode active."
    ''}
    ${lib.optionalString (!config.alanix.openwebrx.enable) ''
      echo "OpenWebRX is not enabled on this host."
    ''}
  '';

  radioStatus = pkgs.writeShellScriptBin "radio-status" ''
    set -euo pipefail

    unit_state() {
      systemctl is-active "$1" 2>/dev/null || true
    }

    if [ -s ${lib.escapeShellArg currentStationFile} ]; then
      current_station="$(tr -d '\r\n' < ${lib.escapeShellArg currentStationFile})"
    elif systemctl is-active --quiet sdr-radio-stream.service; then
      current_station="<unreadable until next retune or nrs>"
    else
      current_station="<unset>"
    fi

    openwebrx_state="$(unit_state openwebrx.service)"
    icecast_state="$(unit_state icecast.service)"
    stream_state="$(unit_state sdr-radio-stream.service)"

    if [ "$stream_state" = "active" ]; then
      mode="car-radio"
    elif [ "$openwebrx_state" = "active" ]; then
      mode="explore"
    else
      mode="idle"
    fi

    echo "Mode: $mode"
    echo "Station: $current_station"
    echo "OpenWebRX: $openwebrx_state"
    echo "Icecast: $icecast_state"
    echo "SDR stream: $stream_state"
    if [ "$icecast_state" = "active" ] && [ "$stream_state" = "active" ]; then
      echo "Stream: live"
    else
      echo "Stream: not publishing"
    fi
    echo
    ${printStreamUrls}
    print_stream_urls
  '';

  alanixRadio = pkgs.writeShellScriptBin "alanix-radio" ''
    set -euo pipefail

    show_help() {
      cat <<'HELP'
Usage:
  alanix-radio help
  alanix-radio status
  alanix-radio list
  sudo alanix-radio car [station-id]
  sudo alanix-radio set <station-id>
  sudo alanix-radio explore

Modes:
  car       RTL-SDR -> Icecast stream for phone/Android Auto.
  explore   RTL-SDR -> OpenWebRX browser workbench.

Notes:
  set only works while car mode is already active.
  Use car <station-id> to switch from explore mode directly to a station.
HELP
    }

    case "''${1:-}" in
      ""|help|-h|--help)
        show_help
        ;;
      list)
        exec ${radioList}/bin/radio-list
        ;;
      set)
        shift
        exec ${radioSet}/bin/radio-set "$@"
        ;;
      car)
        shift
        exec ${radioCarMode}/bin/radio-car-mode "$@"
        ;;
      explore)
        exec ${radioExploreMode}/bin/radio-explore-mode
        ;;
      status)
        exec ${radioStatus}/bin/radio-status
        ;;
      *)
        show_help >&2
        exit 1
        ;;
    esac
  '';
in
{
  options.alanix.radioStreams = {
    enable = lib.mkEnableOption "RTL-SDR car-radio stream mode";

    device = lib.mkOption {
      type = lib.types.str;
      default = "0";
      description = "RTL-SDR device index or serial passed to rtl_fm.";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/sdr-radio-stream";
      description = "Directory storing the selected station and runtime state.";
    };

    defaultStation = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Station selected when no current-station state exists.";
    };

    liveMount = lib.mkOption {
      type = lib.types.str;
      default = "/live.mp3";
      description = "Stable Icecast mount used by Android Auto and radio apps.";
    };

    streamName = lib.mkOption {
      type = lib.types.str;
      default = "${config.networking.hostName} SDR Radio";
      description = "Icecast stream name for the stable live mount.";
    };

    sourcePasswordSecret = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = config.alanix.icecast.source.passwordSecret or null;
      description = ''
        SOPS secret containing the Icecast source password. Defaults to the
        password configured for alanix.icecast when available.
      '';
    };

    icecastHost = lib.mkOption {
      type = lib.types.str;
      default = config.alanix.icecast.listenAddress or "127.0.0.1";
      description = "Icecast host used by Liquidsoap when publishing the local stream.";
    };

    icecastPort = lib.mkOption {
      type = lib.types.port;
      default = config.alanix.icecast.port or 8000;
      description = "Icecast port used by Liquidsoap when publishing the local stream.";
    };

    extraGroups = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "video" ];
      description = "Extra groups granted to the radio streaming service user.";
    };

    stations = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
        options = {
          name = lib.mkOption {
            type = lib.types.str;
            default = name;
            description = "Display name for this station preset.";
          };

          description = lib.mkOption {
            type = lib.types.str;
            default = "Off-air SDR stream";
            description = "Icecast stream description for this station.";
          };

          genre = lib.mkOption {
            type = lib.types.str;
            default = "Radio";
            description = "Icecast genre metadata for this station.";
          };

          frequency = lib.mkOption {
            type = lib.types.int;
            description = "Tuned frequency in Hz.";
          };

          mode = lib.mkOption {
            type = lib.types.enum [ "wbfm" "fm" "nfm" "am" "usb" "lsb" ];
            description = "Demodulation mode used by rtl_fm.";
          };

          gain = lib.mkOption {
            type = lib.types.oneOf [ lib.types.int lib.types.float lib.types.str ];
            default = "auto";
            description = "RTL-SDR gain setting. Use \"auto\" to let rtl_fm choose.";
          };

          sampleRate = lib.mkOption {
            type = lib.types.nullOr lib.types.int;
            default = null;
            description = "Optional rtl_fm sample rate passed with -s.";
          };

          audioRate = lib.mkOption {
            type = lib.types.nullOr lib.types.int;
            default = null;
            description = ''
              Optional PCM rate handed from rtl_fm to Liquidsoap. Defaults to
              44100 for WBFM and 24000 for the other modes.
            '';
          };

          audioLowPass = lib.mkOption {
            type = lib.types.nullOr lib.types.ints.positive;
            default = null;
            description = ''
              Optional Liquidsoap low-pass cutoff in Hz. WBFM presets default
              to 12000 Hz to reduce FM pilot/ringing artifacts before Icecast.
            '';
          };

          bitrate = lib.mkOption {
            type = lib.types.ints.positive;
            default = 96;
            description = "MP3 bitrate in kbps passed to Liquidsoap.";
          };

          ppm = lib.mkOption {
            type = lib.types.int;
            default = 0;
            description = "PPM correction passed to rtl_fm.";
          };

          biasTee = lib.mkOption {
            type = lib.types.nullOr lib.types.bool;
            default = null;
            description = "Whether to enable the RTL-SDR bias tee for this station.";
          };

          extraRtlFmArgs = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "Extra arguments appended to rtl_fm.";
          };

          deemphasis = lib.mkOption {
            type = lib.types.nullOr lib.types.bool;
            default = null;
            description = ''
              Apply 75µs FM de-emphasis (first-order low-pass at 2122 Hz) in
              Liquidsoap. Defaults to true for wbfm since rtl_fm does not apply
              de-emphasis in wbfm mode. Set to false to disable explicitly.
            '';
          };
        };
      }));
      default = { };
      description = ''
        Declarative station presets. The selected preset is stored at runtime
        and all presets publish to alanix.radioStreams.liveMount.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions =
      [
        {
          assertion = config.alanix.icecast.enable;
          message = "alanix.radioStreams.enable requires alanix.icecast.enable = true.";
        }
        {
          assertion = cfg.stations != { };
          message = "alanix.radioStreams.stations must define at least one station preset.";
        }
        {
          assertion = defaultStationId != null && lib.hasAttr defaultStationId cfg.stations;
          message = "alanix.radioStreams.defaultStation must name one of alanix.radioStreams.stations when set.";
        }
        {
          assertion = hasValue cfg.sourcePasswordSecret;
          message = "alanix.radioStreams.sourcePasswordSecret must be set or inherited from alanix.icecast.source.passwordSecret.";
        }
        {
          assertion = lib.hasPrefix "/" cfg.stateDir;
          message = "alanix.radioStreams.stateDir must be an absolute path.";
        }
        {
          assertion = lib.hasPrefix "/" cfg.liveMount;
          message = "alanix.radioStreams.liveMount must start with '/'.";
        }
        {
          assertion = builtins.match "^/[A-Za-z0-9._/-]+$" cfg.liveMount != null;
          message = "alanix.radioStreams.liveMount may contain only letters, digits, dot, underscore, slash, and hyphen.";
        }
        {
          assertion = lib.hasAttrByPath [ "sops" "secrets" cfg.sourcePasswordSecret ] config;
          message = "alanix.radioStreams.sourcePasswordSecret must reference a declared sops secret.";
        }
      ]
      ++ lib.flatten (lib.mapAttrsToList
        (id: _: [
          {
            assertion = builtins.match "^[A-Za-z0-9._-]+$" id != null;
            message = "alanix.radioStreams.stations.${id}: station IDs may contain only letters, digits, dot, underscore, and hyphen.";
          }
        ])
        cfg.stations);

    hardware.rtl-sdr = {
      enable = true;
      package = lib.mkDefault pkgs.rtl-sdr-blog;
    };

    boot.blacklistedKernelModules = [ "rtl2832_sdr" ];

    users.groups.radio-stream = { };
    users.users.radio-stream = {
      isSystemUser = true;
      group = "radio-stream";
      extraGroups = lib.unique (cfg.extraGroups ++ [ "plugdev" ]);
      home = cfg.stateDir;
      createHome = false;
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0755 radio-stream radio-stream - -"
      "z ${cfg.stateDir} 0755 radio-stream radio-stream - -"
      "z ${currentStationFile} 0644 radio-stream radio-stream - -"
    ];

    environment.systemPackages = [
      alanixRadio
    ];

    systemd.services.openwebrx = lib.mkIf config.alanix.openwebrx.enable {
      conflicts = [ "sdr-radio-stream.service" ];
      wantedBy = lib.mkForce [ ];
    };

    system.activationScripts.alanixRadioResetOpenWebRXFailure =
      lib.mkIf config.alanix.openwebrx.enable ''
        ${pkgs.systemd}/bin/systemctl reset-failed openwebrx.service 2>/dev/null || true
      '';

    systemd.services.sdr-radio-stream = {
      description = "RTL-SDR car-radio stream to Icecast";
      after =
        [ "icecast.service" "network-online.target" ]
        ++ lib.optional config.alanix.openwebrx.enable "openwebrx.service";
      wants = [ "icecast.service" "network-online.target" ];
      requires = [ "icecast.service" ];
      conflicts = lib.optional config.alanix.openwebrx.enable "openwebrx.service";
      path = [ pkgs.coreutils pkgs.kmod pkgs.systemd ];
      preStart = preStartScript;
      script = ''
        set -euo pipefail

        station_id="$(tr -d '\r\n' < ${lib.escapeShellArg currentStationFile})"

        case "$station_id" in
        ${stationRuntimeCase}
          *)
            echo "Unknown station in ${currentStationFile}: $station_id" >&2
            echo "Run 'radio-list' and then 'radio-set <station-id>'." >&2
            exit 1
            ;;
        esac

        export ICECAST_SOURCE_PASSWORD="$(tr -d '\r\n' < "$CREDENTIALS_DIRECTORY/icecast_source_password")"

        liquidsoap_script="$RUNTIME_DIRECTORY/sdr-radio-stream.liq"
        cat > "$liquidsoap_script" <<LIQ
        source_password = environment.get("ICECAST_SOURCE_PASSWORD")

        radio = input.external.rawaudio(
          channels=1,
          samplerate=$station_audio_rate,
          restart=false,
          restart_on_error=true,
          $station_tuner_command_liq
        )

        radio = insert_metadata(radio)
        radio.insert_metadata(new_track=true, [
          ("title", $station_title_liq),
          ("artist", "RTL-SDR"),
          ("genre", $station_genre_liq)
        ])

        radio = stereo(radio)
        $station_deemphasis_liq
        $station_audio_low_pass_liq
        radio = mksafe(radio)

        output.icecast(
          %mp3(bitrate=$station_bitrate),
          host=${liqString cfg.icecastHost},
          port=${toString cfg.icecastPort},
          password=source_password,
          mount=${liqString cfg.liveMount},
          name=${liqString cfg.streamName},
          genre=$station_genre_liq,
          description=$station_description_liq,
          public=false,
          radio
        )
        LIQ

        echo "Starting station $station_id: $station_name"
        echo "Tuner command: $station_tuner_command_liq"
        exec ${pkgs.liquidsoap}/bin/liquidsoap "$liquidsoap_script"
      '';
      serviceConfig = {
        Type = "simple";
        User = "radio-stream";
        Group = "radio-stream";
        DynamicUser = false;
        PermissionsStartOnly = true;
        RuntimeDirectory = "sdr-radio-stream";
        RuntimeDirectoryMode = "0750";
        Restart = "on-failure";
        RestartSec = "2s";
        TimeoutStopSec = "5s";
        LoadCredential = [ "icecast_source_password:${config.sops.secrets.${cfg.sourcePasswordSecret}.path}" ];
        UMask = "0077";
      };
    };
  };
}
