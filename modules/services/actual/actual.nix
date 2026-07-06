{ config, lib, pkgs, inputs, ... }:
let
  cfg = config.alanix.actual;
  clusterCfg = cfg.cluster;
  serviceExposure = import ../../../lib/mkServiceExposure.nix { inherit lib pkgs; };
  serviceIdentity = import ../../../lib/mkServiceIdentity.nix { inherit lib; };

  exposeCfg = cfg.expose;
  inherit (serviceIdentity) hasValue;

  # Fixed by the upstream services.actual NixOS module (StateDirectory = "actual")
  dataDir = "/var/lib/actual";

  endpoint = {
    address = cfg.listenAddress;
    port = cfg.port;
    protocol = "http";
  };

  baseConfigReady = hasValue cfg.listenAddress && cfg.port != null;
  reconcileEnabled = cfg.passwordSecret != null && baseConfigReady;

  passfilePath =
    if cfg.passwordSecret != null
    then config.sops.secrets.${cfg.passwordSecret}.path
    else "";

  # ESM script that bootstraps/updates the server password using actual-server's
  # compiled account-db chunk. The chunk filename is content-hashed by upstream's
  # build, so the shell wrapper discovers it at runtime.
  reconcileScript = pkgs.writeTextFile {
    name = "actual-reconcile.mjs";
    text = ''
      import { readFileSync } from 'node:fs';
      import { pathToFileURL } from 'node:url';

      const passFile = process.argv[2];
      const accountDbChunk = process.argv[3];
      const password = readFileSync(passFile, 'utf8').trimEnd();

      if (!password) {
        process.stderr.write('Actual password file is empty\n');
        process.exit(1);
      }

      const {
        _: changePassword,
        d: needsBootstrap,
        t: bootstrap,
      } = await import(pathToFileURL(accountDbChunk).href);

      if (needsBootstrap()) {
        const { error } = await bootstrap({ password });
        if (error) {
          process.stderr.write('Actual bootstrap failed: ' + error + '\n');
          process.exit(1);
        }
        process.stdout.write('Actual password bootstrapped.\n');
      } else {
        const { error } = changePassword(password);
        if (error) {
          process.stderr.write('Actual password update failed: ' + error + '\n');
          process.exit(1);
        }
        process.stdout.write('Actual password updated.\n');
      }
    '';
  };

  setupScript = pkgs.writeShellScript "alanix-actual-setup" ''
    set -euo pipefail

    server_files=${lib.escapeShellArg "${dataDir}/server-files"}
    pass_file=${lib.escapeShellArg passfilePath}
    sync_server=${lib.escapeShellArg "${cfg.package}/lib/actual/packages/sync-server"}

    mkdir -p "$server_files"

    account_db_chunk="$(${pkgs.findutils}/bin/find "$sync_server/chunks" -maxdepth 1 -type f -name 'account-db-*.js' -print -quit)"
    if [ -z "$account_db_chunk" ]; then
      echo "Could not find Actual account-db chunk in $sync_server/chunks" >&2
      exit 1
    fi

    ACTUAL_DATA_DIR=${lib.escapeShellArg dataDir} \
      ${pkgs.nodejs_22}/bin/node "$sync_server/scripts/run-migrations.js" up

    ACTUAL_DATA_DIR=${lib.escapeShellArg dataDir} \
      ${pkgs.nodejs_22}/bin/node ${reconcileScript} "$pass_file" "$account_db_chunk"

    chown -R actual:actual ${lib.escapeShellArg dataDir}
    chmod -R u=rwX,go= ${lib.escapeShellArg dataDir}
    echo "Actual password reconciled."
  '';
