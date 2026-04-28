{ config, lib, pkgs, ... }:
let
  cfg = config.alanix.mail;
  clusterCfg = cfg.cluster;

  hasValue = value: value != null && value != "";
  effectiveFqdn =
    if hasValue cfg.fqdn then
      cfg.fqdn
    else if hasValue cfg.domain then
      "mail.${cfg.domain}"
    else
      null;
  effectiveDomains = lib.unique (cfg.domains ++ lib.optional (hasValue cfg.domain) cfg.domain);
  effectiveAcmeCertificateName =
    if hasValue cfg.acme.certificateName then cfg.acme.certificateName else effectiveFqdn;

  normalizeAddress =
    name:
    if lib.hasInfix "@" name then
      name
    else if hasValue cfg.domain then
      "${name}@${cfg.domain}"
    else
      name;

  enabledAccounts = lib.filterAttrs (_: accountCfg: accountCfg.enable) cfg.accounts;
  loginAccounts =
    lib.mapAttrs'
      (name: accountCfg:
        let
          address = normalizeAddress name;
          passwordHashFile =
            if accountCfg.passwordHashSecret != null then
              config.sops.secrets.${accountCfg.passwordHashSecret}.path
            else
              accountCfg.hashedPasswordFile;
        in
        lib.nameValuePair address (
          {
            hashedPasswordFile = passwordHashFile;
            inherit (accountCfg)
              aliases
              aliasesRegexp
              catchAll
              quota
              sieveScript
              sendOnly
              sendOnlyRejectMessage
              ;
          }
        ))
      enabledAccounts;

  dkimKeyTarget = if clusterCfg.enable then "alanix-cluster-active.target" else "multi-user.target";
  dkimKeyServiceName = "alanix-mail-dkim-keys.service";
  dkimPrivateKeySecrets = cfg.dkim.privateKeySecrets;
  dkimPublicTxtRecords = cfg.dkim.publicTxtRecords;
  declarativeDkim = cfg.dkim.enable && dkimPrivateKeySecrets != { };
  servedDkimDomains = lib.unique (
    effectiveDomains ++ lib.optional (cfg.srs.enable && cfg.srs.domain != null) cfg.srs.domain
  );
  installDkimPrivateKeyCommands = lib.concatStringsSep "\n" (
    lib.mapAttrsToList
      (domain: secretName: ''
        install -o ${lib.escapeShellArg config.services.rspamd.user} -g ${lib.escapeShellArg config.services.rspamd.group} -m 0600 \
          ${lib.escapeShellArg config.sops.secrets.${secretName}.path} \
          ${lib.escapeShellArg "${cfg.dkim.keyDirectory}/${domain}.${cfg.dkim.selector}.key"}
      '')
      dkimPrivateKeySecrets
  );
  installDkimPublicTxtCommands = lib.concatStringsSep "\n" (
    lib.mapAttrsToList
      (domain: txtRecord: ''
        printf '%s\n' ${lib.escapeShellArg txtRecord} > ${lib.escapeShellArg "${cfg.dkim.keyDirectory}/${domain}.${cfg.dkim.selector}.txt"}
        chown ${lib.escapeShellArg config.services.rspamd.user}:${lib.escapeShellArg config.services.rspamd.group} \
          ${lib.escapeShellArg "${cfg.dkim.keyDirectory}/${domain}.${cfg.dkim.selector}.txt"}
        chmod 0644 ${lib.escapeShellArg "${cfg.dkim.keyDirectory}/${domain}.${cfg.dkim.selector}.txt"}
      '')
      dkimPublicTxtRecords
  );

  baseMailserverConfig =
    {
      enable = true;
      stateVersion = cfg.stateVersion;
      fqdn = effectiveFqdn;
      domains = effectiveDomains;
      loginAccounts = loginAccounts;
      extraVirtualAliases = cfg.extraVirtualAliases;
      forwards = cfg.forwards;
      rejectSender = cfg.rejectSender;
      rejectRecipients = cfg.rejectRecipients;
      openFirewall = cfg.openFirewall;

      inherit (cfg)
        certificateScheme
        enableImap
        enableImapSsl
        enableManageSieve
        enablePop3
        enablePop3Ssl
        enableSubmission
        enableSubmissionSsl
        localDnsResolver
        mailDirectory
        messageSizeLimit
        recipientDelimiter
        rewriteMessageId
        sieveDirectory
        systemName
        useFsLayout
        useUTF8FolderNames
        virusScanning
        ;

      dkimSigning = cfg.dkim.enable;
      dkimSelector = cfg.dkim.selector;
      dkimKeyDirectory = cfg.dkim.keyDirectory;
      dkimKeyType = cfg.dkim.keyType;
      dkimKeyBits = cfg.dkim.keyBits;

      fullTextSearch = cfg.fullTextSearch;
      dmarcReporting = cfg.dmarcReporting;
      srs =
        {
          enable = cfg.srs.enable;
        }
        // lib.optionalAttrs (cfg.srs.domain != null) {
          domain = cfg.srs.domain;
        };
      tlsrpt.enable = cfg.tlsrpt.enable;
    }
    // lib.optionalAttrs (cfg.indexDir != null) {
      indexDir = cfg.indexDir;
    }
    // lib.optionalAttrs (cfg.sendingFqdn != null) {
      sendingFqdn = cfg.sendingFqdn;
    }
    // lib.optionalAttrs (cfg.systemContact != null) {
      systemContact = cfg.systemContact;
    }
    // lib.optionalAttrs (cfg.systemDomain != null) {
      systemDomain = cfg.systemDomain;
    }
    // lib.optionalAttrs (cfg.certificateScheme == "acme") {
      acmeCertificateName = effectiveAcmeCertificateName;
    };
