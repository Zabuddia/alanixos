{ config, lib, pkgs, ... }:

let
  cfg = config.alanix.openclaw.bitcoin;

  bitcoinRead = pkgs.writeShellApplication {
    name = "bitcoin-read";
    runtimeInputs = [ pkgs.openssh ];
    text = ''
      usage() {
        cat >&2 <<'EOF'
Usage: bitcoin-read ACTION [ARGUMENT]

Read-only actions:
  status               Return blockchain synchronization status
  network              Return peer and network status
  transaction TXID     Return a decoded transaction and confirmations
  mempool TXID         Return mempool status for an unconfirmed transaction
  wallets              List loaded and available wallet names
  balance WALLET       Return balances for one loaded wallet
EOF
      }

      action="''${1:-}"
      if [ "$#" -gt 0 ]; then
        shift
      fi

      bitcoin_cli() {
        ssh \
          -o BatchMode=yes \
          -o ConnectTimeout=${toString cfg.connectTimeout} \
          -- ${lib.escapeShellArg cfg.host} \
          sudo -n -u ${lib.escapeShellArg cfg.operatorUser} \
          bitcoin-cli "$@"
      }

      case "$action" in
        status)
          [ "$#" -eq 0 ] || { usage; exit 2; }
          bitcoin_cli getblockchaininfo
          ;;
        network)
          [ "$#" -eq 0 ] || { usage; exit 2; }
          bitcoin_cli getnetworkinfo
          ;;
        transaction|mempool)
          [ "$#" -eq 1 ] || { usage; exit 2; }
          if [[ ! "$1" =~ ^[0-9A-Fa-f]{64}$ ]]; then
            echo "TXID must be exactly 64 hexadecimal characters" >&2
            exit 64
          fi
          if [ "$action" = transaction ]; then
            bitcoin_cli getrawtransaction "$1" true
          else
            bitcoin_cli getmempoolentry "$1"
          fi
          ;;
        wallets)
          [ "$#" -eq 0 ] || { usage; exit 2; }
          bitcoin_cli listwalletdir
          ;;
        balance)
          [ "$#" -eq 1 ] || { usage; exit 2; }
          case "$1" in
            ""|*[!A-Za-z0-9_.+-]*)
              echo "Invalid wallet name" >&2
              exit 64
              ;;
          esac
          bitcoin_cli "-rpcwallet=$1" getbalances
          ;;
        *)
          usage
          exit 2
          ;;
      esac
    '';
  };
in
{
  options.alanix.openclaw.bitcoin = {
    enable = lib.mkEnableOption "strictly read-only Bitcoin node access";

    host = lib.mkOption {
      type = lib.types.strMatching "^[A-Za-z0-9.-]+$";
      default = "alan-node";
      description = "Inventory hostname running bitcoind.";
    };

    operatorUser = lib.mkOption {
      type = lib.types.strMatching "^[A-Za-z_][A-Za-z0-9_-]*$";
      default = "operator";
      description = "Remote nix-bitcoin operator account used for RPC reads.";
    };

    connectTimeout = lib.mkOption {
      type = lib.types.ints.positive;
      default = 10;
      description = "SSH connection timeout in seconds.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.alanix.openclaw.gateway.enable;
        message = "alanix.openclaw.bitcoin requires alanix.openclaw.gateway.enable.";
      }
    ];

    alanix.openclaw.packages = [ bitcoinRead ];
  };
}
