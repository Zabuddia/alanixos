{ config, lib, pkgs, ... }:
let
  cluster = config.alanix.cluster;
  torServices =
    lib.mapAttrsToList
      (name: service: {
        inherit name service;
      })
      (lib.filterAttrs (_: service: service.access.tor.enable) cluster.enabledServices);

  torServicesWithSecrets =
    lib.filter (entry: entry.service.access.tor.secretKeySecret != null) torServices;

  torSecretNames =
    lib.unique (map (entry: entry.service.access.tor.secretKeySecret) torServicesWithSecrets);

  torServicesMissingSecrets =
    map
      (entry: entry.name)
      (lib.filter (entry: entry.service.access.tor.secretKeySecret == null) torServices);

  torSecretRuntimePath =
    service:
    "/run/alanix/tor-secrets/${service.access.tor.serviceName}/hs_ed25519_secret_key";

  torSecretDecodeScript = pkgs.writeShellScript "alanix-tor-secret-keys" ''
    set -euo pipefail

    install -d -m 0700 /run/alanix
    rm -rf /run/alanix/tor-secrets
    install -d -m 0700 /run/alanix/tor-secrets

    ${lib.concatMapStringsSep "\n" (
      entry:
      let
        service = entry.service;
        serviceName = service.access.tor.serviceName;
        secretPath = config.sops.secrets.${service.access.tor.secretKeySecret}.path;
        outputDir = "/run/alanix/tor-secrets/${serviceName}";
        tmpPath = "${outputDir}/hs_ed25519_secret_key.tmp";
        outputPath = torSecretRuntimePath service;
      in
      ''
        ${lib.getExe' pkgs.coreutils "install"} -d -m 0700 ${lib.escapeShellArg outputDir}
        ${lib.getExe' pkgs.coreutils "base64"} --decode ${lib.escapeShellArg secretPath} > ${lib.escapeShellArg tmpPath}
        key_header="$(${lib.getExe' pkgs.coreutils "cut"} -f1 -d: ${lib.escapeShellArg tmpPath} | ${lib.getExe' pkgs.coreutils "head"} -1)"
        case "$key_header" in
          ("== ed25519v"*"-secret")
            ${lib.getExe' pkgs.coreutils "install"} -m 0400 ${lib.escapeShellArg tmpPath} ${lib.escapeShellArg outputPath}
            ;;
          (*)
            echo >&2 "Invalid Tor hidden-service key for ${serviceName}: expected base64-encoded hs_ed25519_secret_key"
            exit 1
            ;;
        esac
        ${lib.getExe' pkgs.coreutils "rm"} -f ${lib.escapeShellArg tmpPath}
      ''
    ) torServicesWithSecrets}
  '';
in
{
  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = !(torServices != [ ] && !cluster.activeNode.torCapable);
          message = "Tor-enabled services require the configured active node to have torCapable = true.";
        }
        {
          assertion = torServicesMissingSecrets == [ ];
          message =
            "Tor-enabled services must set access.tor.secretKeySecret to a sops secret containing base64-encoded hs_ed25519_secret_key data. Missing: "
            + lib.concatStringsSep ", " torServicesMissingSecrets;
        }
      ];
    }

    (lib.mkIf (torSecretNames != [ ]) {
      sops.secrets =
        builtins.listToAttrs
          (map
            (secretName: {
              name = secretName;
              value = {
                owner = "root";
                group = "root";
                mode = "0400";
                restartUnits = [
                  "alanix-tor-secret-keys.service"
                  "tor.service"
                ];
              };
            })
            torSecretNames);
    })

    (lib.mkIf (cluster.isActiveNode && torServices != [ ]) {
      environment.systemPackages = [ pkgs.tor ];

      systemd.services.alanix-tor-secret-keys = {
        description = "Decode Alanix Tor hidden-service keys";
        path = [ pkgs.coreutils ];
        after = [ "sops-install-secrets.service" ];
        wants = [ "sops-install-secrets.service" ];
        before = [ "tor.service" ];
        requiredBy = [ "tor.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = builtins.readFile torSecretDecodeScript;
      };

      services.tor = {
        enable = true;
        relay.onionServices =
          builtins.listToAttrs
            (map
              (entry:
                let
                  service = entry.service;
                in
                {
                  name = service.access.tor.serviceName;
                  value = {
                    version = service.access.tor.version;
                    map = [
                      {
                        port = service.access.tor.httpVirtualPort;
                        target = {
                          addr = "127.0.0.1";
                          port = service.access.tor.httpLocalPort;
                        };
                      }
                      {
                        port = service.access.tor.httpsVirtualPort;
                        target = {
                          addr = "127.0.0.1";
                          port = service.access.tor.httpsLocalPort;
                        };
                      }
                    ];
                    secretKey = torSecretRuntimePath service;
                  };
                })
              torServicesWithSecrets);
      };
    })
  ];
}