in
{
  options.alanix.actual = {
    enable = lib.mkEnableOption "Actual (Alanix)";

    package = lib.mkOption {
      type = lib.types.package;
      default = inputs.nixpkgs-unstable.legacyPackages.${pkgs.stdenv.hostPlatform.system}.actual-server;
      defaultText = lib.literalExpression "inputs.nixpkgs-unstable.legacyPackages.\${pkgs.stdenv.hostPlatform.system}.actual-server";
      description = "The actual-server package to use. Defaults to the unstable channel.";
    };

    listenAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Bind address for Actual.";
    };

    port = lib.mkOption {
      type = lib.types.nullOr lib.types.port;
      default = null;
      description = "HTTP port for Actual.";
    };

    backupDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Cluster backup staging directory. Required when cluster.enable = true.";
    };

    passwordSecret = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Name of a sops secret containing the plaintext Actual server password.
        When set, the password is bootstrapped on first start and reconciled
        (force-updated) before every subsequent start.
      '';
    };

    settings = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = "Extra settings merged into services.actual.settings.";
    };

    cluster = {
      enable = lib.mkEnableOption "cluster-manage Actual through alanix.cluster";

      backupInterval = lib.mkOption {
        type = lib.types.str;
        default = "1h";
      };

      maxBackupAge = lib.mkOption {
        type = lib.types.str;
        default = "6h";
      };
    };

    expose = serviceExposure.mkOptions {
      serviceName = "actual";
      serviceDescription = "Actual";
      defaultPublicPort = 80;
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions =
        [
          {
            assertion = hasValue cfg.listenAddress;
            message = "alanix.actual.listenAddress must be set when alanix.actual.enable = true.";
          }
          {
            assertion = cfg.port != null;
            message = "alanix.actual.port must be set when alanix.actual.enable = true.";
          }
          {
            assertion = cfg.backupDir == null || lib.hasPrefix "/" cfg.backupDir;
            message = "alanix.actual.backupDir must be an absolute path when set.";
          }
          {
            assertion = !clusterCfg.enable || cfg.backupDir != null;
            message = "alanix.actual.cluster.enable requires alanix.actual.backupDir to be set.";
          }
          {
            assertion = cfg.passwordSecret == null || lib.hasAttrByPath [ "sops" "secrets" cfg.passwordSecret ] config;
            message = "alanix.actual.passwordSecret must reference a declared sops secret.";
          }
        ]
        ++ serviceExposure.mkAssertions {
          inherit config endpoint exposeCfg;
          optionPrefix = "alanix.actual.expose";
        };

      services.actual = lib.mkIf baseConfigReady {
        enable = true;
        package = cfg.package;
        settings = {
          hostname = cfg.listenAddress;
          port = cfg.port;
        } // cfg.settings;
      };

      # Override DynamicUser to use a static system account — consistent with
      # other alanix services and required for sops secret ownership to work.
      systemd.services.actual.serviceConfig = lib.mkIf baseConfigReady {
        DynamicUser = lib.mkForce false;
        User = lib.mkForce "actual";
        Group = lib.mkForce "actual";
      };

      users.groups.actual = { };
      users.users.actual = {
        isSystemUser = true;
        group = "actual";
        home = dataDir;
        createHome = false;
      };

      systemd.services.actual-setup = lib.mkIf reconcileEnabled {
        description = "Reconcile Actual server password";
        before = [ "actual.service" ];
        requiredBy = [ "actual.service" ];
        after = [ "sops-nix.service" "systemd-tmpfiles-setup.service" ];
        wants = [ "sops-nix.service" "systemd-tmpfiles-setup.service" ];

        serviceConfig = {
          Type = "oneshot";
          User = "root";
          Group = "root";
          UMask = "0077";
        };

        script = "${setupScript}";
      };

      systemd.services.actual.restartTriggers = lib.mkIf (cfg.passwordSecret != null) [
        (builtins.toJSON { inherit (cfg) passwordSecret; })
      ];
    }

    (lib.mkIf (baseConfigReady && !clusterCfg.enable) (
      serviceExposure.mkConfig {
        inherit config endpoint exposeCfg;
        serviceName = "actual";
        serviceDescription = "Actual";
      }
    ))
  ]);
}
