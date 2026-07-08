{ config, lib, pkgs, hostname, allHosts, ... }:
let
  cfg = config.alanix.cluster;
  types = lib.types;
  serviceExposure = import ../../lib/mkServiceExposure.nix { inherit lib pkgs; };

  parseDurationMs =
    value:
    let
      msMatch = builtins.match "^([0-9]+)ms$" value;
      sMatch = builtins.match "^([0-9]+)s$" value;
    in
    if msMatch != null then
      builtins.fromJSON (builtins.head msMatch)
    else if sMatch != null then
      1000 * builtins.fromJSON (builtins.head sMatch)
    else
      throw "Unsupported duration `${value}`. Use <n>ms or <n>s.";

  normalizeLocalAddress =
    address:
    if address == "0.0.0.0" then
      "127.0.0.1"
    else if address == "::" then
      "::1"
    else
      address;

in
{
  options.alanix.cluster = {
    enable = lib.mkEnableOption "Alanix cluster controller";

    name = lib.mkOption {
      type = types.str;
      default = "cluster";
    };

    transport = lib.mkOption {
      type = types.enum [ "tailscale" ];
      default = "tailscale";
    };

    members = lib.mkOption {
      type = types.listOf types.str;
      default = [ ];
    };

    voters = lib.mkOption {
      type = types.listOf types.str;
      default = [ ];
    };

    priority = lib.mkOption {
      type = types.listOf types.str;
      default = [ ];
    };

    addresses = lib.mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "Cluster transport address for each member, keyed by hostname.";
    };

    etcd = {
      bootstrapGeneration = lib.mkOption {
        type = types.int;
        default = 1;
        description = ''
          Explicit etcd bootstrap generation. Bump this when cluster membership or
          initial etcd topology changes and the cluster should be re-initialized.
        '';
      };

      heartbeatInterval = lib.mkOption {
        type = types.str;
        default = "500ms";
      };

      electionTimeout = lib.mkOption {
        type = types.str;
        default = "5s";
      };

      leaseTtl = lib.mkOption {
        type = types.str;
        default = "30s";
      };

      renewEvery = lib.mkOption {
        type = types.str;
        default = "5s";
      };

      acquisitionStep = lib.mkOption {
        type = types.str;
        default = "5s";
      };

      dialTimeout = lib.mkOption {
        type = types.str;
        default = "1s";
        description = "Per-endpoint etcdctl dial timeout used by the cluster controller.";
      };

      commandTimeout = lib.mkOption {
        type = types.str;
        default = "3s";
        description = "Per-endpoint etcdctl command timeout used by the cluster controller.";
      };
    };

    backup = {
      repoUser = lib.mkOption {
        type = types.str;
        default = "buddia";
      };

      repoBaseDir = lib.mkOption {
        type = types.str;
        default = "/var/lib/alanix-backups";
      };

      passwordSecret = lib.mkOption {
        type = types.str;
        default = "cluster/restic-password";
      };

      maxConcurrent = lib.mkOption {
        type = types.ints.positive;
        default = 2;
        description = ''
          Maximum number of service backups the active cluster node may run at once.
          Backups for the same service are never overlapped.
        '';
      };

      minFreeSpaceBytes = lib.mkOption {
        type = types.ints.positive;
        default = 100 * 1024 * 1024 * 1024;
        description = ''
          Minimum free space that should remain on the filesystem holding staged
          backup payloads after the local snapshot completes. When the remaining
          space falls below this threshold, the controller keeps the local
          snapshot but skips slower remote replications so staged data can be
          cleaned up promptly.
        '';
      };

      retainDays = lib.mkOption {
        type = types.ints.positive;
        default = 7;
        description = ''
          Number of days to keep timestamped backup manifests before pruning.
        '';
      };
    };

    dashboard = {
      enable = lib.mkEnableOption "Alanix cluster dashboard";

      listenAddress = lib.mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "Local bind address for the cluster dashboard.";
      };

      port = lib.mkOption {
        type = types.port;
        default = 9842;
        description = "Local HTTP port for the cluster dashboard.";
      };

      recentEvents = lib.mkOption {
        type = types.int;
        default = 40;
        description = "Number of recent controller events to show in the dashboard.";
      };

      admin = {
        enable = lib.mkOption {
          type = types.bool;
          default = true;
          description = "Whether the dashboard should allow authenticated admin actions.";
        };

        username = lib.mkOption {
          type = types.str;
          default = cfg.backup.repoUser;
          description = "Username shown and accepted by the dashboard admin login.";
        };

        passwordFile = lib.mkOption {
          type = types.nullOr types.path;
          default = null;
          description = "Path to a file containing the plaintext password for dashboard admin login.";
        };

        sessionTtl = lib.mkOption {
          type = types.str;
          default = "12h";
          description = "Lifetime for dashboard admin sessions.";
        };
      };

      expose = serviceExposure.mkOptions {
        serviceName = "cluster-dashboard";
        serviceDescription = "Cluster Dashboard";
        defaultPublicPort = 80;
      };
    };

    ddns = {
      enable = lib.mkEnableOption "cluster-leader-tracking Cloudflare DDNS";

      domains = lib.mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Domains to point at the current cluster leader via Cloudflare DDNS.";
      };

      ipv4Provider = lib.mkOption {
        type = types.str;
        default = "cloudflare.trace";
        description = "IPv4 detection provider passed to cloudflare-ddns.";
      };

      ipv6Provider = lib.mkOption {
        type = types.str;
        default = "none";
        description = "IPv6 detection provider passed to cloudflare-ddns.";
      };

      detectionTimeout = lib.mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Optional detection timeout passed to cloudflare-ddns.";
      };

      credentialsFile = lib.mkOption {
        type = types.path;
        description = "Path to file containing CLOUDFLARE_API_TOKEN=<token>.";
      };
    };
  };

  options.alanix.clusterServices = lib.mkOption {
    type = types.attrsOf types.anything;
    default = { };
    internal = true;
    visible = false;
    description = ''
      Internal cluster service registry. Service modules publish their cluster
      contract here; alanix.cluster consumes the registry generically.
    '';
  };

  config = lib.mkIf cfg.enable (
    let
      hostTransportAddress = hostName: cfg.addresses.${hostName} or null;
      localTransportAddress = hostTransportAddress hostname;
      isVoter = builtins.elem hostname cfg.voters;
      dashboardCfg = cfg.dashboard;
      ddnsCfg = cfg.ddns;
      dashboardEndpoint = {
        address = dashboardCfg.listenAddress;
        port = dashboardCfg.port;
        protocol = "http";
      };

      enabledServices = lib.filterAttrs (_: svc: svc.enable or true) config.alanix.clusterServices;
      serviceEntries = lib.mapAttrsToList (serviceName: svc: svc // { inherit serviceName; }) enabledServices;

      peerHostCfg = peer: lib.attrByPath [ peer ] null allHosts;

      peerTailscaleAddress =
        peer:
        let
          hostCfg = peerHostCfg peer;
        in
        if hostCfg != null then hostCfg.config.alanix.tailscale.address else null;

      urlHostLiteral =
        host:
        if lib.hasPrefix "[" host && lib.hasSuffix "]" host then
          host
        else if lib.hasInfix ":" host then
          "[${host}]"
        else
          host;

      mkUrl =
        {
          scheme,
          host,
          port,
          path ? "/",
        }:
        let
          defaultPort = if scheme == "https" then 443 else 80;
          portSuffix = if port == defaultPort then "" else ":${toString port}";
        in
        "${scheme}://${urlHostLiteral host}${portSuffix}${path}";

      mkConstantLinksByHost =
        links:
        lib.listToAttrs (
          map (peer: {
            name = peer;
            value = links;
          }) cfg.members
        );

      mkPeerLinksByHost =
        {
          label,
          transport,
          scheme,
          port,
          addressFn,
        }:
        lib.listToAttrs (
          map (peer: {
            name = peer;
            value =
              let
                address = addressFn peer;
              in
              lib.optionals (address != null && address != "") [
                {
                  inherit scheme transport;
                  label = "${label} (${transport})";
                  host = peer;
                  url = mkUrl {
                    inherit scheme port;
                    host = address;
                  };
                }
              ];
          }) cfg.members
        );

      mergeLinksByHost =
        attrsets:
        lib.listToAttrs (
          map (peer: {
            name = peer;
            value = lib.concatLists (map (attrs: attrs.${peer} or [ ]) attrsets);
          }) cfg.members
        );

      peerDashboardTorHostname =
        peer:
        let
          hostCfg = peerHostCfg peer;
        in
        if hostCfg != null then hostCfg.config.alanix.cluster.dashboard.expose.tor.hostname else null;

      dashboardLinks =
        lib.optionals dashboardCfg.expose.tailscale.enable (
          map (peer: {
            label = "${peer} dashboard (tailscale)";
            host = peer;
            transport = "tailscale";
            url = mkUrl {
              scheme = "http";
              host = peerTailscaleAddress peer;
              port = dashboardCfg.expose.tailscale.port;
            };
          }) (lib.filter (peer: peerTailscaleAddress peer != null && peerTailscaleAddress peer != "") cfg.members)
        )
        ++ lib.optionals dashboardCfg.expose.tor.enable (
          lib.concatMap (peer:
            let torHostname = peerDashboardTorHostname peer;
            in lib.optionals (torHostname != null) [{
              label = "${peer} dashboard (tor)";
              host = peer;
              transport = "tor";
              url = "http://${torHostname}/";
            }]
          ) cfg.members
        )
        ++ lib.optionals dashboardCfg.expose.wan.enable (
          map (peer: {
            label = "${peer} dashboard (wan)";
            host = peer;
            transport = "wan";
            url = "https://${dashboardCfg.expose.wan.domain}/";
          }) cfg.members
        );

      webEndpoints =
        lib.concatMap
          (svc:
            map
              (endpoint:
                endpoint
                // {
                  serviceName = svc.serviceName;
                  serviceLabel =
                    endpoint.label or svc.label or (svc.controller.label or svc.serviceName);
                  id = endpoint.id or endpoint.name or svc.serviceName;
                  label = endpoint.label or svc.label or (svc.controller.label or svc.serviceName);
                  torStateDirName = endpoint.torStateDirName or endpoint.id or endpoint.name or svc.serviceName;
                })
              (svc.webEndpoints or [ ]))
          serviceEntries;

      endpointHasCaddy =
        endpoint:
        (endpoint.expose.tailscale.enable or false)
        || (endpoint.expose.wan.enable or false)
        || ((endpoint.expose.tor.enable or false) && (endpoint.expose.tor.tls or false));

      anyCaddyExposure = lib.any endpointHasCaddy webEndpoints;
      anyWanExposure = lib.any (endpoint: endpoint.expose.wan.enable or false) webEndpoints;
      anyTailscaleCaddyExposure = lib.any (endpoint: endpoint.expose.tailscale.enable or false) webEndpoints;
      anyTorExposure = lib.any (endpoint: endpoint.expose.tor.enable or false) webEndpoints;
      postgresqlCluster = lib.any (svc: svc.needsPostgresql or false) serviceEntries;

      mkTorUrl =
        torCfg:
        let
          scheme = if torCfg.tls then "https" else "http";
          port = torCfg.publicPort;
        in
        if torCfg.enable && torCfg.hostname != null then
          mkUrl {
            inherit scheme port;
            host = torCfg.hostname;
          }
        else
          null;

      mkWanUrl =
        wanCfg:
        if wanCfg.enable && wanCfg.domain != null then
          mkUrl {
            scheme = if wanCfg.tls then "https" else "http";
            host = wanCfg.domain;
            port =
              if wanCfg.port != null then
                wanCfg.port
              else if wanCfg.tls then
                443
              else
                80;
          }
        else
          null;

      mkWebEndpointLinksByHost =
        endpoint:
        let
          exposeCfg = endpoint.expose;
          label = endpoint.label;
        in
        mergeLinksByHost [
          (lib.optionalAttrs exposeCfg.tailscale.enable (
            mkPeerLinksByHost {
              inherit label;
              transport = "tailscale";
              scheme = if exposeCfg.tailscale.tls then "https" else "http";
              port = exposeCfg.tailscale.port;
              addressFn = peerTailscaleAddress;
            }
          ))
          (lib.optionalAttrs (exposeCfg.tor.enable && exposeCfg.tor.hostname != null) (
            mkConstantLinksByHost [
              {
                label = "${label} (tor)";
                transport = "tor";
                url = mkTorUrl exposeCfg.tor;
              }
            ]
          ))
          (lib.optionalAttrs (exposeCfg.wan.enable && exposeCfg.wan.domain != null) (
            mkConstantLinksByHost [
              {
                label = "${label} (wan)";
                transport = "wan";
                url = mkWanUrl exposeCfg.wan;
              }
            ]
          ))
        ];

      webEndpointsForService = serviceName: lib.filter (endpoint: endpoint.serviceName == serviceName) webEndpoints;

      primaryTorEndpoint =
        serviceName:
        lib.findFirst
          (endpoint: endpoint.expose.tor.enable or false)
          null
          (webEndpointsForService serviceName);

      mkServiceLinksByHost =
        serviceName: svc:
        mergeLinksByHost (
          [ (svc.controller.linksByHost or { }) ]
          ++ (map mkWebEndpointLinksByHost (webEndpointsForService serviceName))
        );

      mkServiceTorUrl =
        serviceName: svc:
        let
          configured = svc.controller.torUrl or null;
          endpoint = primaryTorEndpoint serviceName;
        in
        if configured != null then
          configured
        else if endpoint != null then
          mkTorUrl endpoint.expose.tor
        else
          null;

      mkServiceTorConfig =
        serviceName: svc:
        let
          configured = svc.controller.tor or null;
          endpoint = primaryTorEndpoint serviceName;
        in
        if configured != null then
          configured
        else if endpoint != null then
          {
            enabled = endpoint.expose.tor.enable;
            tls = endpoint.expose.tor.tls;
            publicPort = endpoint.expose.tor.publicPort;
            stateDirName = endpoint.torStateDirName;
          }
        else
          null;

      serviceBackupDir =
        serviceName:
        "${cfg.backup.repoBaseDir}/${cfg.name}/${serviceName}";

      mkSharedRepoPath =
        serviceName:
        "${serviceBackupDir serviceName}/repo";

      mkManifestGlobs =
        serviceName:
        [
          "${serviceBackupDir serviceName}/manifest-*.json"
        ];

      mkRemoteTargets =
        serviceName:
        map
          (peer: {
            host = peer;
            address = hostTransportAddress peer;
            repoPath = mkSharedRepoPath serviceName;
            manifestDir = serviceBackupDir serviceName;
          })
          (lib.filter (peer: peer != hostname) cfg.members);

      mkLocalTarget =
        serviceName:
        {
          repoPath = mkSharedRepoPath serviceName;
          manifestDir = serviceBackupDir serviceName;
        };

      mkControllerService =
        serviceName: svc:
        let
          controller = svc.controller;
          controllerConfig = lib.removeAttrs controller [ "maxBackupAge" ];
          recoveryMode = controller.recoveryMode or "backup";
          activeUnits =
            lib.unique (
              (controller.activeUnits or [ ])
              ++ lib.optionals (anyCaddyExposure || anyTorExposure) [ "alanix-cluster-exposure.service" ]
            );
          torUrl = mkServiceTorUrl serviceName svc;
          torConfig = mkServiceTorConfig serviceName svc;
        in
        controllerConfig
        // {
          name = controller.name or serviceName;
          activeUnits = activeUnits;
          linksByHost = mkServiceLinksByHost serviceName svc;
        }
        // lib.optionalAttrs (svc.label != null && !(controller ? label)) {
          label = svc.label;
        }
        // lib.optionalAttrs (torUrl != null) {
          inherit torUrl;
        }
        // lib.optionalAttrs (torConfig != null) {
          tor = torConfig;
        }
        // lib.optionalAttrs (recoveryMode == "declarative") {
          remoteTargets = controller.remoteTargets or [ ];
        }
        // lib.optionalAttrs (recoveryMode != "declarative" && controller ? backupPaths) {
          remoteTargets = mkRemoteTargets serviceName;
          manifestGlobs = mkManifestGlobs serviceName;
          localTarget = mkLocalTarget serviceName;
        };

      controllerServices = lib.mapAttrs mkControllerService enabledServices;

      dashboardFaviconPath =
        if builtins.pathExists ./favicon.ico then
          "${./favicon.ico}"
        else
          null;

      dashboardModeProbeUrlsByHost =
        lib.listToAttrs (
          map
            (peer: {
              name = peer;
              value =
                lib.optionals (dashboardCfg.expose.tailscale.enable && peerTailscaleAddress peer != null && dashboardCfg.expose.tailscale.port != null) [
                  (mkUrl {
                    scheme = "http";
                    host = peerTailscaleAddress peer;
                    port = dashboardCfg.expose.tailscale.port;
                    path = "/api/mode";
                  })
                ];
            })
            cfg.members
        );

      controllerConfig = {
        cluster = {
          name = cfg.name;
          transport = cfg.transport;
          leaderKey = "/alanix/clusters/${cfg.name}/leader";
          runtimeModeKey = "/alanix/clusters/${cfg.name}/runtime-mode";
          runtimeModeAckPrefix = "/alanix/clusters/${cfg.name}/runtime-mode-acks";
          runtimeModeFile = "/var/lib/alanix-cluster/runtime-mode.json";
          hostname = hostname;
          members = cfg.members;
          voters = cfg.voters;
          priority = cfg.priority;
          bootstrapHost = lib.head cfg.priority;
          activeTarget = "alanix-cluster-active.target";
          modeProbeUrls = dashboardModeProbeUrlsByHost;
          modeProbeTimeoutSeconds = 2;
          modeAckTimeout = "2m";
          modeAckPollInterval = "2s";
          etcd = {
            leaseTtl = cfg.etcd.leaseTtl;
            renewEvery = cfg.etcd.renewEvery;
            acquisitionStep = cfg.etcd.acquisitionStep;
            dialTimeout = cfg.etcd.dialTimeout;
            commandTimeout = cfg.etcd.commandTimeout;
          };
          backup = {
            repoUser = cfg.backup.repoUser;
            repoBaseDir = cfg.backup.repoBaseDir;
            passwordFile = config.sops.secrets.${cfg.backup.passwordSecret}.path;
            maxConcurrent = cfg.backup.maxConcurrent;
            minFreeSpaceBytes = cfg.backup.minFreeSpaceBytes;
            retainDays = cfg.backup.retainDays;
          };
          endpoints =
            map
              (peer:
                if peer == hostname then
                  "http://127.0.0.1:2379"
                else
                  "http://${hostTransportAddress peer}:2379")
              cfg.voters;
        };
        dashboard = {
          listenAddress = dashboardCfg.listenAddress;
          port = dashboardCfg.port;
          recentEvents = dashboardCfg.recentEvents;
          faviconPath = dashboardFaviconPath;
          links = dashboardLinks;
          admin = {
            enable = dashboardCfg.admin.enable;
            username = dashboardCfg.admin.username;
            passwordFile = dashboardCfg.admin.passwordFile;
            sessionTtl = dashboardCfg.admin.sessionTtl;
          };
        };
        services = controllerServices;
      };

      controllerConfigFile = pkgs.writeText "alanix-cluster-controller.json" (builtins.toJSON controllerConfig);

      mkUpstream =
        endpoint:
        let
          address = normalizeLocalAddress endpoint.address;
        in
        if endpoint.protocol == "https" then
          "https://${address}:${toString endpoint.port}"
        else
          "${address}:${toString endpoint.port}";

      endpointExtraCaddy = endpoint: endpoint.extraCaddyConfig or "";

      mkCaddyBlock =
        {
          site,
          bindAddress ? null,
          tls ? false,
          endpoint,
        }:
        let
          bindLine = lib.optionalString (bindAddress != null && bindAddress != "") "  bind ${bindAddress}\n";
          tlsLine = lib.optionalString tls "  tls internal\n";
          extra = endpointExtraCaddy endpoint;
          extraLines = lib.optionalString (extra != "") "${extra}\n";
          defaultProxyLine =
            lib.optionalString
              (!(endpoint.disableDefaultCaddyReverseProxy or false))
              "  reverse_proxy ${mkUpstream endpoint.endpoint}\n";
        in
        ''
          cat >> "$caddy_file" <<EOF
          ${site} {
          ${bindLine}${tlsLine}${extraLines}${defaultProxyLine}
          }

          EOF
        '';

      tailscaleName =
        endpoint:
        if endpoint.expose.tailscale.tlsName != null then
          endpoint.expose.tailscale.tlsName
        else
          config.alanix.tailscale.address;

      torTargetAddress =
        endpoint:
        normalizeLocalAddress (
          if endpoint.expose.tor.targetAddress != null then
            endpoint.expose.tor.targetAddress
          else
            endpoint.endpoint.address
        );

      torTargetPort =
        endpoint:
        if endpoint.expose.tor.tls then
          endpoint.expose.tor.publicPort
        else
          endpoint.endpoint.port;

      torSecretPath =
        endpoint:
        if endpoint.expose.tor.secretKeyBase64Secret != null then
          config.sops.secrets.${endpoint.expose.tor.secretKeyBase64Secret}.path
        else
          null;

      mkWanSite =
        endpoint:
        let
          wanCfg = endpoint.expose.wan;
          port =
            if wanCfg.port != null then
              wanCfg.port
            else if wanCfg.tls then
              443
            else
              80;
          defaultPort = if wanCfg.tls then 443 else 80;
          scheme = if wanCfg.tls then "https" else "http";
          portSuffix = if port == defaultPort then "" else ":${toString port}";
        in
        if wanCfg.domain != null then
          "${scheme}://${wanCfg.domain}${portSuffix}"
        else
          ":${toString port}";

      mkEndpointStartScript =
        endpoint:
        let
          exposeCfg = endpoint.expose;
        in
        lib.concatStringsSep "\n" [
          (lib.optionalString exposeCfg.tailscale.enable (
            mkCaddyBlock {
              site = "${if exposeCfg.tailscale.tls then "https" else "http"}://${tailscaleName endpoint}:${toString exposeCfg.tailscale.port}";
              bindAddress = "$ts_ip";
              tls = exposeCfg.tailscale.tls;
              inherit endpoint;
            }
          ))
          (lib.optionalString (exposeCfg.tor.enable && exposeCfg.tor.tls) (
            mkCaddyBlock {
              site = "https://${exposeCfg.tor.tlsName}:${toString exposeCfg.tor.publicPort}";
              bindAddress = torTargetAddress endpoint;
              tls = true;
              inherit endpoint;
            }
          ))
          (lib.optionalString exposeCfg.tor.enable ''
            rm -rf "$tor_state_dir/${endpoint.torStateDirName}"
            mkdir -p "$tor_state_dir/${endpoint.torStateDirName}"
            chown tor:tor "$tor_state_dir/${endpoint.torStateDirName}"
            chmod 0700 "$tor_state_dir/${endpoint.torStateDirName}"
          '')
          (lib.optionalString (exposeCfg.tor.enable && torSecretPath endpoint != null) ''
            base64 --decode ${lib.escapeShellArg (torSecretPath endpoint)} > "$tor_state_dir/${endpoint.torStateDirName}/hs_ed25519_secret_key"
            chown tor:tor "$tor_state_dir/${endpoint.torStateDirName}/hs_ed25519_secret_key"
            chmod 0600 "$tor_state_dir/${endpoint.torStateDirName}/hs_ed25519_secret_key"
          '')
          (lib.optionalString exposeCfg.tor.enable ''
            cat >> "$tor_file" <<EOF
            HiddenServiceDir $tor_state_dir/${endpoint.torStateDirName}
            HiddenServiceVersion 3
            HiddenServicePort ${toString exposeCfg.tor.publicPort} ${torTargetAddress endpoint}:${toString (torTargetPort endpoint)}

            EOF
          '')
          (lib.optionalString exposeCfg.wan.enable (
            mkCaddyBlock {
              site = mkWanSite endpoint;
              bindAddress =
                if exposeCfg.wan.address != null && exposeCfg.wan.address != "0.0.0.0" then
                  exposeCfg.wan.address
                else
                  null;
              tls = false;
              inherit endpoint;
            }
          ))
        ];

      exposureUnits = lib.unique (lib.concatMap (svc: svc.exposureUnits or [ ]) serviceEntries);
      serviceTmpfiles = lib.concatMap (svc: svc.tmpfiles or [ ]) serviceEntries;
      serviceFirewallPorts = lib.unique (lib.concatMap (svc: svc.firewallAllowedTCPPorts or [ ]) serviceEntries);

      exposureScript = pkgs.writeShellScript "alanix-cluster-exposure" ''
        set -euo pipefail

        action="''${1:-start}"
        runtime_dir=/run/alanix-cluster
        caddy_file="$runtime_dir/caddy/cluster.caddy"
        tor_state_dir=/var/lib/tor/alanix-cluster
        tor_file="$tor_state_dir/cluster.conf"
        tor_hostname_dir=/var/lib/alanix-cluster/tor-hostnames

        mkdir -p "$runtime_dir/caddy" "$tor_state_dir" "$tor_hostname_dir"

        if [[ "$action" == "start" ]]; then
          : > "$caddy_file"
          : > "$tor_file"

          ${lib.optionalString anyTailscaleCaddyExposure ''
            ts_ip="$(${config.services.tailscale.package}/bin/tailscale ip -4 | head -n1)"
            if [[ -z "$ts_ip" ]]; then
              echo "failed to determine Tailscale IPv4 address" >&2
              exit 1
            fi
          ''}

          ${lib.concatMapStringsSep "\n" (svc: svc.extraExposureStart or "") serviceEntries}
          ${lib.concatMapStringsSep "\n" mkEndpointStartScript webEndpoints}

          ${lib.optionalString anyCaddyExposure ''
            systemctl start caddy.service
            systemctl reload caddy.service
          ''}

          ${lib.optionalString anyTorExposure ''
            systemctl start tor.service
            systemctl reload tor.service

            publish_tor_hostname() {
              local service_name="$1"
              local source="$tor_state_dir/$service_name/hostname"
              local target="$tor_hostname_dir/$service_name"
              local attempts=20

              while [[ "$attempts" -gt 0 ]]; do
                if [[ -s "$source" ]]; then
                  install -m0644 -o root -g root "$source" "$target"
                  return 0
                fi
                sleep 1
                attempts=$((attempts - 1))
              done

              return 0
            }

            ${lib.concatMapStringsSep "\n" (endpoint:
              lib.optionalString (endpoint.expose.tor.enable or false) ''
                publish_tor_hostname ${lib.escapeShellArg endpoint.torStateDirName}
              '') webEndpoints}
          ''}
        else
          : > "$caddy_file"
          : > "$tor_file"

          ${lib.concatMapStringsSep "\n" (endpoint:
            lib.optionalString (endpoint.expose.tor.enable or false) ''
              rm -rf "$tor_state_dir/${endpoint.torStateDirName}"
            '') webEndpoints}
          ${lib.concatMapStringsSep "\n" (svc: svc.extraExposureStop or "") serviceEntries}

          ${lib.optionalString anyCaddyExposure ''
            systemctl reload caddy.service || true
          ''}

          ${lib.optionalString anyTorExposure ''
            systemctl reload tor.service || true
          ''}
        fi
      '';
    in
    lib.mkMerge (
      [
        {
          assertions =
            [
              {
                assertion = builtins.elem hostname cfg.members;
                message = "alanix.cluster.enable requires the current host to be listed in alanix.cluster.members.";
              }
              {
                assertion = cfg.members == lib.unique cfg.members;
                message = "alanix.cluster.members must not contain duplicates.";
              }
              {
                assertion = cfg.voters == lib.unique cfg.voters;
                message = "alanix.cluster.voters must not contain duplicates.";
              }
              {
                assertion = cfg.priority == lib.unique cfg.priority;
                message = "alanix.cluster.priority must not contain duplicates.";
              }
              {
                assertion = lib.all (host: builtins.elem host cfg.members) cfg.voters;
                message = "alanix.cluster.voters must be a subset of alanix.cluster.members.";
              }
              {
                assertion = lib.all (host: builtins.elem host cfg.members) cfg.priority;
                message = "alanix.cluster.priority must be a subset of alanix.cluster.members.";
              }
              {
                assertion = cfg.priority != [ ];
                message = "alanix.cluster.priority must contain at least one host.";
              }
              {
                assertion = builtins.length cfg.voters == 3;
                message = "alanix.cluster.voters must contain exactly three hosts.";
              }
              {
                assertion = cfg.transport == "tailscale" -> config.alanix.tailscale.enable;
                message = "alanix.cluster.transport = \"tailscale\" requires alanix.tailscale.enable = true.";
              }
              {
                assertion = cfg.transport != "tailscale" || config.alanix.tailscale.address != null;
                message = "alanix.cluster.transport = \"tailscale\" requires alanix.tailscale.address to be set.";
              }
              {
                assertion = cfg.etcd.bootstrapGeneration >= 1;
                message = "alanix.cluster.etcd.bootstrapGeneration must be at least 1.";
              }
              {
                assertion = lib.hasAttrByPath [ "sops" "secrets" cfg.backup.passwordSecret ] config;
                message = "alanix.cluster.backup.passwordSecret must reference a declared sops secret.";
              }
              {
                assertion = lib.hasAttrByPath [ "users" "users" cfg.backup.repoUser ] config;
                message = "alanix.cluster.backup.repoUser must reference a declared local user.";
              }
            ]
            ++ map
              (peer: {
                assertion = hostTransportAddress peer != null;
                message = "Cluster member `${peer}` is missing an entry in alanix.cluster.addresses.";
              })
              cfg.members
            ++ serviceExposure.mkAssertions {
              inherit config;
              optionPrefix = "alanix.cluster.dashboard.expose";
              endpoint = dashboardEndpoint;
              exposeCfg = dashboardCfg.expose;
            };

          systemd.targets."alanix-cluster-active" = {
            description = "Alanix cluster active target";
          };

          system.activationScripts.alanixClusterTor = lib.mkIf anyTorExposure {
            deps = [ "users" ];
            text = ''
              mkdir -p /var/lib/tor/alanix-cluster
              chown root:tor /var/lib/tor/alanix-cluster
              chmod 0750 /var/lib/tor/alanix-cluster
              if [ ! -e /var/lib/tor/alanix-cluster/cluster.conf ]; then
                touch /var/lib/tor/alanix-cluster/cluster.conf
              fi
              chown root:tor /var/lib/tor/alanix-cluster/cluster.conf
              chmod 0640 /var/lib/tor/alanix-cluster/cluster.conf
            '';
          };

          systemd.services."alanix-cluster-controller" = {
            description = "Alanix cluster controller";
            wantedBy = [ "multi-user.target" ];
            after =
              [ "network-online.target" "sops-nix.service" ]
              ++ lib.optional (cfg.transport == "tailscale") "tailscaled.service"
              ++ lib.optionals postgresqlCluster [ "postgresql.service" ]
              ++ lib.optional isVoter "etcd.service";
            wants =
              [ "network-online.target" "sops-nix.service" ]
              ++ lib.optional (cfg.transport == "tailscale") "tailscaled.service"
              ++ lib.optionals postgresqlCluster [ "postgresql.service" ]
              ++ lib.optional isVoter "etcd.service";
            path = with pkgs; [
              coreutils
              etcd
              jq
              openssh
              python3
              restic
              rsync
              sqlite
              systemd
              util-linux
            ] ++ lib.optionals postgresqlCluster [ config.services.postgresql.package ];
            serviceConfig = {
              Type = "simple";
              Restart = "always";
              RestartSec = "5s";
              ExecStart = "${pkgs.python3}/bin/python3 ${./controller.py} ${controllerConfigFile}";
            };
            environment = {
              PYTHONUNBUFFERED = "1";
            };
          };

          systemd.services."alanix-cluster-dashboard" = lib.mkIf dashboardCfg.enable {
            description = "Alanix cluster dashboard";
            wantedBy = [ "multi-user.target" ];
            after =
              [ "network-online.target" "sops-nix.service" ]
              ++ lib.optional (cfg.transport == "tailscale") "tailscaled.service";
            wants =
              [ "network-online.target" "sops-nix.service" ]
              ++ lib.optional (cfg.transport == "tailscale") "tailscaled.service";
            path = with pkgs; [
              coreutils
              etcd
              python3
              restic
              systemd
            ];
            serviceConfig = {
              Type = "simple";
              Restart = "always";
              RestartSec = "5s";
              ExecStart = "${pkgs.python3}/bin/python3 ${./dashboard.py} ${controllerConfigFile}";
            };
            environment = {
              PYTHONUNBUFFERED = "1";
            };
          };

          systemd.tmpfiles.rules =
            [
              "d ${cfg.backup.repoBaseDir} 0700 ${cfg.backup.repoUser} users - -"
              "Z ${cfg.backup.repoBaseDir} - ${cfg.backup.repoUser} users - -"
              "d /var/lib/alanix-cluster 0755 root root - -"
            ]
            ++ serviceTmpfiles
            ++ lib.optionals anyCaddyExposure [
              "d /run/alanix-cluster 0755 root root - -"
              "d /run/alanix-cluster/caddy 0755 root root - -"
              "f /run/alanix-cluster/caddy/cluster.caddy 0644 root root - -"
            ]
            ++ lib.optionals anyTorExposure [
              "d /var/lib/tor/alanix-cluster 0750 root tor - -"
              "f /var/lib/tor/alanix-cluster/cluster.conf 0640 root tor - -"
              "d /var/lib/alanix-cluster/tor-hostnames 0755 root root - -"
            ];
        }

        (lib.mkIf isVoter {
          services.etcd = {
            enable = true;
            name = hostname;
            # Bind once on all interfaces; localhost access still works via 127.0.0.1.
            listenClientUrls = [ "http://0.0.0.0:2379" ];
            advertiseClientUrls = [ "http://${localTransportAddress}:2379" ];
            listenPeerUrls = [ "http://0.0.0.0:2380" ];
            initialAdvertisePeerUrls = [ "http://${localTransportAddress}:2380" ];
            initialCluster = map (peer: "${peer}=http://${hostTransportAddress peer}:2380") cfg.voters;
            initialClusterState = "new";
            initialClusterToken = "alanix-${cfg.name}";
            extraConf = {
              HEARTBEAT_INTERVAL = toString (parseDurationMs cfg.etcd.heartbeatInterval);
              ELECTION_TIMEOUT = toString (parseDurationMs cfg.etcd.electionTimeout);
            };
          };

          systemd.services.etcd.preStart = lib.mkBefore ''
            set -euo pipefail

            generation_file=/var/lib/etcd/.alanix-bootstrap-generation
            desired_generation=${lib.escapeShellArg (toString cfg.etcd.bootstrapGeneration)}
            current_generation=""

            if [ -f "$generation_file" ]; then
              current_generation="$(cat "$generation_file" 2>/dev/null || true)"
            fi

            if [ "$current_generation" != "$desired_generation" ]; then
              echo "alanix-cluster: resetting /var/lib/etcd for bootstrap generation $desired_generation"
              rm -rf /var/lib/etcd
              install -d -o etcd -g etcd -m 0700 /var/lib/etcd
              printf '%s\n' "$desired_generation" > "$generation_file"
              chown etcd:etcd "$generation_file"
              chmod 0600 "$generation_file"
            fi
          '';

          systemd.services.etcd.serviceConfig.UnsetEnvironment = [
            "ETCD_CLIENT_CERT_AUTH"
            "ETCD_DISCOVERY"
            "ETCD_PEER_CLIENT_CERT_AUTH"
          ];

          systemd.services.etcd.serviceConfig.PermissionsStartOnly = true;

          systemd.services.etcd.after =
            [ "network-online.target" ]
            ++ lib.optional (cfg.transport == "tailscale") "tailscaled.service";

          systemd.services.etcd.wants =
            [ "network-online.target" ]
            ++ lib.optional (cfg.transport == "tailscale") "tailscaled.service";

        })

        (lib.mkIf dashboardCfg.enable (
          serviceExposure.mkConfig {
            serviceName = "cluster-dashboard";
            serviceDescription = "Cluster Dashboard";
            inherit config;
            endpoint = dashboardEndpoint;
            exposeCfg = dashboardCfg.expose;
          }
        ))

        (lib.mkIf anyCaddyExposure {
          services.caddy.enable = true;
          services.caddy.extraConfig = lib.mkAfter ''
            import /run/alanix-cluster/caddy/cluster.caddy
          '';
        })

        (lib.mkIf anyWanExposure {
          networking.firewall.allowedTCPPorts = [ 80 443 ];
        })

        (lib.mkIf (serviceFirewallPorts != [ ]) {
          networking.firewall.allowedTCPPorts = serviceFirewallPorts;
        })

        (lib.mkIf ddnsCfg.enable {
          systemd.services.alanix-cluster-ddns = {
            description = "Alanix cluster leader DDNS (Cloudflare)";
            wantedBy = [ "alanix-cluster-active.target" ];
            partOf = [ "alanix-cluster-active.target" ];
            after = [
              "alanix-cluster-active.target"
              "network-online.target"
              "sops-nix.service"
            ];
            wants = [ "network-online.target" ];
            environment =
              {
                DOMAINS = lib.concatStringsSep " " ddnsCfg.domains;
                IP4_PROVIDER = ddnsCfg.ipv4Provider;
                IP6_PROVIDER = ddnsCfg.ipv6Provider;
                UPDATE_CRON = "@every 5m";
                UPDATE_ON_START = "true";
                DELETE_ON_STOP = "false";
                TTL = "1";
              }
              // lib.optionalAttrs (ddnsCfg.detectionTimeout != null) {
                DETECTION_TIMEOUT = ddnsCfg.detectionTimeout;
              };
            serviceConfig = {
              ExecStart = "${pkgs.cloudflare-ddns}/bin/ddns";
              EnvironmentFile = ddnsCfg.credentialsFile;
              Restart = "on-failure";
              RestartSec = 10;
            };
          };
        })

        (lib.mkIf anyTorExposure {
          services.tor.enable = true;
          services.tor.settings."%include" = "/var/lib/tor/alanix-cluster/cluster.conf";
        })

        (lib.mkIf (anyCaddyExposure || anyTorExposure) {
          systemd.services."alanix-cluster-exposure" = {
            description = "Alanix cluster runtime exposure manager";
            wantedBy = [ "alanix-cluster-active.target" ];
            partOf = [ "alanix-cluster-active.target" ];
            after = exposureUnits ++ lib.optionals anyTailscaleCaddyExposure [ "alanix-tailscale-ready.service" ];
            wants = exposureUnits ++ lib.optionals anyTailscaleCaddyExposure [ "alanix-tailscale-ready.service" ];
            path =
              [ pkgs.coreutils pkgs.systemd ]
              ++ lib.optionals anyCaddyExposure [ config.services.caddy.package ]
              ++ lib.optionals anyTailscaleCaddyExposure [ config.services.tailscale.package ];
            script = "${exposureScript} start";
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              SuccessExitStatus = [ "SIGTERM" ];
              ExecStop = "${exposureScript} stop";
              Restart = "on-failure";
              RestartSec = "5s";
            };
          };
        })
      ]
    )
  );
}
