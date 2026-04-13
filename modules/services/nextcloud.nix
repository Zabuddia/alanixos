{ config, lib, pkgs, ... }:
let
  cfg = config.alanix.nextcloud;
  clusterCfg = cfg.cluster;
  serviceExposure = import ../../lib/mkServiceExposure.nix { inherit lib pkgs; };
  passwordUsers = import ../../lib/mkPlaintextPasswordUsers.nix { inherit lib; };

  inherit (passwordUsers) hasValue;

  exposeCfg = cfg.expose;
  collaboraCfg = cfg.collabora;
  collaboraExposeCfg = collaboraCfg.expose;

  defaultAppIds = [
    "contacts"
    "calendar"
    "tasks"
    "notes"
    "deck"
    "forms"
    "richdocuments"
    "polls"
  ];

  sanitizeUserKey = name: lib.replaceStrings [ "-" "." "@" "+" ] [ "_" "_" "_" "_" ] name;

  normalizeInternalAddress =
    address:
    if address == "0.0.0.0" then
      "127.0.0.1"
    else if address == "::" then
      "::1"
    else
      address;

  urlHostLiteral =
    host:
    if lib.hasPrefix "[" host && lib.hasSuffix "]" host then
      host
    else if lib.hasInfix ":" host then
      "[${host}]"
    else
      host;

  mkOriginUrl =
    {
      scheme,
      host,
      port ? null,
    }:
    let
      defaultPort = if scheme == "https" then 443 else 80;
      portSuffix = if port == null || port == defaultPort then "" else ":${toString port}";
    in
    "${scheme}://${urlHostLiteral host}${portSuffix}";

  urlMatch = url: if url == null then null else builtins.match "^(https?)://([^/]+)/?$" url;

  urlScheme =
    url:
    let
      match = urlMatch url;
    in
    if match == null then null else builtins.elemAt match 0;

  urlAuthority =
    url:
    let
      match = urlMatch url;
    in
    if match == null then null else builtins.elemAt match 1;

  authorityHost =
    authority:
    if lib.hasPrefix "[" authority then
      let
        remainder = builtins.substring 1 ((builtins.stringLength authority) - 1) authority;
        parts = lib.splitString "]" remainder;
      in
      if parts == [ ] then null else builtins.head parts
    else
      let
        parts = lib.splitString ":" authority;
      in
      if parts == [ ] then null else builtins.head parts;

  urlHost =
    url:
    let
      authority = urlAuthority url;
    in
    if authority == null then null else authorityHost authority;

  normalizeBaseUrl = url: if url == null then null else lib.removeSuffix "/" url;
  ensureBaseUrl = url: if url == null then null else "${normalizeBaseUrl url}/";
  isOnionHost = host: host != null && lib.hasSuffix ".onion" host;

  uniqueValues = values: lib.unique (lib.filter hasValue values);

  tailscaleHosts =
    backendCfg:
    uniqueValues [
      (if backendCfg.tailscale.tls then backendCfg.tailscale.tlsName else null)
      (
        if backendCfg.tailscale.address != null && !(builtins.elem backendCfg.tailscale.address [ "0.0.0.0" "::" ]) then
          backendCfg.tailscale.address
        else
          null
      )
    ];

  wireguardAddress =
    backendCfg:
    if backendCfg.wireguard.address != null then
      backendCfg.wireguard.address
    else
      config.alanix.wireguard.vpnIP;

  wireguardHosts =
    backendCfg:
    uniqueValues [
      (if backendCfg.wireguard.tls then backendCfg.wireguard.tlsName else null)
      (
        if wireguardAddress backendCfg != null && !(builtins.elem (wireguardAddress backendCfg) [ "0.0.0.0" "::" ]) then
          wireguardAddress backendCfg
        else
          null
      )
    ];

  nextcloudInternalAddress = normalizeInternalAddress cfg.listenAddress;
  nextcloudInternalUrlBase =
    if hasValue nextcloudInternalAddress && cfg.port != null then
      mkOriginUrl {
        scheme = "http";
        host = nextcloudInternalAddress;
        port = cfg.port;
      }
    else
      null;

  nextcloudPublicUrlBase = normalizeBaseUrl cfg.rootUrl;

  nextcloudPublicUrl = ensureBaseUrl nextcloudPublicUrlBase;

  nextcloudExposedUrlBases = lib.unique (
    lib.concatLists [
      (lib.optionals (exposeCfg.wan.enable && hasValue exposeCfg.wan.domain) [
        (mkOriginUrl {
          scheme = if exposeCfg.wan.tls then "https" else "http";
          host = exposeCfg.wan.domain;
          port =
            if exposeCfg.wan.port != null then
              exposeCfg.wan.port
            else if exposeCfg.wan.tls then
              443
            else
              80;
        })
      ])
      (lib.optionals exposeCfg.wireguard.enable (
        builtins.map
          (
            host:
            mkOriginUrl {
              scheme = if exposeCfg.wireguard.tls then "https" else "http";
              inherit host;
              port = exposeCfg.wireguard.port;
            }
          )
          (wireguardHosts exposeCfg)
      ))
      (lib.optionals exposeCfg.tailscale.enable (
        builtins.map
          (
            host:
            mkOriginUrl {
              scheme = if exposeCfg.tailscale.tls then "https" else "http";
              inherit host;
              port = exposeCfg.tailscale.port;
            }
          )
          (tailscaleHosts exposeCfg)
      ))
      (lib.optionals (exposeCfg.tor.enable && exposeCfg.tor.tls && exposeCfg.tor.tlsName != null) [
        (mkOriginUrl {
          scheme = "https";
          host = exposeCfg.tor.tlsName;
          port = exposeCfg.tor.publicPort;
        })
      ])
    ]
  );

  nextcloudBrowserUrlBases = lib.unique (lib.filter hasValue ([ nextcloudPublicUrlBase ] ++ nextcloudExposedUrlBases));

  collaboraPublicUrlBase = normalizeBaseUrl collaboraCfg.rootUrl;

  collaboraPublicUrl = ensureBaseUrl collaboraPublicUrlBase;

  configuredCollaboraCallbackUrlBase = normalizeBaseUrl collaboraCfg.callbackUrl;

  collaboraLocalNextcloudUrlBase = nextcloudInternalUrlBase;

  collaboraServerReachableNextcloudUrlBases = lib.unique (
    lib.filter hasValue (
      [
        (
          if exposeCfg.wireguard.enable then
            mkOriginUrl {
              scheme = if exposeCfg.wireguard.tls then "https" else "http";
              host = wireguardAddress exposeCfg;
              port = exposeCfg.wireguard.port;
            }
          else
            null
        )
        (
          if exposeCfg.tailscale.enable then
            let
              hosts = tailscaleHosts exposeCfg;
            in
            if hosts == [ ] then
              null
            else
              mkOriginUrl {
                scheme = if exposeCfg.tailscale.tls then "https" else "http";
                host = builtins.head hosts;
                port = exposeCfg.tailscale.port;
              }
          else
            null
        )
        (
          if exposeCfg.wan.enable && hasValue exposeCfg.wan.domain then
            mkOriginUrl {
              scheme = if exposeCfg.wan.tls then "https" else "http";
              host = exposeCfg.wan.domain;
              port =
                if exposeCfg.wan.port != null then
                  exposeCfg.wan.port
                else if exposeCfg.wan.tls then
                  443
                else
                  80;
            }
          else
            null
        )
        collaboraLocalNextcloudUrlBase
      ]
    )
  );

  defaultCollaboraCallbackUrlBase =
    if exposeCfg.tor.enable || (nextcloudPublicUrlBase != null && isOnionHost (urlHost nextcloudPublicUrlBase)) then
      if collaboraServerReachableNextcloudUrlBases == [ ] then null else builtins.head collaboraServerReachableNextcloudUrlBases
    else
      null;

  collaboraCallbackUrlBase =
    if configuredCollaboraCallbackUrlBase != null then
      configuredCollaboraCallbackUrlBase
    else
      defaultCollaboraCallbackUrlBase;

  collaboraAllowedNextcloudUrlBases = lib.unique (
    lib.filter hasValue (
      [
        nextcloudPublicUrlBase
        configuredCollaboraCallbackUrlBase
        defaultCollaboraCallbackUrlBase
        collaboraLocalNextcloudUrlBase
      ]
      ++ nextcloudExposedUrlBases
    )
  );

  collaboraPrimaryNextcloudUrlBase =
    if collaboraAllowedNextcloudUrlBases == [ ] then null else builtins.head collaboraAllowedNextcloudUrlBases;

  collaboraInternalUrlBase =
    mkOriginUrl {
      scheme = "http";
      host = "127.0.0.1";
      port = collaboraCfg.port;
    };

  addressesCollide =
    a: b:
    a == b
    || builtins.elem a [ "0.0.0.0" "::" ]
    || builtins.elem b [ "0.0.0.0" "::" ];

  effectiveHostName = urlHost nextcloudPublicUrlBase;

  trustedDomainCandidates =
    lib.filter hasValue (
      [
        effectiveHostName
        (urlHost nextcloudPublicUrlBase)
        exposeCfg.wan.domain
        (if exposeCfg.tor.enable && exposeCfg.tor.tls then exposeCfg.tor.tlsName else null)
        nextcloudInternalAddress
        (if collaboraCfg.enable then urlHost collaboraLocalNextcloudUrlBase else null)
        (if collaboraCfg.enable then urlHost configuredCollaboraCallbackUrlBase else null)
      ]
      ++ wireguardHosts exposeCfg
      ++ tailscaleHosts exposeCfg
      ++ cfg.trustedDomains
    );

  trustedDomains = lib.unique trustedDomainCandidates;

  nextcloudServerAliases = lib.filter (domain: domain != effectiveHostName) trustedDomains;

  endpoint = {
    address = cfg.listenAddress;
    port = cfg.port;
    protocol = "http";
  };

  collaboraEndpoint = {
    address = "127.0.0.1";
    port = collaboraCfg.port;
    protocol = "http";
  };

  baseConfigReady = hasValue cfg.listenAddress && cfg.port != null;
  richdocumentsCanonicalWebroot =
    if lib.length nextcloudBrowserUrlBases <= 1 then
      nextcloudPublicUrlBase
    else
      null;
  nextcloudTorHostnameFiles =
    lib.optionals (baseConfigReady && exposeCfg.tor.enable && !exposeCfg.tor.tls) [
      (
        if clusterCfg.enable then
          "/var/lib/alanix-cluster/tor-hostnames/nextcloud"
        else
          "${config.services.tor.relay.onionServices.${exposeCfg.tor.onionServiceName}.path}/hostname"
      )
    ];

  declaredUsernames = builtins.attrNames cfg.users;
  declaredUsersList = lib.concatStringsSep " " declaredUsernames;
  adminUsernames = lib.filter (uname: cfg.users.${uname}.admin) declaredUsernames;

  appPackageSet = lib.attrByPath [ "passthru" "packages" "apps" ] { } cfg.package;
  packagedAppIds = lib.unique cfg.appIds;
  missingAppIds = lib.filter (appId: !(builtins.hasAttr appId appPackageSet)) packagedAppIds;
  packagedApps = lib.genAttrs (lib.filter (appId: builtins.hasAttr appId appPackageSet) packagedAppIds) (appId: appPackageSet.${appId});
  extraApps = packagedApps // cfg.extraApps;

  userRestartData = pkgs.writeText "alanix-nextcloud-users.json" (
    builtins.toJSON (
      passwordUsers.sanitizeForRestart {
        users = cfg.users;
        inheritFields = [
          "admin"
          "displayName"
          "email"
          "enabled"
          "groups"
          "passwordSecret"
          "quota"
        ];
      }
    )
  );

  appRestartData = pkgs.writeText "alanix-nextcloud-apps.json" (
    builtins.toJSON {
      appIds = packagedAppIds;
      extraApps = builtins.attrNames cfg.extraApps;
      appstoreEnable = cfg.appstoreEnable;
    }
  );

  collaboraRestartData = pkgs.writeText "alanix-nextcloud-collabora.json" (
    builtins.toJSON {
      enable = collaboraCfg.enable;
      port = collaboraCfg.port;
      rootUrl = collaboraCfg.rootUrl;
      callbackUrl = collaboraCfg.callbackUrl;
      disableCertificateVerification = collaboraCfg.disableCertificateVerification;
    }
  );

  defaultSettings =
    {
      trusted_domains = lib.filter (domain: domain != effectiveHostName) trustedDomains;
      trusted_proxies = [ "127.0.0.1" "::1" ];
    }
    // lib.optionalAttrs (nextcloudPublicUrl != null) {
      "overwrite.cli.url" = nextcloudPublicUrl;
    };

  defaultCollaboraSettings =
    {
      net = {
        listen = "loopback";
        proto = "IPv4";
      };

      server_name = lib.mkDefault (urlAuthority collaboraPublicUrlBase);

      ssl = {
        enable = false;
        termination = (urlScheme collaboraPublicUrlBase) == "https";
      };

      storage.wopi."@allow" = true;
    };

  nextcloudVhostName = effectiveHostName;

  desiredOverwriteHost = lib.attrByPath [ "overwritehost" ] null cfg.settings;
  desiredOverwriteProtocol = lib.attrByPath [ "overwriteprotocol" ] null cfg.settings;
  desiredOverwriteCondAddr = lib.attrByPath [ "overwritecondaddr" ] null cfg.settings;
  desiredOverwriteWebroot = lib.attrByPath [ "overwritewebroot" ] null cfg.settings;
