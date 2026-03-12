{ config, lib, pkgs, ... }:
let
  cluster = config.alanix.cluster;
  dns = cluster.settings.dns;
  wanServices =
    lib.filter
      (service: service.access.wan.enable)
      (builtins.attrValues cluster.enabledServices);

  recordManifest = {
    provider = dns.provider;
    zone = cluster.settings.domain;
    publicIpv4Urls = dns.publicIpv4Urls;
    nodeRecord = {
      name = cluster.currentNode.endpointHost;
      ttl = dns.endpointRecord.ttl;
      proxied = dns.endpointRecord.proxied;
    };
    serviceRecords =
      map
        (service: {
          name = service.access.wan.domain;
          ttl = dns.serviceRecords.ttl;
          proxied = dns.serviceRecords.proxied;
        })
        wanServices;
  };

  commonScriptBody = ''
    set -euo pipefail

    TOKEN_FILE=${lib.escapeShellArg config.sops.secrets.${dns.apiTokenSecret}.path}
    MANIFEST=${lib.escapeShellArg "/etc/alanix/cloudflare-records.json"}
    API="https://api.cloudflare.com/client/v4"

    api_token="$(tr -d '\r\n' < "$TOKEN_FILE")"
    [ -n "$api_token" ] || { echo "Cloudflare API token is empty" >&2; exit 1; }

    auth_args=(-H "Authorization: Bearer $api_token" -H "Content-Type: application/json")

    fetch_public_ipv4() {
      local url ip

      while IFS= read -r url; do
        [ -n "$url" ] || continue
        ip="$(curl -4fsS --max-time 10 "$url" 2>/dev/null | tr -d '\r\n' || true)"
        ip="''${ip//[[:space:]]/}"
        if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
          printf '%s\n' "$ip"
          return 0
        fi
      done < <(jq -r '.publicIpv4Urls[]' "$MANIFEST")

      echo "Could not determine public IPv4 address from configured sources" >&2
      return 1
    }

    get_zone_id() {
      local zone
      zone="$(jq -r '.zone' "$MANIFEST")"
      curl -fsS "''${auth_args[@]}" "$API/zones?name=$zone" \
        | jq -er '.result[0].id'
    }

    delete_extra_records() {
      local zone_id="$1"
      local records_json="$2"
      local extra_id

      jq -r '.[1:][]?.id' <<<"$records_json" | while read -r extra_id; do
        [ -n "$extra_id" ] || continue
        curl -fsS -X DELETE "''${auth_args[@]}" "$API/zones/$zone_id/dns_records/$extra_id" >/dev/null || true
      done
    }

    upsert_a_record() {
      local zone_id="$1"
      local name="$2"
      local content="$3"
      local ttl="$4"
      local proxied="$5"
      local body records_json count record_id current_content current_ttl current_proxied

      body="$(
        jq -cn \
          --arg type "A" \
          --arg name "$name" \
          --arg content "$content" \
          --argjson ttl "$ttl" \
          --argjson proxied "$proxied" \
          '{type:$type,name:$name,content:$content,ttl:$ttl,proxied:$proxied}'
      )"

      records_json="$(
        curl -fsS "''${auth_args[@]}" "$API/zones/$zone_id/dns_records?type=A&name=$name" \
          | jq -c '.result'
      )"

      count="$(jq -r 'length' <<<"$records_json")"
      if [ "$count" = "0" ]; then
        curl -fsS -X POST "''${auth_args[@]}" "$API/zones/$zone_id/dns_records" --data "$body" >/dev/null
        echo "Created $name -> $content"
        return 0
      fi

      record_id="$(jq -r '.[0].id' <<<"$records_json")"
      current_content="$(jq -r '.[0].content' <<<"$records_json")"
      current_ttl="$(jq -r '.[0].ttl' <<<"$records_json")"
      current_proxied="$(jq -r '.[0].proxied' <<<"$records_json")"

      if [ "$current_content" = "$content" ] \
        && [ "$current_ttl" = "$ttl" ] \
        && [ "$current_proxied" = "$proxied" ] \
        && [ "$count" = "1" ]; then
        echo "No DNS change for $name"
        return 0
      fi

      curl -fsS -X PATCH "''${auth_args[@]}" "$API/zones/$zone_id/dns_records/$record_id" --data "$body" >/dev/null
      delete_extra_records "$zone_id" "$records_json"
      echo "Updated $name -> $content"
    }
  '';

  nodeSyncScript = pkgs.writeShellScriptBin "alanix-cloudflare-sync-node" ''
    ${commonScriptBody}

    zone_id="$(get_zone_id)"
    public_ip="$(fetch_public_ipv4)"
    record_name="$(jq -r '.nodeRecord.name' "$MANIFEST")"
    record_ttl="$(jq -r '.nodeRecord.ttl' "$MANIFEST")"
    record_proxied="$(jq -r '.nodeRecord.proxied' "$MANIFEST")"

    upsert_a_record "$zone_id" "$record_name" "$public_ip" "$record_ttl" "$record_proxied"
  '';

  serviceSyncScript = pkgs.writeShellScriptBin "alanix-cloudflare-sync-services" ''
    ${commonScriptBody}

    is_active=${if cluster.isActiveNode then "true" else "false"}
    if [ "$is_active" != "true" ]; then
      echo "This host generation is standby; skipping service DNS sync."
      exit 0
    fi

    record_count="$(jq -r '.serviceRecords | length' "$MANIFEST")"
    [ "$record_count" -gt 0 ] || exit 0

    zone_id="$(get_zone_id)"
    public_ip="$(fetch_public_ipv4)"

    jq -c '.serviceRecords[]' "$MANIFEST" | while read -r record; do
      record_name="$(jq -r '.name' <<<"$record")"
      record_ttl="$(jq -r '.ttl' <<<"$record")"
      record_proxied="$(jq -r '.proxied' <<<"$record")"
      upsert_a_record "$zone_id" "$record_name" "$public_ip" "$record_ttl" "$record_proxied"
    done
  '';

  syncAllScript = pkgs.writeShellScriptBin "alanix-cloudflare-sync-all" ''
    set -euo pipefail
    ${lib.getExe nodeSyncScript}
    ${lib.getExe serviceSyncScript}
  '';
