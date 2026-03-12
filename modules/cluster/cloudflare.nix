{ config, lib, pkgs, ... }:
let
  cluster = config.alanix.cluster;
  services =
    lib.filter
      (service: service.access.wan.enable)
      (builtins.attrValues cluster.enabledServices);

  recordManifest = {
    provider = cluster.settings.dns.provider;
    zone = cluster.settings.domain;
    activeNode = cluster.activeNodeName;
    records =
      map
        (service: {
          name = service.access.wan.domain;
          proxied = false;
        })
        services;
  };

  syncScript = pkgs.writeShellScriptBin "alanix-cloudflare-sync-active" ''
    set -euo pipefail

    TOKEN_FILE=${lib.escapeShellArg config.sops.secrets.${cluster.settings.dns.apiTokenSecret}.path}
    MANIFEST=${lib.escapeShellArg "/etc/alanix/cloudflare-records.json"}
    API_TOKEN="$(tr -d '\r\n' < "$TOKEN_FILE")"
    PUBLIC_IP="$(curl -4fsS https://api.ipify.org)"
    ZONE="$(jq -r '.zone' "$MANIFEST")"

    [ -n "$API_TOKEN" ] || { echo "Cloudflare API token is empty" >&2; exit 1; }
    printf '%s' "$PUBLIC_IP" | jq -enR 'select(test("^[0-9]{1,3}(\\.[0-9]{1,3}){3}$"))' >/dev/null

    API="https://api.cloudflare.com/client/v4"
    AUTH=(-H "Authorization: Bearer $API_TOKEN" -H "Content-Type: application/json")

    ZONE_ID="$(
      curl -fsS "''${AUTH[@]}" "$API/zones?name=$ZONE" \
        | jq -er '.result[0].id'
    )"

    jq -c '.records[]' "$MANIFEST" | while read -r record; do
      name="$(jq -r '.name' <<<"$record")"
      proxied="$(jq -r '.proxied' <<<"$record")"

      body="$(
        jq -cn \
          --arg type "A" \
          --arg name "$name" \
          --arg content "$PUBLIC_IP" \
          --argjson ttl 60 \
          --argjson proxied "$proxied" \
          '{type:$type,name:$name,content:$content,ttl:$ttl,proxied:$proxied}'
      )"

      records_json="$(
        curl -fsS "''${AUTH[@]}" "$API/zones/$ZONE_ID/dns_records?type=A&name=$name" \
          | jq -c '.result'
      )"

      count="$(jq -r 'length' <<<"$records_json")"
      if [ "$count" = "0" ]; then
        curl -fsS -X POST "''${AUTH[@]}" "$API/zones/$ZONE_ID/dns_records" --data "$body" >/dev/null
      else
        record_id="$(jq -r '.[0].id' <<<"$records_json")"
        curl -fsS -X PATCH "''${AUTH[@]}" "$API/zones/$ZONE_ID/dns_records/$record_id" --data "$body" >/dev/null
        if [ "$count" -gt 1 ]; then
          jq -r '.[1:][]?.id' <<<"$records_json" | while read -r extra_id; do
            [ -n "$extra_id" ] || continue
            curl -fsS -X DELETE "''${AUTH[@]}" "$API/zones/$ZONE_ID/dns_records/$extra_id" >/dev/null || true
          done
        fi
      fi
      echo "Updated $name -> $PUBLIC_IP"
    done
  '';
in
{
  config = {
    environment.etc."alanix/cloudflare-records.json".text = builtins.toJSON recordManifest;
    environment.systemPackages = [
      syncScript
      pkgs.jq
    ];
  };
}
