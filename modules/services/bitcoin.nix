{ config, lib, ... }:

let
  cfg = config.alanix.bitcoin;
  inherit (lib) types;
  hasValue = value: value != null && value != "";
  mainConfigReady =
    hasValue cfg.configVersion
    && hasValue cfg.operatorName
    && hasValue cfg.backupsFrequency
    && cfg.bitcoind.listen != null
    && cfg.bitcoind.dbCache != null
    && cfg.bitcoind.txindex != null;
  mempoolConfigReady =
    hasValue cfg.mempool.electrumServer
    && hasValue cfg.mempool.frontend.address
    && cfg.mempool.frontend.port != null;
in
{
  options.alanix.bitcoin = {
    enable = lib.mkEnableOption "nix-bitcoin stack";

    configVersion = lib.mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "nix-bitcoin config version.";
    };

    generateSecrets = lib.mkOption {
      type = types.bool;
      default = false;
      description = "Whether nix-bitcoin should generate secrets.";
    };

    operatorName = lib.mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Name of the nix-bitcoin operator user.";
    };

    useDoas = lib.mkOption {
      type = types.bool;
      default = false;
      description = "Whether to replace sudo with doas for the bitcoin host.";
    };

    hideProcessInformation = lib.mkOption {
      type = types.bool;
      default = false;
      description = "Whether to enable nix-bitcoin's dbus process-information hiding.";
    };

    exposeSshOnionService = lib.mkOption {
      type = types.bool;
      default = false;
      description = "Whether to expose sshd as a Tor onion service.";
    };

    copyRootSshKeysToOperator = lib.mkOption {
      type = types.bool;
      default = false;
      description = "Whether to copy root authorized SSH keys to the operator account.";
    };

    enableNodeInfo = lib.mkOption {
      type = types.bool;
      default = false;
      description = "Whether to enable nix-bitcoin nodeinfo.";
    };

    backupsFrequency = lib.mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Backup frequency for nix-bitcoin backups.";
    };

    bitcoind = {
      listen = lib.mkOption {
        type = types.nullOr types.bool;
        default = null;
        description = "Whether bitcoind should listen for peer connections.";
      };

      dbCache = lib.mkOption {
        type = types.nullOr types.int;
        default = null;
        description = "Bitcoind dbcache size in MiB.";
      };

      txindex = lib.mkOption {
        type = types.nullOr types.bool;
        default = null;
        description = "Whether txindex should be enabled.";
      };
    };

    fulcrum.enable = lib.mkOption {
      type = types.bool;
      default = false;
      description = "Whether to enable Fulcrum.";
    };

    mempool = {
      enable = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Whether to enable mempool.";
      };

      electrumServer = lib.mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Electrum server name for mempool.";
      };

      frontend.address = lib.mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Bind address for the mempool frontend.";
      };

      frontend.port = lib.mkOption {
        type = types.nullOr types.port;
        default = null;
        description = "Port for the mempool frontend.";
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf (!cfg.enable) {
      nix-bitcoin.secretsSetupMethod = "manual";
    })

    (lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = hasValue cfg.configVersion;
          message = "alanix.bitcoin.configVersion must be set when alanix.bitcoin.enable = true.";
        }
        {
          assertion = hasValue cfg.operatorName;
          message = "alanix.bitcoin.operatorName must be set when alanix.bitcoin.enable = true.";
        }
        {
          assertion = hasValue cfg.backupsFrequency;
          message = "alanix.bitcoin.backupsFrequency must be set when alanix.bitcoin.enable = true.";
        }
        {
          assertion = cfg.bitcoind.listen != null;
          message = "alanix.bitcoin.bitcoind.listen must be set when alanix.bitcoin.enable = true.";
        }
        {
          assertion = cfg.bitcoind.dbCache != null;
          message = "alanix.bitcoin.bitcoind.dbCache must be set when alanix.bitcoin.enable = true.";
        }
        {
          assertion = cfg.bitcoind.txindex != null;
          message = "alanix.bitcoin.bitcoind.txindex must be set when alanix.bitcoin.enable = true.";
        }
        {
          assertion = !cfg.exposeSshOnionService || config.alanix.ssh.enable;
          message = "alanix.bitcoin.exposeSshOnionService requires alanix.ssh.enable = true.";
        }
        {
          assertion = !cfg.mempool.enable || hasValue cfg.mempool.electrumServer;
          message = "alanix.bitcoin.mempool.electrumServer must be set when alanix.bitcoin.mempool.enable = true.";
        }
        {
          assertion = !cfg.mempool.enable || hasValue cfg.mempool.frontend.address;
          message = "alanix.bitcoin.mempool.frontend.address must be set when alanix.bitcoin.mempool.enable = true.";
        }
        {
          assertion = !cfg.mempool.enable || cfg.mempool.frontend.port != null;
          message = "alanix.bitcoin.mempool.frontend.port must be set when alanix.bitcoin.mempool.enable = true.";
        }
      ];
    })

    (lib.mkIf (cfg.enable && mainConfigReady) {
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

    (lib.mkIf (cfg.enable && mainConfigReady && cfg.exposeSshOnionService) {
      services.tor.relay.onionServices.sshd = config.nix-bitcoin.lib.mkOnionService { port = 22; };
      nix-bitcoin.onionAddresses.access.${cfg.operatorName} = [ "sshd" ];
    })

    (lib.mkIf (cfg.enable && mainConfigReady && cfg.copyRootSshKeysToOperator) {
      users.users.${cfg.operatorName}.openssh.authorizedKeys.keys =
        config.users.users.root.openssh.authorizedKeys.keys;
    })

    (lib.mkIf (cfg.enable && cfg.fulcrum.enable) {
      services.fulcrum.enable = true;
    })

    (lib.mkIf (cfg.enable && cfg.mempool.enable && mempoolConfigReady) {
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