in
{
  config = lib.mkIf (dns.provider == "cloudflare") {
    environment.etc."alanix/cloudflare-records.json".text = builtins.toJSON recordManifest;

    environment.systemPackages = [
      nodeSyncScript
      serviceSyncScript
      syncAllScript
      pkgs.curl
      pkgs.jq
    ];

    systemd.services.alanix-cloudflare-node-ddns = {
      description = "Update this node's WireGuard endpoint Cloudflare record";
      after = [
        "network-online.target"
        "sops-install-secrets.service"
      ];
      wants = [
        "network-online.target"
        "sops-install-secrets.service"
      ];
      path = [
        pkgs.coreutils
        pkgs.curl
        pkgs.jq
      ];
      serviceConfig = {
        Type = "oneshot";
      };
      script = "${lib.getExe nodeSyncScript}";
    };

    systemd.timers.alanix-cloudflare-node-ddns = {
      description = "Periodic DDNS update for this node's WireGuard endpoint";
      wantedBy = [ "timers.target" ];
      timerConfig = dns.endpointRecord.timerConfig;
    };

    systemd.services.alanix-cloudflare-service-ddns = {
      description = "Update active public service Cloudflare records";
      after = [
        "network-online.target"
        "sops-install-secrets.service"
      ];
      wants = [
        "network-online.target"
        "sops-install-secrets.service"
      ];
      path = [
        pkgs.coreutils
        pkgs.curl
        pkgs.jq
      ];
      serviceConfig = {
        Type = "oneshot";
      };
      script = "${lib.getExe serviceSyncScript}";
    };

    systemd.timers.alanix-cloudflare-service-ddns = {
      description = "Periodic DDNS update for active public service records";
      wantedBy = lib.optionals (cluster.isActiveNode && wanServices != [ ]) [ "timers.target" ];
      timerConfig = dns.serviceRecords.timerConfig;
    };
  };
}
