{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:

let
  cfg = config.alanix.bitcoin;
  defaultTrue = lib.mkDefault true;
  enableTorProxy = {
    tor.proxy = defaultTrue;
    tor.enforce = defaultTrue;
  };
  enforceTor = {
    tor.enforce = defaultTrue;
  };
in
{
  imports = [
    (inputs.nix-bitcoin + "/modules/modules.nix")
  ];

  options = {
    alanix.bitcoin = {
      enable = lib.mkEnableOption "Bitcoin Core and its local Alanix services";

      configVersion = lib.mkOption {
        type = lib.types.str;
        default = "0.0.85";
        description = "nix-bitcoin configuration compatibility version.";
      };

      generateSecrets = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Let nix-bitcoin generate its service credentials.";
      };

      operatorName = lib.mkOption {
        type = lib.types.str;
        default = "operator";
        description = "User granted interactive access to nix-bitcoin command-line tools.";
      };

      txIndex = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Build and maintain Bitcoin Core's full transaction index.";
      };

      fulcrum.enable = lib.mkEnableOption "the Fulcrum Electrum server";

      mempool = {
        enable = lib.mkEnableOption "the mempool explorer";

        electrumServer = lib.mkOption {
          type = lib.types.enum [
            "electrs"
            "fulcrum"
          ];
          default = "electrs";
          description = "Electrum backend used by mempool.";
        };

        onionService = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Expose the mempool frontend through a Tor onion service.";
        };

        frontend = {
          listenAddress = lib.mkOption {
            type = lib.types.str;
            default = "127.0.0.1";
            description = "Address on which the mempool frontend listens.";
          };

          port = lib.mkOption {
            type = lib.types.port;
            default = 4080;
            description = "Port on which the mempool frontend listens.";
          };
        };
      };
    };
  };

  config = lib.mkMerge [
    {
      # nix-bitcoin requires a setup method even when all of its services are
      # disabled. Generated secrets override this inert default when enabled.
      nix-bitcoin.secretsSetupMethod = lib.mkDefault "manual";
    }

    (lib.mkIf cfg.enable {
      networking.firewall.enable = true;

      nix-bitcoin = {
        configVersion = cfg.configVersion;
        generateSecrets = cfg.generateSecrets;
        security.dbusHideProcessInformation = true;
        nodeinfo.enable = true;
        operator = {
          enable = true;
          name = cfg.operatorName;
        };
        onionServices = {
          bitcoind.enable = defaultTrue;
          liquidd.enable = defaultTrue;
          electrs.enable = defaultTrue;
          fulcrum.enable = defaultTrue;
          joinmarket-ob-watcher.enable = defaultTrue;
          rtl.enable = defaultTrue;
          mempool-frontend = {
            enable = cfg.mempool.onionService;
            externalPort = 80;
          };
        };
      };

      # Match nix-bitcoin's secure-node preset while allowing this wrapper to be
      # enabled and configured through alanix.bitcoin.
      security.doas.enable = true;
      security.sudo.enable = false;
      environment.shellAliases.sudo = "doas";
      environment.systemPackages = [ pkgs.jq ];

      services = {
        tor = {
          enable = true;
          client.enable = true;
          relay.onionServices.sshd = config.nix-bitcoin.lib.mkOnionService { port = 22; };
        };

        bitcoind = enableTorProxy // {
          enable = true;
          listen = true;
          dbCache = 1000;
          txindex = cfg.txIndex;
        };

        clightning = enableTorProxy;
        lnd = enableTorProxy;
        lightning-loop = enableTorProxy;
        liquidd = enableTorProxy // {
          validatepegin = true;
          listen = true;
        };
        lightning-pool = enableTorProxy;

        electrs = enforceTor;
        nbxplorer = enforceTor;
        rtl = enforceTor;
        joinmarket = enforceTor;
        joinmarket-ob-watcher = enforceTor;
        clightning-rest = enforceTor;

        fulcrum = enforceTor // {
          enable = cfg.fulcrum.enable;
        };

        mempool = enableTorProxy // {
          enable = cfg.mempool.enable;
          electrumServer = cfg.mempool.electrumServer;
          frontend = {
            address = cfg.mempool.frontend.listenAddress;
            port = cfg.mempool.frontend.port;
          };
        };

        backups.frequency = "daily";
      };

      nix-bitcoin.onionAddresses.access.${cfg.operatorName} = [ "sshd" ];

      users.users.${cfg.operatorName}.openssh.authorizedKeys.keys =
        config.users.users.root.openssh.authorizedKeys.keys;
    })
  ];
}
