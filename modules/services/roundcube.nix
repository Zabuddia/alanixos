{ config, lib, pkgs, ... }:
let
  cfg = config.alanix.roundcube;
  clusterCfg = cfg.cluster;
  mailCfg = config.alanix.mail;
  serviceExposure = import ../../lib/mkServiceExposure.nix { inherit lib pkgs; };

  exposeCfg = cfg.expose;
  hasValue = value: value != null && value != "";

  effectiveMailFqdn =
    if hasValue mailCfg.fqdn then
      mailCfg.fqdn
    else if hasValue mailCfg.domain then
      "mail.${mailCfg.domain}"
    else
      "localhost";

  effectiveMailDomain =
    if hasValue cfg.mail.domain then
      cfg.mail.domain
    else if hasValue mailCfg.domain then
      mailCfg.domain
    else
      null;

  effectiveImapHost =
    if hasValue cfg.mail.imapHost then
      cfg.mail.imapHost
    else if mailCfg.enable && mailCfg.enableImapSsl then
      "ssl://${effectiveMailFqdn}:993"
    else if mailCfg.enable && mailCfg.enableImap then
      "tls://${effectiveMailFqdn}:143"
    else
      "localhost:143";

  effectiveSmtpHost =
    if hasValue cfg.mail.smtpHost then
      cfg.mail.smtpHost
    else if mailCfg.enable && mailCfg.enableSubmissionSsl then
      "ssl://${effectiveMailFqdn}:465"
    else if mailCfg.enable && mailCfg.enableSubmission then
      "tls://${effectiveMailFqdn}:587"
    else
      "localhost:587";

  effectiveUsernameDomain =
    if hasValue cfg.mail.usernameDomain then
      cfg.mail.usernameDomain
    else
      effectiveMailDomain;

  phpString =
    value:
    "'${lib.replaceStrings [ "\\" "'" ] [ "\\\\" "\\'" ] value}'";

  phpBool = value: if value then "true" else "false";

  phpArrayOfStrings =
    values:
    "[${lib.concatMapStringsSep ", " phpString values}]";

  defaultTrustedHostPatterns =
    lib.filter hasValue (
      [
        cfg.hostName
        cfg.expose.wan.domain
      ]
      ++ lib.optional cfg.expose.tailscale.enable (
        if cfg.expose.tailscale.tlsName != null then cfg.expose.tailscale.tlsName else config.alanix.tailscale.address
      )
      ++ lib.optional cfg.expose.wireguard.enable (
        if cfg.expose.wireguard.tlsName != null then cfg.expose.wireguard.tlsName else config.alanix.wireguard.vpnIP
      )
      ++ lib.optional cfg.expose.tor.enable cfg.expose.tor.hostname
      ++ lib.optional (cfg.expose.tor.enable && cfg.expose.tor.tls) cfg.expose.tor.tlsName
    );

  trustedHostPatterns = lib.unique (defaultTrustedHostPatterns ++ cfg.trustedHostPatterns);

  endpoint = {
    address = cfg.listenAddress;
    port = cfg.port;
    protocol = "http";
  };

  baseConfigReady =
    hasValue cfg.hostName
    && hasValue cfg.listenAddress
    && cfg.port != null;

  roundcubeExtraConfig = ''
    $config['imap_host'] = ${phpString effectiveImapHost};
    $config['smtp_host'] = ${phpString effectiveSmtpHost};
    $config['smtp_user'] = ${phpString cfg.mail.smtpUser};
    $config['smtp_pass'] = ${phpString cfg.mail.smtpPass};
    $config['product_name'] = ${phpString cfg.productName};
    $config['skin'] = ${phpString cfg.skin};
    $config['username_domain_forced'] = ${phpBool cfg.mail.forceUsernameDomain};
  ''
  + lib.optionalString (trustedHostPatterns != [ ]) ''
    $config['trusted_host_patterns'] = ${phpArrayOfStrings trustedHostPatterns};
  ''
  + lib.optionalString (effectiveUsernameDomain != null) ''
    $config['username_domain'] = ${phpString effectiveUsernameDomain};
  ''
  + lib.optionalString (effectiveMailDomain != null) ''
    $config['mail_domain'] = ${phpString effectiveMailDomain};
  ''
  + lib.optionalString (cfg.supportUrl != null) ''
    $config['support_url'] = ${phpString cfg.supportUrl};
  ''
  + cfg.extraConfig;