in
{
  options.alanix.nextcloud = {
    enable = lib.mkEnableOption "Nextcloud (Alanix)";

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
      default = "/var/lib/nextcloud";
      description = "State directory used for Nextcloud config and runtime state.";
    };

    dataDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional override for Nextcloud's data directory. Defaults to alanix.nextcloud.stateDir.";
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.nextcloud32;
      description = "Nextcloud package to use for the Alanix Nextcloud instance.";
    };

    backupDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional Nextcloud cluster backup staging directory.";
    };

    cluster = {
      enable = lib.mkEnableOption "cluster-manage Nextcloud through alanix.cluster";

      backupInterval = lib.mkOption {
        type = lib.types.str;
        default = "15m";
      };

      maxBackupAge = lib.mkOption {
        type = lib.types.str;
        default = "1h";
      };
    };

    rootUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Required when enabled. Preferred public Nextcloud origin URL, including http:// or https:// and no base path.
        This is used for CLI/background-generated URLs and related integration defaults, but incoming browser requests are allowed to stay on any trusted exposed host.
      '';
    };

    trustedDomains = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional Nextcloud trusted domains or IPs.";
    };

    appIds = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = defaultAppIds;
      description = "Packaged Nextcloud app ids installed from cfg.package.passthru.packages.apps.";
    };

    extraApps = lib.mkOption {
      type = lib.types.attrsOf lib.types.package;
      default = { };
      description = "Additional packaged Nextcloud apps merged on top of alanix.nextcloud.appIds.";
    };

    appstoreEnable = lib.mkOption {
      type = lib.types.nullOr lib.types.bool;
      default = null;
      description = "Optional override for services.nextcloud.appstoreEnable.";
    };

    settings = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = "Extra services.nextcloud.settings merged on top of the Alanix defaults.";
    };

    pruneUndeclaredUsers = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Delete Nextcloud users that are not present in alanix.nextcloud.users.";
    };

    users = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule ({ name, ... }: {
          options = passwordUsers.mkOptions {
            extraOptions = {
              admin = lib.mkOption {
                type = lib.types.bool;
                default = false;
              };

              displayName = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = "Display name shown in Nextcloud. Defaults to the username when omitted.";
              };

              email = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = "Optional email address for the Nextcloud user.";
              };

              enabled = lib.mkOption {
                type = lib.types.bool;
                default = true;
              };

              groups = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ ];
                description = "Additional Nextcloud groups the user should belong to.";
              };

              quota = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = "Optional Nextcloud quota string, for example 10 GB.";
              };
            };
          };
        })
      );
      default = { };
      description = "Declarative Nextcloud users.";
    };

    collabora = {
      enable = lib.mkEnableOption "local Collabora Online integration for Nextcloud Office";

      port = lib.mkOption {
        type = lib.types.port;
        default = 9980;
      };

      rootUrl = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Required when enabled. Public Collabora origin URL for browsers, including http:// or https:// and no base path.";
      };

      callbackUrl = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional Nextcloud origin URL Collabora should call back to. Defaults to the local Nextcloud listener.";
      };

      disableCertificateVerification = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether Nextcloud Office should disable certificate verification for Collabora.";
      };

      settings = lib.mkOption {
        type = lib.types.attrs;
        default = { };
        description = "Extra services.collabora-online.settings merged on top of the Alanix defaults.";
      };

      extraArgs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Extra arguments passed through to services.collabora-online.extraArgs.";
      };

      expose = serviceExposure.mkOptions {
        serviceName = "nextcloud-collabora";
        serviceDescription = "Nextcloud Collabora";
        defaultPublicPort = 9980;
      };
    };

    expose = serviceExposure.mkOptions {
      serviceName = "nextcloud";
      serviceDescription = "Nextcloud";
      defaultPublicPort = 80;
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      warnings = lib.optionals (collaboraCfg.enable && lib.length nextcloudBrowserUrlBases > 1) [
        ''
          alanix.nextcloud: Nextcloud is exposed on multiple public origins, but Collabora still uses one browser-facing origin at ${collaboraPublicUrlBase}.
          General Nextcloud access is multi-origin, but Office editing will only work for clients that can reach that Collabora URL.
        ''
      ];

      assertions =
        [
          {
            assertion = cfg.users != { };
            message = "alanix.nextcloud: users must not be empty when enable = true.";
          }
          {
            assertion = adminUsernames != [ ];
            message = "alanix.nextcloud: at least one declared user must have admin = true.";
          }
          {
            assertion = hasValue cfg.listenAddress;
            message = "alanix.nextcloud.listenAddress must be set when alanix.nextcloud.enable = true.";
          }
          {
            assertion = cfg.port != null;
            message = "alanix.nextcloud.port must be set when alanix.nextcloud.enable = true.";
          }
          {
            assertion = lib.hasPrefix "/" cfg.stateDir;
            message = "alanix.nextcloud.stateDir must be an absolute path.";
          }
          {
            assertion = cfg.dataDir == null || lib.hasPrefix "/" cfg.dataDir;
            message = "alanix.nextcloud.dataDir must be an absolute path when set.";
          }
          {
            assertion = cfg.backupDir == null || lib.hasPrefix "/" cfg.backupDir;
            message = "alanix.nextcloud.backupDir must be an absolute path when set.";
          }
          {
            assertion = lib.versionAtLeast cfg.package.version "32.0.0";
            message = "alanix.nextcloud currently requires Nextcloud >= 32.0.0 for declarative bootstrapping without an initial admin user.";
          }
          {
            assertion = cfg.rootUrl != null;
            message = "alanix.nextcloud.rootUrl must be set when alanix.nextcloud.enable = true.";
          }
          {
            assertion = builtins.match "^https?://[^/]+/?$" cfg.rootUrl != null;
            message = "alanix.nextcloud.rootUrl must be an origin URL like https://nextcloud.example.com with no base path.";
          }
          {
            assertion = missingAppIds == [ ];
            message = "alanix.nextcloud.appIds contains packaged app ids not present in alanix.nextcloud.package.passthru.packages.apps: ${lib.concatStringsSep ", " missingAppIds}";
          }
          {
            assertion = !collaboraCfg.enable || builtins.elem "richdocuments" packagedAppIds;
            message = "alanix.nextcloud.collabora.enable requires richdocuments to be present in alanix.nextcloud.appIds.";
          }
          {
            assertion = !collaboraCfg.enable || collaboraCfg.rootUrl != null;
            message = "alanix.nextcloud.collabora.rootUrl must be set when alanix.nextcloud.collabora.enable = true.";
          }
          {
            assertion = !collaboraCfg.enable || builtins.match "^https?://[^/]+/?$" collaboraCfg.rootUrl != null;
            message = "alanix.nextcloud.collabora.rootUrl must be an origin URL like https://office.example.com with no base path.";
          }
          {
            assertion = !collaboraCfg.enable || collaboraCfg.callbackUrl == null || builtins.match "^https?://[^/]+/?$" collaboraCfg.callbackUrl != null;
            message = "alanix.nextcloud.collabora.callbackUrl must be an origin URL like https://nextcloud.example.com with no base path.";
          }
          {
            assertion =
              !collaboraCfg.enable
              || cfg.port != collaboraCfg.port
              || !(addressesCollide cfg.listenAddress "127.0.0.1");
            message = "alanix.nextcloud.collabora.port must not collide with the local Nextcloud listener.";
          }
          {
            assertion = !clusterCfg.enable || cfg.backupDir != null;
            message = "alanix.nextcloud.cluster.enable requires alanix.nextcloud.backupDir to be set.";
          }
        ]
        ++ serviceExposure.mkAssertions {
          inherit config endpoint exposeCfg;
          optionPrefix = "alanix.nextcloud.expose";
        }
        ++ lib.optionals collaboraCfg.enable (
          serviceExposure.mkAssertions {
            config = config;
            endpoint = collaboraEndpoint;
            exposeCfg = collaboraExposeCfg;
            optionPrefix = "alanix.nextcloud.collabora.expose";
          }
        )
        ++ passwordUsers.mkAssertions {
          inherit config;
          users = cfg.users;
          usernamePattern = "^[A-Za-z0-9_@-]+$";
          usernameMessage = uname: "alanix.nextcloud.users.${uname}: usernames may contain only letters, digits, underscore, hyphen, and @.";
          passwordSourceMessage = uname: "alanix.nextcloud.users.${uname}: set exactly one of password, passwordFile, or passwordSecret.";
          passwordSecretMessage = uname: "alanix.nextcloud.users.${uname}.passwordSecret must reference a declared sops secret.";
        };

      services.nextcloud = lib.mkIf (baseConfigReady && nextcloudVhostName != null) {
        enable = true;
        package = cfg.package;
        home = cfg.stateDir;
        datadir = if cfg.dataDir != null then cfg.dataDir else cfg.stateDir;
        hostName = nextcloudVhostName;
        https = (urlScheme nextcloudPublicUrlBase) == "https";
        configureRedis = true;
        database.createLocally = true;
        config = {
          adminuser = null;
          adminpassFile = null;
          dbtype = "pgsql";
          dbname = "nextcloud";
          dbuser = "nextcloud";
        };
        appstoreEnable = cfg.appstoreEnable;
        extraApps = extraApps;
        extraAppsEnable = true;
        settings = lib.recursiveUpdate defaultSettings cfg.settings;
      };

      services.nginx.virtualHosts = lib.mkIf (baseConfigReady && nextcloudVhostName != null) {
        ${nextcloudVhostName} = {
          listen = [
            {
              addr = cfg.listenAddress;
              port = cfg.port;
            }
          ];
          serverAliases = nextcloudServerAliases;
          locations."~ \\.php(?:$|/)".extraConfig = lib.mkAfter ''
            # Preserve the caller's host so multi-origin access does not collapse
            # back to the rootUrl host inside Nextcloud's request handling.
            fastcgi_param HTTP_HOST $http_host;
            fastcgi_param SERVER_NAME $host;
          '';
        };
      };

      services.collabora-online = lib.mkIf (collaboraCfg.enable && baseConfigReady) {
        enable = true;
        port = collaboraCfg.port;
        extraArgs = collaboraCfg.extraArgs;
        aliasGroups = [
          {
            host = collaboraPrimaryNextcloudUrlBase;
            aliases =
              lib.filter
                (alias: alias != collaboraPrimaryNextcloudUrlBase)
                collaboraAllowedNextcloudUrlBases;
          }
        ];
        settings = lib.recursiveUpdate defaultCollaboraSettings collaboraCfg.settings;
      };

      systemd.services.nextcloud-reconcile = lib.mkIf baseConfigReady {
        description = "Reconcile Nextcloud users and optional office integration";
        wantedBy = [ "multi-user.target" ];
        wants =
          [ "nextcloud-setup.service" "sops-nix.service" ]
          ++ lib.optionals (exposeCfg.tor.enable && !exposeCfg.tor.tls) [ "tor.service" ]
          ++ lib.optionals collaboraCfg.enable [ "coolwsd.service" ];
        after =
          [ "nextcloud-setup.service" "sops-nix.service" ]
          ++ lib.optionals (exposeCfg.tor.enable && !exposeCfg.tor.tls) [ "tor.service" ]
          ++ lib.optionals collaboraCfg.enable [ "coolwsd.service" ];
        partOf = lib.optionals collaboraCfg.enable [ "coolwsd.service" ];

        serviceConfig = {
          Type = "oneshot";
          RuntimeDirectory = "alanix-nextcloud";
          RuntimeDirectoryMode = "0700";
          UMask = "0077";
        };

        path = [
          pkgs.coreutils
          pkgs.gawk
          pkgs.gnugrep
          pkgs.jq
        ];

        restartTriggers = [
          userRestartData
          appRestartData
          collaboraRestartData
        ];

        script =
          let
            passfileLines =
              lib.concatStringsSep "\n"
                (lib.mapAttrsToList
                  (uname: u:
                    let
                      var = "PASSFILE_" + sanitizeUserKey uname;
                      runtimePassfile = "$RUNTIME_DIRECTORY/${sanitizeUserKey uname}.pass";
                    in
                    if u.passwordFile != null then
                      ''${var}=${lib.escapeShellArg (toString u.passwordFile)}''
                    else if u.passwordSecret != null then
                      ''${var}=${lib.escapeShellArg config.sops.secrets.${u.passwordSecret}.path}''
                    else
                      ''${var}=${lib.escapeShellArg runtimePassfile}; ensure_runtime_passfile "${"$"}${var}" ${lib.escapeShellArg u.password}'')
                  cfg.users);

            ensureLines =
              lib.concatStringsSep "\n"
                (lib.mapAttrsToList
                  (uname: u:
                    let
                      var = "PASSFILE_" + sanitizeUserKey uname;
                      adminFlag = if u.admin then "1" else "0";
                      enabledFlag = if u.enabled then "1" else "0";
                      displayName = if u.displayName != null then u.displayName else uname;
                      email = if u.email != null then u.email else "";
                      quota = if u.quota != null then u.quota else "";
                    in
                    ''ensure_user ${lib.escapeShellArg uname} "${"$"}${var}" ${adminFlag} ${enabledFlag} ${lib.escapeShellArg displayName} ${lib.escapeShellArg email} ${lib.escapeShellArg quota} ${lib.escapeShellArg (builtins.toJSON (lib.filter (group: group != "admin") (lib.unique u.groups)))}'')
                  cfg.users);
          in
          ''
            set -euo pipefail

            OCC=/run/current-system/sw/bin/nextcloud-occ
            DECLARED=${lib.escapeShellArg declaredUsersList}
            PRUNE=${if cfg.pruneUndeclaredUsers then "1" else "0"}
            COLLABORA_ENABLE=${if collaboraCfg.enable then "1" else "0"}
            COLLABORA_INTERNAL_URL=${lib.escapeShellArg collaboraInternalUrlBase}
            COLLABORA_CALLBACK_URL=${lib.escapeShellArg (if collaboraCallbackUrlBase != null then collaboraCallbackUrlBase else "")}
            COLLABORA_DISABLE_VERIFY=${if collaboraCfg.disableCertificateVerification then "1" else "0"}
            STATIC_TRUSTED_DOMAINS_JSON=${lib.escapeShellArg (builtins.toJSON trustedDomains)}
            NEXTCLOUD_TOR_HOSTNAME_FILES=${lib.escapeShellArg (lib.concatStringsSep "\n" nextcloudTorHostnameFiles)}
            NEXTCLOUD_PUBLIC_URL=${lib.escapeShellArg (if nextcloudPublicUrlBase != null then nextcloudPublicUrlBase else "")}
            RICHDOCUMENTS_CANONICAL_WEBROOT=${lib.escapeShellArg (if richdocumentsCanonicalWebroot != null then richdocumentsCanonicalWebroot else "")}
            DESIRED_OVERWRITEHOST=${lib.escapeShellArg (if desiredOverwriteHost != null then toString desiredOverwriteHost else "")}
            DESIRED_OVERWRITEPROTOCOL=${lib.escapeShellArg (if desiredOverwriteProtocol != null then toString desiredOverwriteProtocol else "")}
            DESIRED_OVERWRITECONDADDR=${lib.escapeShellArg (if desiredOverwriteCondAddr != null then toString desiredOverwriteCondAddr else "")}
            DESIRED_OVERWRITEWEBROOT=${lib.escapeShellArg (if desiredOverwriteWebroot != null then toString desiredOverwriteWebroot else "")}
            PASSWORD_DIGESTS_FILE=${lib.escapeShellArg "${cfg.stateDir}/alanix-password-digests.json"}

            ensure_runtime_passfile() {
              local path="$1"
              local value="$2"
              umask 077
              printf '%s' "$value" > "$path"
            }

            render_trusted_domains_json() {
              local trusted_domains_json="$STATIC_TRUSTED_DOMAINS_JSON"
              local hostname_file
              local tor_host

              while IFS= read -r hostname_file; do
                [ -n "$hostname_file" ] || continue

                if [ -r "$hostname_file" ]; then
                  tor_host="$(tr -d '\r\n' < "$hostname_file")"
                  if [ -n "$tor_host" ]; then
                    trusted_domains_json="$(jq -cn \
                      --argjson base "$trusted_domains_json" \
                      --arg host "$tor_host" \
                      '$base + [$host] | map(select(. != "")) | unique'
                    )"
                  fi
                fi
              done < <(printf '%s\n' "$NEXTCLOUD_TOR_HOSTNAME_FILES")

              printf '%s\n' "$trusted_domains_json"
            }

            sync_trusted_domains() {
              local trusted_domains_json

              trusted_domains_json="$(render_trusted_domains_json)"
              "$OCC" config:system:set trusted_domains --type json --value="$trusted_domains_json" >/dev/null
            }

            sync_optional_system_value() {
              local key="$1"
              local value="$2"

              if [ -n "$value" ]; then
                "$OCC" config:system:set "$key" --value="$value" >/dev/null
              else
                "$OCC" config:system:delete "$key" >/dev/null 2>&1 || true
              fi
            }

            sync_overwrite_settings() {
              sync_optional_system_value overwritehost "$DESIRED_OVERWRITEHOST"
              sync_optional_system_value overwriteprotocol "$DESIRED_OVERWRITEPROTOCOL"
              sync_optional_system_value overwritecondaddr "$DESIRED_OVERWRITECONDADDR"
              sync_optional_system_value overwritewebroot "$DESIRED_OVERWRITEWEBROOT"
            }

            password_digest() {
              local passfile="$1"
              sha256sum "$passfile" | awk '{print $1}'
            }

            current_password_digest() {
              local name="$1"

              if [ ! -r "$PASSWORD_DIGESTS_FILE" ]; then
                return 0
              fi

              jq -r --arg user "$name" '.[$user] // empty' "$PASSWORD_DIGESTS_FILE"
            }

            write_password_digest() {
              local name="$1"
              local digest="$2"
              local tmp

              tmp="$(mktemp "$RUNTIME_DIRECTORY/password-digests.XXXXXX")"
              if [ -r "$PASSWORD_DIGESTS_FILE" ]; then
                jq -c --arg user "$name" --arg digest "$digest" '. + {($user): $digest}' "$PASSWORD_DIGESTS_FILE" > "$tmp"
              else
                jq -cn --arg user "$name" --arg digest "$digest" '{($user): $digest}' > "$tmp"
              fi

              install -m 600 "$tmp" "$PASSWORD_DIGESTS_FILE"
              rm -f "$tmp"
            }

            delete_password_digest() {
              local name="$1"
              local tmp

              if [ ! -r "$PASSWORD_DIGESTS_FILE" ]; then
                return 0
              fi

              tmp="$(mktemp "$RUNTIME_DIRECTORY/password-digests.XXXXXX")"
              jq -c --arg user "$name" 'del(.[$user])' "$PASSWORD_DIGESTS_FILE" > "$tmp"
              install -m 600 "$tmp" "$PASSWORD_DIGESTS_FILE"
              rm -f "$tmp"
            }

            nextcloud_users_json() {
              "$OCC" user:list --output=json --info
            }

            have_user() {
              nextcloud_users_json | jq -e --arg user "$1" 'type == "object" and has($user)' >/dev/null
            }

            have_group() {
              "$OCC" group:info "$1" >/dev/null 2>&1
            }

            ensure_group() {
              local name="$1"
              if ! have_group "$name"; then
                "$OCC" group:add "$name" >/dev/null
              fi
            }

            current_display_name() {
              nextcloud_users_json | jq -r --arg user "$1" '.[$user].display_name // empty'
            }

            current_enabled() {
              nextcloud_users_json | jq -r --arg user "$1" '.[$user].enabled // false'
            }

            current_groups_json() {
              nextcloud_users_json | jq -c --arg user "$1" '.[$user].groups // []'
            }

            set_email() {
              local name="$1"
              local email="$2"

              if [ -n "$email" ]; then
                "$OCC" user:setting "$name" settings email "$email" >/dev/null
              else
                "$OCC" user:setting "$name" settings email --delete >/dev/null 2>&1 || true
              fi
            }

            set_quota() {
              local name="$1"
              local quota="$2"

              if [ -n "$quota" ]; then
                "$OCC" user:setting "$name" files quota "$quota" >/dev/null
              else
                "$OCC" user:setting "$name" files quota --delete >/dev/null 2>&1 || true
              fi
            }

            set_display_name() {
              local name="$1"
              local display_name="$2"
              local current

              current="$(current_display_name "$name")"
              if [ "$current" != "$display_name" ]; then
                "$OCC" user:setting "$name" settings display_name "$display_name" >/dev/null
              fi
            }

            sync_enabled_state() {
              local name="$1"
              local enabled="$2"
              local current

              current="$(current_enabled "$name")"
              if [ "$enabled" = "1" ] && [ "$current" != "true" ]; then
                "$OCC" user:enable "$name" >/dev/null
              elif [ "$enabled" != "1" ] && [ "$current" != "false" ]; then
                "$OCC" user:disable "$name" >/dev/null
              fi
            }

            sync_groups() {
              local name="$1"
              local admin="$2"
              local groups_json="$3"
              local desired_json
              local current_json

              desired_json="$(printf '%s\n' "$groups_json" | jq -c --arg admin "$admin" '
                .
                + (if $admin == "1" then ["admin"] else [] end)
                | map(select(. != ""))
                | unique
              ')"

              while IFS= read -r group; do
                [ -n "$group" ] || continue
                ensure_group "$group"
                if ! printf '%s\n' "$desired_json" | jq -e --arg group "$group" 'index($group) != null' >/dev/null; then
                  "$OCC" group:removeuser "$group" "$name" >/dev/null
                fi
              done < <(printf '%s\n' "$(current_groups_json "$name")" | jq -r '.[]')

              while IFS= read -r group; do
                [ -n "$group" ] || continue
                if ! printf '%s\n' "$(current_groups_json "$name")" | jq -e --arg group "$group" 'index($group) != null' >/dev/null; then
                  ensure_group "$group"
                  "$OCC" group:adduser "$group" "$name" >/dev/null
                fi
              done < <(printf '%s\n' "$desired_json" | jq -r '.[]')
            }

            ensure_user() {
              local name="$1"
              local passfile="$2"
              local admin="$3"
              local enabled="$4"
              local display_name="$5"
              local email="$6"
              local quota="$7"
              local groups_json="$8"
              local group
              local desired_digest
              local current_digest
              local -a create_args

              desired_digest="$(password_digest "$passfile")"
              current_digest="$(current_password_digest "$name")"

              if have_user "$name"; then
                if [ "$desired_digest" != "$current_digest" ]; then
                  export NC_PASS
                  NC_PASS="$(tr -d '\r\n' < "$passfile")"
                  "$OCC" user:resetpassword --password-from-env "$name" >/dev/null
                  unset NC_PASS
                fi
              else
                create_args=(user:add --password-from-env "$name" "--display-name=$display_name")
                if [ -n "$email" ]; then
                  create_args+=("--email=$email")
                fi

                while IFS= read -r group; do
                  [ -n "$group" ] || continue
                  create_args+=("--group=$group")
                done < <(printf '%s\n' "$groups_json" | jq -r '.[]')

                if [ "$admin" = "1" ]; then
                  create_args+=("--group=admin")
                fi

                export NC_PASS
                NC_PASS="$(tr -d '\r\n' < "$passfile")"
                "$OCC" "''${create_args[@]}" >/dev/null
                unset NC_PASS
              fi

              set_display_name "$name" "$display_name"
              set_email "$name" "$email"
              set_quota "$name" "$quota"
              sync_enabled_state "$name" "$enabled"
              sync_groups "$name" "$admin" "$groups_json"
              write_password_digest "$name" "$desired_digest"
            }

            prune_undeclared_users() {
              if [ "$PRUNE" != "1" ]; then
                return 0
              fi

              "$OCC" user:list --output=json | jq -r 'keys[]' | while IFS= read -r user; do
                if ! printf '%s\n' "$DECLARED" | tr ' ' '\n' | grep -Fxq "$user"; then
                  "$OCC" user:delete "$user" >/dev/null
                  delete_password_digest "$user"
                fi
              done
            }

            configure_collabora() {
              if [ "$COLLABORA_ENABLE" != "1" ]; then
                return 0
              fi

              local -a activate_args

              activate_args=(richdocuments:activate-config --wopi-url="$COLLABORA_INTERNAL_URL")
              if [ -n "$COLLABORA_CALLBACK_URL" ]; then
                activate_args+=(--callback-url="$COLLABORA_CALLBACK_URL")
              fi

              "$OCC" "''${activate_args[@]}" >/dev/null

              if [ -n "$NEXTCLOUD_PUBLIC_URL" ]; then
                if [ -n "$RICHDOCUMENTS_CANONICAL_WEBROOT" ]; then
                  "$OCC" config:app:set richdocuments canonical_webroot --value="$RICHDOCUMENTS_CANONICAL_WEBROOT" >/dev/null
                else
                  "$OCC" config:app:delete richdocuments canonical_webroot >/dev/null 2>&1 || true
                fi
              fi

              if [ "$COLLABORA_DISABLE_VERIFY" = "1" ]; then
                "$OCC" config:app:set richdocuments disable_certificate_verification --value=yes >/dev/null
              else
                "$OCC" config:app:delete richdocuments disable_certificate_verification >/dev/null 2>&1 || true
              fi
            }

            ${passfileLines}
            ${ensureLines}

            sync_trusted_domains
            sync_overwrite_settings
            prune_undeclared_users
            configure_collabora
          '';
      };
    }

    (lib.mkIf (baseConfigReady && !clusterCfg.enable) (
      serviceExposure.mkConfig {
        inherit config endpoint exposeCfg;
        serviceName = "nextcloud";
        serviceDescription = "Nextcloud";
      }
    ))

    (lib.mkIf (collaboraCfg.enable && baseConfigReady && !clusterCfg.enable) (
      serviceExposure.mkConfig {
        config = config;
        endpoint = collaboraEndpoint;
        exposeCfg = collaboraExposeCfg;
        serviceName = "nextcloud-collabora";
        serviceDescription = "Nextcloud Collabora";
      }
    ))
  ]);
}
