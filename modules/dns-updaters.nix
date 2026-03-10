{ config, lib, pkgs, ... }:
let
  cfg = config.alanix.dnsUpdaters;
  enabledUpdaters = lib.filterAttrs (_: updater: updater.enable) cfg;

  mkUnitName = name:
    "alanix-dns-updater-${lib.replaceStrings [ " " "/" ":" "." ] [ "-" "-" "-" "-" ] name}";

  mkRecordArrayLines = records:
    lib.concatStringsSep "\n" (map (record: ''RECORDS+=(${lib.escapeShellArg record})'') records);
in
{
  options.alanix.dnsUpdaters = lib.mkOption {
    description = "Declarative DNS update jobs (API-based).";
    default = {};
    type = lib.types.attrsOf (lib.types.submodule ({ ... }: {
      options = {
        enable = lib.mkEnableOption "DNS updater job" // {
          default = true;
        };

        provider = lib.mkOption {
          type = lib.types.enum [ "cloudflare" ];
          default = "cloudflare";
          description = "DNS provider backend used for record upserts.";
        };

        zone = lib.mkOption {
          type = lib.types.str;
          description = "DNS zone name (for example fifefin.com).";
        };

        records = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
          description = "Fully-qualified records to upsert to this node's public IPv4.";
        };

        tokenSecret = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "sops secret containing provider API token.";
        };

        interval = lib.mkOption {
          type = lib.types.str;
          default = "2min";
          description = "Systemd OnUnitActiveSec value for periodic updates.";
        };

        startupDelay = lib.mkOption {
          type = lib.types.str;
          default = "45s";
          description = "Systemd OnBootSec delay before first update.";
        };

        ttl = lib.mkOption {
          type = lib.types.ints.unsigned;
          default = 60;
          description = "TTL for A records.";
        };

        proxied = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Whether records should be proxied at provider (if supported).";
        };

        publicIPv4URL = lib.mkOption {
          type = lib.types.str;
          default = "https://api.ipify.org";
          description = "URL used to detect this node's public IPv4.";
        };

        runOnlyWhenPathExists = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Optional path gate (ConditionPathExists) for this update job.";
        };
      };
    }));
  };

  config = {
    assertions = lib.flatten (lib.mapAttrsToList (name: updater: [
      {
        assertion = updater.records != [];
        message = "alanix.dnsUpdaters.${name}.records must not be empty when enabled.";
      }
      {
        assertion = updater.tokenSecret != null;
        message = "alanix.dnsUpdaters.${name}.tokenSecret must be set when enabled.";
      }
    ]) enabledUpdaters);

    systemd.services = lib.mapAttrs'
      (name: updater:
        let
          unitName = mkUnitName name;
          tokenPath = if updater.tokenSecret != null then config.sops.secrets.${updater.tokenSecret}.path else "/dev/null";
        in
        lib.nameValuePair unitName {
          description = "DNS updater job '${name}'";
          after = [ "network-online.target" "sops-install-secrets.service" ];
          wants = [ "network-online.target" "sops-install-secrets.service" ];
          serviceConfig =
            {
              Type = "oneshot";
              User = "root";
              Group = "root";
            }
            // lib.optionalAttrs (updater.runOnlyWhenPathExists != null) {
              ConditionPathExists = updater.runOnlyWhenPathExists;
            };
          path = [ pkgs.curl pkgs.jq pkgs.coreutils ];
          script = ''
            set -euo pipefail

            PROVIDER=${lib.escapeShellArg updater.provider}
            ZONE=${lib.escapeShellArg updater.zone}
            PUBLIC_IP_URL=${lib.escapeShellArg updater.publicIPv4URL}
            API_TOKEN_PATH=${lib.escapeShellArg tokenPath}
            TTL=${toString updater.ttl}
            PROXIED=${if updater.proxied then "true" else "false"}

            RECORDS=()
            ${mkRecordArrayLines updater.records}

            curl_retry() {
              curl -4fsS --retry 5 --retry-delay 2 --retry-all-errors "$@"
            }

            API_TOKEN="$(tr -d '\n' < "$API_TOKEN_PATH")"
            PUBLIC_IP="$(curl_retry "$PUBLIC_IP_URL" || true)"

            if ! jq -en --arg ip "$PUBLIC_IP" '$ip | test("^[0-9]{1,3}(\\.[0-9]{1,3}){3}$")' >/dev/null; then
              echo "DNS updater: unable to determine public IPv4 from $PUBLIC_IP_URL (got '$PUBLIC_IP'); skipping this run" >&2
              exit 0
            fi

            case "$PROVIDER" in
              cloudflare)
                API="https://api.cloudflare.com/client/v4"
                AUTH=(-H "Authorization: Bearer $API_TOKEN" -H "Content-Type: application/json")

                ZONE_ID="$(curl_retry "''${AUTH[@]}" "$API/zones?name=$ZONE" | jq -er '.result[0].id')"

                for RECORD in "''${RECORDS[@]}"; do
                  RECORDS_JSON="$(curl_retry "''${AUTH[@]}" "$API/zones/$ZONE_ID/dns_records?type=A&name=$RECORD" | jq -c '.result')"
                  RECORD_COUNT="$(printf '%s' "$RECORDS_JSON" | jq -r 'length')"

                  BODY="$(jq -n \
                    --arg type "A" \
                    --arg name "$RECORD" \
                    --arg content "$PUBLIC_IP" \
                    --argjson ttl "$TTL" \
                    --argjson proxied "$PROXIED" \
                    '{type: $type, name: $name, content: $content, ttl: $ttl, proxied: $proxied}')"

                  if [ "$RECORD_COUNT" = "0" ]; then
                    curl_retry -X POST "''${AUTH[@]}" "$API/zones/$ZONE_ID/dns_records" --data "$BODY" >/dev/null
                    continue
                  fi

                  RECORD_ID="$(printf '%s' "$RECORDS_JSON" | jq -er '.[0].id')"
                  curl_retry -X PATCH "''${AUTH[@]}" "$API/zones/$ZONE_ID/dns_records/$RECORD_ID" --data "$BODY" >/dev/null

                  # Keep exactly one A record per name to avoid split DNS answers.
                  if [ "$RECORD_COUNT" -gt 1 ]; then
                    while IFS= read -r EXTRA_ID; do
                      [ -n "$EXTRA_ID" ] || continue
                      curl_retry -X DELETE "''${AUTH[@]}" "$API/zones/$ZONE_ID/dns_records/$EXTRA_ID" >/dev/null
                    done < <(printf '%s' "$RECORDS_JSON" | jq -r '.[1:][]?.id')
                  fi
                done
                ;;
              *)
                echo "Unsupported DNS provider: $PROVIDER" >&2
                exit 2
                ;;
            esac
          '';
        })
      enabledUpdaters;

    systemd.timers = lib.mapAttrs'
      (name: updater:
        let
          unitName = mkUnitName name;
        in
        lib.nameValuePair unitName {
          description = "Periodic DNS updater timer '${name}'";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = updater.startupDelay;
            OnUnitActiveSec = updater.interval;
            Unit = "${unitName}.service";
          };
        })
      enabledUpdaters;
  };
}
