{ config, lib, pkgs, ... }:
let
  cfg = config.alanix.xmpp;
  realtimeCfg = config.alanix.realtime;
  certificateDir = config.security.acme.certs.${cfg.domain}.directory;
  serviceExposure = import ../../../lib/mkServiceExposure.nix { inherit lib pkgs; };
in
{
  options.alanix.xmpp = {
    enable = lib.mkEnableOption "the public Prosody XMPP service";

    domain = lib.mkOption {
      type = lib.types.str;
      default = "fifefin.com";
      description = "XMPP user domain (the portion after @ in a Jabber ID).";
    };

    serverDomain = lib.mkOption {
      type = lib.types.str;
      default = "xmpp.${cfg.domain}";
      defaultText = "xmpp.<domain>";
      description = "DNS name targeted by the client and server SRV records.";
    };

    conferenceDomain = lib.mkOption {
      type = lib.types.str;
      default = "conference.${cfg.domain}";
      defaultText = "conference.<domain>";
      description = "Multi-user chat component domain.";
    };

    uploadDomain = lib.mkOption {
      type = lib.types.str;
      default = "upload.${cfg.domain}";
      defaultText = "upload.<domain>";
      description = "Public HTTPS file-upload endpoint.";
    };

    clientPort = lib.mkOption {
      type = lib.types.port;
      default = 5222;
    };

    serverPort = lib.mkOption {
      type = lib.types.port;
      default = 5269;
    };

    upload = {
      maxFileSize = lib.mkOption {
        type = lib.types.ints.positive;
        default = 100 * 1024 * 1024;
        defaultText = "100 MiB";
      };

      expiresAfter = lib.mkOption {
        type = lib.types.str;
        default = "30 days";
      };

      dailyQuota = lib.mkOption {
        type = lib.types.ints.positive;
        default = 1024 * 1024 * 1024;
        defaultText = "1 GiB";
      };

      expose = serviceExposure.mkOptions {
        serviceName = "xmpp-upload";
        serviceDescription = "XMPP HTTP uploads";
        defaultPublicPort = 443;
      };
    };

    archiveExpiresAfter = lib.mkOption {
      type = lib.types.str;
      default = "1 year";
      description = "Retention period for one-to-one and MUC message archives.";
    };

    acme = {
      dnsProvider = lib.mkOption {
        type = lib.types.str;
        default = "cloudflare";
      };

      credentialsFile = lib.mkOption {
        type = lib.types.path;
        description = "Environment file containing credentials for the ACME DNS provider.";
      };
    };

    cluster = {
      enable = lib.mkEnableOption "cluster management for the personal XMPP service";
      backupDir = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
      };
      backupInterval = lib.mkOption {
        type = lib.types.str;
        default = "12h";
      };
      maxBackupAge = lib.mkOption {
        type = lib.types.str;
        default = "24h";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.alanix.cluster.enable;
        message = "alanix.xmpp currently requires alanix.cluster.enable.";
      }
      {
        assertion = realtimeCfg.enable && realtimeCfg.cluster.enable;
        message = "alanix.xmpp requires the neutral clustered alanix.realtime Prosody/TURN runtime.";
      }
      {
        assertion = !cfg.cluster.enable || cfg.cluster.backupDir != null;
        message = "alanix.xmpp.cluster.enable requires alanix.xmpp.cluster.backupDir.";
      }
      {
        assertion = cfg.cluster.backupDir == null || lib.hasPrefix "/" cfg.cluster.backupDir;
        message = "alanix.xmpp.cluster.backupDir must be absolute.";
      }
      {
        assertion = lib.all (value: value != "") [ cfg.domain cfg.serverDomain cfg.conferenceDomain cfg.uploadDomain ];
        message = "alanix.xmpp domain names must not be empty.";
      }
      {
        assertion = lib.length (lib.unique [ cfg.domain cfg.serverDomain cfg.conferenceDomain cfg.uploadDomain ]) == 4;
        message = "alanix.xmpp domain names must be distinct.";
      }
    ];

    security.acme.acceptTerms = lib.mkDefault true;
    security.acme.certs.${cfg.domain} = {
      dnsProvider = cfg.acme.dnsProvider;
      environmentFile = cfg.acme.credentialsFile;
      extraDomainNames = [
        cfg.serverDomain
        cfg.conferenceDomain
        cfg.uploadDomain
      ];
      group = "prosody";
      reloadServices = [ "prosody.service" ];
    };

    services.prosody = {
      enable = true;
      admins = [ "buddia@${cfg.domain}" ];
      allowRegistration = false;
      authentication = "internal_hashed";
      c2sRequireEncryption = true;
      s2sRequireEncryption = true;
      s2sSecureAuth = false;

      # Only Caddy is public for HTTP. XMPP itself owns 5222/5269 directly.
      httpInterfaces = [ "127.0.0.1" ];
      httpsInterfaces = [ "127.0.0.1" ];

      modules = {
        register = false;
        mam = true;
        smacks = true;
        carbons = true;
        csi = true;
        cloud_notify = true;
        bookmarks = true;
        blocklist = true;
        ping = true;
      };

      httpFileShare = {
        domain = cfg.uploadDomain;
        http_external_url = "https://${cfg.uploadDomain}/";
        size_limit = cfg.upload.maxFileSize;
        expires_after = cfg.upload.expiresAfter;
        daily_quota = cfg.upload.dailyQuota;
      };

      muc = [
        {
          domain = cfg.conferenceDomain;
          name = "Fifefin Chatrooms";
          restrictRoomCreation = "local";
          maxHistoryMessages = 100;
          roomDefaultPublic = false;
          roomDefaultMembersOnly = false;
          roomDefaultPublicJids = false;
          roomDefaultHistoryLength = 50;
          extraConfig = ''
            muc_log_by_default = true
            muc_log_expires_after = "${cfg.archiveExpiresAfter}"
          '';
        }
      ];

      extraConfig = lib.mkAfter ''
        c2s_ports = { ${toString cfg.clientPort} }
        s2s_ports = { ${toString cfg.serverPort} }
        archive_expires_after = "${cfg.archiveExpiresAfter}"
        default_archive_policy = "always"
        smacks_hibernation_time = 86400
        smacks_max_hibernated_sessions = 10
        turn_external_tls_port = ${toString realtimeCfg.turn.tlsPort}
        limits = {
          c2s = { rate = "10kb/s"; burst = "2s"; };
          s2sin = { rate = "30kb/s"; burst = "5s"; };
        }
      '';

      virtualHosts.${cfg.domain} = {
        domain = cfg.domain;
        enabled = true;
        ssl = {
          key = "${certificateDir}/key.pem";
          cert = "${certificateDir}/fullchain.pem";
        };
        extraConfig = lib.mkAfter ''
          modules_enabled = { "turn_external" }
          turn_external_host = "${realtimeCfg.turn.hostName}"
          turn_external_port = ${toString realtimeCfg.turn.port}
          turn_external_secret = os.getenv("TURN_SECRET") or "prosody-config-validation-only"
          turn_external_tcp = true
        '';
      };
    };

    systemd.services.prosody = {
      after = [ "acme-${cfg.domain}.service" ];
      wants = [ "acme-${cfg.domain}.service" ];
    };

  };
}