in
{
  options.alanix.mail = {
    enable = lib.mkEnableOption "nixos-mailserver through Alanix";

    domain = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Primary mail domain. When set, fqdn defaults to mail.<domain>.";
    };

    domains = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional domains served by the mail server.";
    };

    fqdn = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Fully qualified mail server name.";
    };

    sendingFqdn = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "FQDN used by outbound SMTP when identifying to remote servers.";
    };

    stateVersion = lib.mkOption {
      type = lib.types.ints.positive;
      default = 3;
      description = "nixos-mailserver state version.";
    };

    systemName = lib.mkOption {
      type = lib.types.str;
      default = "${if effectiveDomains == [ ] then "Alanix" else lib.head effectiveDomains} mail system";
      description = "Sender name for automated mail reports.";
    };

    systemDomain = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Primary domain used for automated reports.";
    };

    systemContact = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Administrative contact address used by optional reporting features.";
    };

    certificateScheme = lib.mkOption {
      type = lib.types.enum [ "manual" "selfsigned" "acme-nginx" "acme" ];
      default = "acme";
      description = "TLS certificate scheme passed to nixos-mailserver.";
    };

    acme = {
      certificateName = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "ACME certificate name when certificateScheme = acme.";
      };

      dnsProvider = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional ACME DNS provider for issuing the mail certificate.";
      };

      credentialsFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Optional ACME DNS provider credentials file.";
      };

      extraDomainNames = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Extra names included on the mail ACME certificate.";
      };
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Open public mail ports in the NixOS firewall.";
    };

    enableImap = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable IMAP with STARTTLS on port 143.";
    };

    enableImapSsl = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable IMAPS on port 993.";
    };

    enableSubmission = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable SMTP submission with STARTTLS on port 587.";
    };

    enableSubmissionSsl = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable SMTP submission over TLS on port 465.";
    };

    enablePop3 = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable POP3 with STARTTLS on port 110.";
    };

    enablePop3Ssl = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable POP3 over TLS on port 995.";
    };

    enableManageSieve = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable ManageSieve on port 4190.";
    };

    localDnsResolver = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable the local DNS resolver recommended by nixos-mailserver/rspamd.";
    };

    mailDirectory = lib.mkOption {
      type = lib.types.path;
      default = "/var/vmail";
      description = "Directory where mail is stored.";
    };

    sieveDirectory = lib.mkOption {
      type = lib.types.path;
      default = "/var/sieve";
      description = "Directory where Sieve scripts are stored.";
    };

    indexDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional separate Dovecot full text search index directory.";
    };

    messageSizeLimit = lib.mkOption {
      type = lib.types.int;
      default = 20971520;
      description = "Maximum accepted message size in bytes.";
    };

    recipientDelimiter = lib.mkOption {
      type = lib.types.str;
      default = "+";
      description = "Recipient delimiter for plus addressing.";
    };

    rewriteMessageId = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Rewrite Message-ID hostnames to the mailserver FQDN.";
    };

    useFsLayout = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Use Dovecot fs-layout maildirs.";
    };

    useUTF8FolderNames = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Store mailbox names using UTF-8.";
    };

    virusScanning = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable ClamAV virus scanning.";
    };

    accounts = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
        options = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Whether to create this login account.";
          };

          passwordHashSecret = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "SOPS secret containing the account password hash.";
          };

          hashedPasswordFile = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = "Path to a file containing the account password hash.";
          };

          aliases = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "Additional addresses that deliver to this account and may be used as senders.";
          };

          aliasesRegexp = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "Regular expression aliases for this account.";
          };

          catchAll = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "Domains for which this account receives catch-all mail.";
          };

          quota = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Optional per-user quota, such as 10G.";
          };

          sieveScript = lib.mkOption {
            type = lib.types.nullOr lib.types.lines;
            default = null;
            description = "Optional default Sieve script for this account.";
          };

          sendOnly = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Whether this account may only send mail.";
          };

          sendOnlyRejectMessage = lib.mkOption {
            type = lib.types.str;
            default = "This account cannot receive emails.";
            description = "SMTP rejection message for send-only accounts.";
          };
        };
      }));
      default = { };
      description = ''
        Declarative mail accounts. Attribute names may be complete email
        addresses or local parts when alanix.mail.domain is set.
      '';
    };

    extraVirtualAliases = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = "Extra nixos-mailserver virtual aliases.";
    };

    forwards = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = "Forward-only aliases.";
    };

    rejectSender = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Sender addresses or domains to reject.";
    };

    rejectRecipients = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Recipient addresses to reject.";
    };

    dkim = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable DKIM signing through rspamd.";
      };

      selector = lib.mkOption {
        type = lib.types.str;
        default = "mail";
        description = "DKIM selector.";
      };

      keyDirectory = lib.mkOption {
        type = lib.types.path;
        default = "/var/dkim";
        description = "Directory where DKIM keys are stored.";
      };

      keyType = lib.mkOption {
        type = lib.types.enum [ "rsa" "ed25519" ];
        default = "rsa";
        description = "DKIM key type.";
      };

      keyBits = lib.mkOption {
        type = lib.types.int;
        default = 2048;
        description = "RSA DKIM key size.";
      };

      privateKeySecrets = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = ''
          SOPS secrets containing pre-generated DKIM private keys, keyed by
          mail domain. Keys are installed to dkim.keyDirectory before rspamd starts.
        '';
      };

      publicTxtRecords = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = ''
          Public DKIM TXT record values, keyed by mail domain. These are written
          beside the private keys for operator inspection.
        '';
      };
    };

    fullTextSearch = {
      enable = lib.mkEnableOption "Dovecot full text search";
      memoryLimit = lib.mkOption {
        type = lib.types.nullOr lib.types.int;
        default = null;
      };
      autoIndex = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
      autoIndexExclude = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
      };
      enforced = lib.mkOption {
        type = lib.types.enum [ "yes" "no" "body" ];
        default = "no";
      };
      languages = lib.mkOption {
        type = lib.types.nonEmptyListOf lib.types.str;
        default = [ "en" ];
      };
      substringSearch = lib.mkOption {
        type = lib.types.bool;
        default = false;
      };
      headerExcludes = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "Received"
          "DKIM-*"
          "X-*"
          "Comments"
        ];
      };
      filters = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "normalizer-icu"
          "snowball"
          "stopwords"
        ];
      };
    };

    srs = {
      enable = lib.mkEnableOption "Sender Rewriting Scheme";
      domain = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional SRS domain.";
      };
    };

    dmarcReporting = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Send aggregate DMARC reports for incoming mail.";
      };

      excludeDomains = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Domains excluded from DMARC reports.";
      };
    };

    tlsrpt.enable = lib.mkEnableOption "SMTP TLS reporting";

    settings = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = "Additional raw nixos-mailserver options merged over Alanix defaults.";
    };

    cluster = {
      enable = lib.mkEnableOption "cluster-manage mail through alanix.cluster";

      backupDir = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Cluster backup staging directory. Required when cluster.enable = true.";
      };

      backupInterval = lib.mkOption {
        type = lib.types.str;
        default = "15m";
        description = "How often the active cluster node backs up mail state.";
      };

      maxBackupAge = lib.mkOption {
        type = lib.types.str;
        default = "1h";
        description = "Maximum backup age allowed for normal cluster promotion.";
      };

      includeRedis = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Include rspamd's local Redis state in cluster backups.";
      };

      includeRspamdState = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Include rspamd's state directory in cluster backups.";
      };

      includeIndexDir = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Include a separate Dovecot index directory in cluster backups.";
      };
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions =
        [
          {
            assertion = hasValue effectiveFqdn;
            message = "alanix.mail requires alanix.mail.fqdn or alanix.mail.domain.";
          }
          {
            assertion = effectiveDomains != [ ];
            message = "alanix.mail requires alanix.mail.domain or alanix.mail.domains.";
          }
          {
            assertion = cfg.accounts != { };
            message = "alanix.mail.accounts must define at least one account.";
          }
          {
            assertion = cfg.cluster.backupDir == null || lib.hasPrefix "/" cfg.cluster.backupDir;
            message = "alanix.mail.cluster.backupDir must be an absolute path when set.";
          }
          {
            assertion = !clusterCfg.enable || cfg.cluster.backupDir != null;
            message = "alanix.mail.cluster.enable requires alanix.mail.cluster.backupDir to be set.";
          }
          {
            assertion = cfg.indexDir == null || lib.hasPrefix "/" cfg.indexDir;
            message = "alanix.mail.indexDir must be an absolute path when set.";
          }
          {
            assertion = cfg.srs.domain == null || cfg.srs.enable;
            message = "alanix.mail.srs.domain requires alanix.mail.srs.enable = true.";
          }
        ]
        ++ lib.flatten (
          lib.mapAttrsToList
            (name: accountCfg: [
              {
                assertion =
                  (!accountCfg.enable)
                  || ((accountCfg.passwordHashSecret != null) != (accountCfg.hashedPasswordFile != null));
                message = "alanix.mail.accounts.${name} must set exactly one of passwordHashSecret or hashedPasswordFile.";
              }
              {
                assertion =
                  accountCfg.passwordHashSecret == null
                  || lib.hasAttrByPath [ "sops" "secrets" accountCfg.passwordHashSecret ] config;
                message = "alanix.mail.accounts.${name}.passwordHashSecret must reference a declared sops secret.";
              }
              {
                assertion =
                  lib.all (domain: builtins.elem domain effectiveDomains) accountCfg.catchAll;
                message = "alanix.mail.accounts.${name}.catchAll entries must be served mail domains.";
              }
            ])
            cfg.accounts
        )
        ++ lib.flatten (
          lib.mapAttrsToList
            (domain: secretName: [
              {
                assertion = builtins.elem domain servedDkimDomains;
                message = "alanix.mail.dkim.privateKeySecrets.${domain} must be a served DKIM domain.";
              }
              {
                assertion = lib.hasAttrByPath [ "sops" "secrets" secretName ] config;
                message = "alanix.mail.dkim.privateKeySecrets.${domain} must reference a declared sops secret.";
              }
            ])
            dkimPrivateKeySecrets
        )
        ++ lib.flatten (
          lib.mapAttrsToList
            (domain: _: [
              {
                assertion = builtins.elem domain servedDkimDomains;
                message = "alanix.mail.dkim.publicTxtRecords.${domain} must be a served DKIM domain.";
              }
            ])
            dkimPublicTxtRecords
        );

      mailserver = lib.recursiveUpdate baseMailserverConfig cfg.settings;

      systemd.services.alanix-mail-dkim-keys = lib.mkIf declarativeDkim {
        description = "Install declarative DKIM keys for Alanix mail";
        wantedBy = [ dkimKeyTarget ];
        partOf = lib.optional clusterCfg.enable dkimKeyTarget;
        before = [ "rspamd.service" ];
        path = [ pkgs.coreutils ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          set -euo pipefail

          install -d -o ${lib.escapeShellArg config.services.rspamd.user} -g ${lib.escapeShellArg config.services.rspamd.group} -m 0750 \
            ${lib.escapeShellArg cfg.dkim.keyDirectory}

          ${installDkimPrivateKeyCommands}
          ${installDkimPublicTxtCommands}
        '';
      };

      systemd.services.rspamd = lib.mkIf declarativeDkim {
        requires = [ dkimKeyServiceName ];
        after = [ dkimKeyServiceName ];
      };

      security.acme.acceptTerms = lib.mkIf (cfg.certificateScheme == "acme") (lib.mkDefault true);
      security.acme.certs = lib.mkIf (cfg.certificateScheme == "acme" && hasValue effectiveAcmeCertificateName) {
        "${effectiveAcmeCertificateName}" =
          {
            extraDomainNames = cfg.acme.extraDomainNames;
          }
          // lib.optionalAttrs (cfg.acme.dnsProvider != null) {
            dnsProvider = cfg.acme.dnsProvider;
          }
          // lib.optionalAttrs (cfg.acme.credentialsFile != null) {
            credentialsFile = cfg.acme.credentialsFile;
          };
      };
    }
  ]);
}