in
{
  options.alanix.roundcube = {
    enable = lib.mkEnableOption "Roundcube webmail (Alanix)";

    hostName = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Browser-facing host name for this Roundcube instance.";
    };

    listenAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "127.0.0.1";
      description = "Internal nginx address used by Roundcube.";
    };

    port = lib.mkOption {
      type = lib.types.nullOr lib.types.port;
      default = null;
      description = "Internal nginx port used by Roundcube.";
    };

    package = lib.mkPackageOption pkgs "roundcube" {
      example = "pkgs.roundcube.withPlugins (plugins: [ plugins.persistent_login ])";
    };

    plugins = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Roundcube plugins to enable.";
    };

    dicts = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      example = lib.literalExpression "with pkgs.aspellDicts; [ en ]";
      description = "Aspell dictionaries used for Roundcube spell checking.";
    };

    maxAttachmentSize = lib.mkOption {
      type = lib.types.int;
      default = 18;
      description = "Roundcube attachment size limit in MB before encoding overhead.";
    };

    productName = lib.mkOption {
      type = lib.types.str;
      default = "Roundcube Webmail";
      description = "Name displayed by Roundcube.";
    };

    skin = lib.mkOption {
      type = lib.types.str;
      default = "elastic";
      description = "Roundcube skin name.";
    };

    supportUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional support URL shown by Roundcube.";
    };

    trustedHostPatterns = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional Roundcube trusted_host_patterns entries.";
    };

    extraConfig = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Extra PHP Roundcube configuration appended after Alanix defaults.";
    };

    database = {
      username = lib.mkOption {
        type = lib.types.str;
        default = "roundcube";
        description = "PostgreSQL user for Roundcube.";
      };

      dbname = lib.mkOption {
        type = lib.types.str;
        default = "roundcube";
        description = "PostgreSQL database for Roundcube.";
      };

      host = lib.mkOption {
        type = lib.types.str;
        default = "localhost";
        description = "PostgreSQL host. Use localhost for the locally managed database.";
      };

      passwordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "PostgreSQL .pgpass file for a remote Roundcube database.";
      };
    };

    mail = {
      domain = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Mail domain used for login completion and outgoing identities.";
      };

      usernameDomain = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Domain appended to local-part-only Roundcube logins.";
      };

      forceUsernameDomain = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether Roundcube should replace any login domain with usernameDomain.";
      };

      imapHost = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Roundcube IMAP endpoint, such as ssl://mail.example.com:993.";
      };

      smtpHost = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Roundcube SMTP endpoint, such as ssl://mail.example.com:465.";
      };

      smtpUser = lib.mkOption {
        type = lib.types.str;
        default = "%u";
        description = "Roundcube SMTP username template.";
      };

      smtpPass = lib.mkOption {
        type = lib.types.str;
        default = "%p";
        description = "Roundcube SMTP password template.";
      };
    };

    backupDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional Roundcube cluster backup staging directory.";
    };

    cluster = {
      enable = lib.mkEnableOption "cluster-manage Roundcube through alanix.cluster";

      backupInterval = lib.mkOption {
        type = lib.types.str;
        default = "15m";
      };

      maxBackupAge = lib.mkOption {
        type = lib.types.str;
        default = "1h";
      };
    };

    expose = serviceExposure.mkOptions {
      serviceName = "roundcube";
      serviceDescription = "Roundcube";
      defaultPublicPort = 80;
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions =
        [
          {
            assertion = hasValue cfg.hostName;
            message = "alanix.roundcube.hostName must be set when alanix.roundcube.enable = true.";
          }
          {
            assertion = hasValue cfg.listenAddress;
            message = "alanix.roundcube.listenAddress must be set when alanix.roundcube.enable = true.";
          }
          {
            assertion = cfg.port != null;
            message = "alanix.roundcube.port must be set when alanix.roundcube.enable = true.";
          }
          {
            assertion = cfg.backupDir == null || lib.hasPrefix "/" cfg.backupDir;
            message = "alanix.roundcube.backupDir must be an absolute path when set.";
          }
          {
            assertion = !clusterCfg.enable || cfg.backupDir != null;
            message = "alanix.roundcube.cluster.enable requires alanix.roundcube.backupDir to be set.";
          }
          {
            assertion = cfg.database.host == "localhost" || cfg.database.passwordFile != null;
            message = "alanix.roundcube.database.passwordFile must be set when using a remote database.";
          }
        ]
        ++ serviceExposure.mkAssertions {
          inherit config endpoint exposeCfg;
          optionPrefix = "alanix.roundcube.expose";
        };

      services.roundcube = lib.mkIf baseConfigReady {
        enable = true;
        hostName = cfg.hostName;
        package = cfg.package;
        plugins = cfg.plugins;
        dicts = cfg.dicts;
        maxAttachmentSize = cfg.maxAttachmentSize;
        configureNginx = true;
        extraConfig = roundcubeExtraConfig;
        database =
          {
            inherit (cfg.database) username dbname host;
          }
          // lib.optionalAttrs (cfg.database.passwordFile != null) {
            passwordFile = cfg.database.passwordFile;
          };
      };

      services.nginx.virtualHosts = lib.mkIf baseConfigReady {
        ${cfg.hostName} = {
          listen = [
            {
              addr = cfg.listenAddress;
              port = cfg.port;
              ssl = false;
            }
          ];
          forceSSL = lib.mkForce false;
          enableACME = lib.mkForce false;
          addSSL = lib.mkForce false;
        };
      };
    }

    (lib.mkIf (baseConfigReady && !clusterCfg.enable) (
      serviceExposure.mkConfig {
        inherit config endpoint exposeCfg;
        serviceName = "roundcube";
        serviceDescription = "Roundcube";
      }
    ))
  ]);
}
