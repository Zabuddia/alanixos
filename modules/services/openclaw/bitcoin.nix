{ config, lib, pkgs, ... }:

let
  cfg = config.alanix.openclaw.bitcoin;

  bitcoinRead = pkgs.writeShellApplication {
    name = "bitcoin-read";
    runtimeInputs = [
      pkgs.jq
      pkgs.gnused
      pkgs.openssh
    ];
    text = ''
      usage() {
        cat >&2 <<'EOF'
Usage: bitcoin-read ACTION [ARGUMENT]

Read-only actions:
  status               Return blockchain synchronization status
  network              Return peer and network status
  fulcrum              Return Fulcrum service and synchronization status
  transaction TXID     Return a decoded transaction and confirmations
  mempool TXID         Return mempool status for an unconfirmed transaction
  wallets              List loaded and available wallet names
  balance WALLET       Return balances for one loaded wallet
  transactions WALLET [COUNT]
                       Return recent wallet activity, newest first (default 5)
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

      validate_wallet() {
        case "$1" in
          ""|*[!A-Za-z0-9_.+-]*)
            echo "Invalid wallet name" >&2
            return 64
            ;;
        esac
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
        fulcrum)
          [ "$#" -eq 0 ] || { usage; exit 2; }
          service_state="$(
            ssh -o BatchMode=yes -o ConnectTimeout=${toString cfg.connectTimeout} \
              -- ${lib.escapeShellArg cfg.host} \
              sudo -n systemctl is-active fulcrum.service 2>/dev/null || true
          )"
          bitcoin_height="$(bitcoin_cli getblockcount)"
          latest_synced_line="$(
            ssh -o BatchMode=yes -o ConnectTimeout=${toString cfg.connectTimeout} \
              -- ${lib.escapeShellArg cfg.host} \
              "sudo -n journalctl -u fulcrum.service -g 'Block height [0-9]+, up-to-date' -n 1 --no-pager -o cat" \
              2>/dev/null || true
          )"
          fulcrum_height="$(
            printf '%s\n' "$latest_synced_line" \
              | sed -nE 's/.*Block height ([0-9]+), up-to-date.*/\1/p'
          )"
          jq -n \
            --arg serviceState "$service_state" \
            --arg bitcoinHeight "$bitcoin_height" \
            --arg fulcrumHeight "$fulcrum_height" \
            '{
              serviceState: $serviceState,
              bitcoinHeight: ($bitcoinHeight | tonumber),
              fulcrumHeight: (if $fulcrumHeight == "" then null else ($fulcrumHeight | tonumber) end),
              synchronized: ($serviceState == "active" and $fulcrumHeight != "" and $fulcrumHeight == $bitcoinHeight)
            }'
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
          available="$(bitcoin_cli listwalletdir)"
          loaded="$(bitcoin_cli listwallets)"
          jq -n \
            --argjson directory "$available" \
            --argjson loaded "$loaded" \
            '{available: ($directory.wallets | map(.name)), loaded: $loaded}'
          ;;
        balance)
          [ "$#" -eq 1 ] || { usage; exit 2; }
          validate_wallet "$1"
          bitcoin_cli "-rpcwallet=$1" getbalances
          ;;
        transactions)
          [ "$#" -ge 1 ] && [ "$#" -le 2 ] || { usage; exit 2; }
          wallet="$1"
          count="''${2:-5}"
          validate_wallet "$wallet"
          case "$count" in
            ""|*[!0-9]*) echo "COUNT must be an integer from 1 through 100" >&2; exit 64 ;;
          esac
          [ "$count" -ge 1 ] && [ "$count" -le 100 ] \
            || { echo "COUNT must be an integer from 1 through 100" >&2; exit 64; }
          bitcoin_cli "-rpcwallet=$wallet" listtransactions '\*' "$count" 0 | jq 'reverse'
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
