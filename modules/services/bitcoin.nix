{ config, lib, ... }:

let
  cfg = config.alanix.bitcoin;
  inherit (lib) types;
in
{
  options.alanix.bitcoin = {
    enable = lib.mkEnableOption "nix-bitcoin stack";

    configVersion = lib.mkOption {
      type = types.str;
      description = "nix-bitcoin config version.";
    };

    generateSecrets = lib.mkOption {
      type = types.bool;
      description = "Whether nix-bitcoin should generate secrets.";
    };

    operatorName = lib.mkOption {
      type = types.str;
      description = "Name of the nix-bitcoin operator user.";
    };

    useDoas = lib.mkOption {
      type = types.bool;
      description = "Whether to replace sudo with doas for the bitcoin host.";
    };

    hideProcessInformation = lib.mkOption {
      type = types.bool;
      description = "Whether to enable nix-bitcoin's dbus process-information hiding.";
    };

    exposeSshOnionService = lib.mkOption {
      type = types.bool;
      description = "Whether to expose sshd as a Tor onion service.";
    };

    copyRootSshKeysToOperator = lib.mkOption {
      type = types.bool;
      description = "Whether to copy root authorized SSH keys to the operator account.";
    };

    enableNodeInfo = lib.mkOption {
      type = types.bool;
      description = "Whether to enable nix-bitcoin nodeinfo.";
    };

    backupsFrequency = lib.mkOption {
      type = types.str;
      description = "Backup frequency for nix-bitcoin backups.";
    };

    bitcoind = {
      listen = lib.mkOption {
        type = types.bool;
        description = "Whether bitcoind should listen for peer connections.";
      };

      dbCache = lib.mkOption {
        type = types.int;
        description = "Bitcoind dbcache size in MiB.";
      };

      txindex = lib.mkOption {
        type = types.bool;
        description = "Whether txindex should be enabled.";
      };
    };

    fulcrum.enable = lib.mkOption {
      type = types.bool;
      description = "Whether to enable Fulcrum.";
    };

    mempool = {
      enable = lib.mkOption {
        type = types.bool;
        description = "Whether to enable mempool.";
      };

      electrumServer = lib.mkOption {
        type = types.str;
        description = "Electrum server name for mempool.";
      };

      frontend.address = lib.mkOption {
        type = types.str;
        description = "Bind address for the mempool frontend.";
      };

      frontend.port = lib.mkOption {
        type = types.port;
        description = "Port for the mempool frontend.";
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf (!cfg.enable) {
      nix-bitcoin.secretsSetupMethod = "manual";
    })

    (lib.mkIf cfg.enable {
      nix-bitcoin = {
        configVersion = cfg.configVersion;
        generateSecrets = cfg.generateSecrets;
        security.dbusHideProcessInformation = cfg.hideProcessInformation;
        operator = {
          enable = true;
          name = cfg.operatorName;
        };
      };

      security.doas.enable = cfg.useDoas;
      security.sudo.enable = !cfg.useDoas;

      environment.shellAliases = lib.mkIf cfg.useDoas {
        sudo = "doas";
      };

      services.backups.frequency = cfg.backupsFrequency;

      services.bitcoind = {
        enable = true;
        listen = cfg.bitcoind.listen;
        dbCache = cfg.bitcoind.dbCache;
        txindex = cfg.bitcoind.txindex;
      };

      nix-bitcoin.nodeinfo.enable = cfg.enableNodeInfo;
    })

    (lib.mkIf (cfg.enable && cfg.exposeSshOnionService) {
      services.tor.relay.onionServices.sshd = config.nix-bitcoin.lib.mkOnionService { port = 22; };
      nix-bitcoin.onionAddresses.access.${cfg.operatorName} = [ "sshd" ];
    })

    (lib.mkIf (cfg.enable && cfg.copyRootSshKeysToOperator) {
      users.users.${cfg.operatorName}.openssh.authorizedKeys.keys =
        config.users.users.root.openssh.authorizedKeys.keys;
    })

    (lib.mkIf (cfg.enable && cfg.fulcrum.enable) {
      services.fulcrum.enable = true;
    })

    (lib.mkIf (cfg.enable && cfg.mempool.enable) {
      services.mempool = {
        enable = true;
        electrumServer = cfg.mempool.electrumServer;
        frontend = {
          address = cfg.mempool.frontend.address;
          port = cfg.mempool.frontend.port;
        };
      };
    })
  ];
}
