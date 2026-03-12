{ lib, config, pkgs, ... }:

let
  cfg = config.services.cloudflare-ddns;

  script = pkgs.writeShellApplication {
    name = "cloudflare-ddns";
    runtimeInputs = [ pkgs.curl pkgs.jq ];
    text = ''
      TOKEN=$(cat ${cfg.apiTokenFile})
      IP=$(curl -sf https://api.ipify.org)

      ZONE_ID=$(curl -sf \
        -H "Authorization: Bearer $TOKEN" \
        "https://api.cloudflare.com/client/v4/zones?name=${cfg.zone}" \
        | jq -r '.result[0].id')

      if [ -z "$ZONE_ID" ] || [ "$ZONE_ID" = "null" ]; then
        echo "Error: could not find Cloudflare zone '${cfg.zone}'" >&2
        exit 1
      fi

      for HOSTNAME in ${lib.escapeShellArgs cfg.hostnames}; do
        RECORDS=$(curl -sf \
          -H "Authorization: Bearer $TOKEN" \
          "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=A&name=$HOSTNAME")

        RECORD_ID=$(echo "$RECORDS" | jq -r '.result[0].id // empty')

        if [ -z "$RECORD_ID" ]; then
          echo "Creating A record: $HOSTNAME -> $IP"
          curl -sf -X POST \
            -H "Authorization: Bearer $TOKEN" \
            -H "Content-Type: application/json" \
            --data "$(jq -n \
              --arg name "$HOSTNAME" \
              --arg content "$IP" \
              '{type:"A", name:$name, content:$content, ttl:60, proxied:false}')" \
            "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" > /dev/null
          echo "Created $HOSTNAME -> $IP"
        else
          CURRENT_IP=$(echo "$RECORDS" | jq -r '.result[0].content')
          if [ "$CURRENT_IP" = "$IP" ]; then
            echo "$HOSTNAME is up to date ($IP)"
          else
            echo "Updating $HOSTNAME: $CURRENT_IP -> $IP"
            curl -sf -X PATCH \
              -H "Authorization: Bearer $TOKEN" \
              -H "Content-Type: application/json" \
              --data "$(jq -n --arg content "$IP" '{content:$content}')" \
              "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" > /dev/null
            echo "Updated $HOSTNAME -> $IP"
          fi
        fi
      done
    '';
  };
in
{
  options.services.cloudflare-ddns = {
    enable = lib.mkEnableOption "Cloudflare dynamic DNS updater";

    hostnames = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "FQDNs to keep up to date (A records are created or updated).";
      example = [ "myhost-wg.example.com" ];
    };

    zone = lib.mkOption {
      type = lib.types.str;
      description = "Cloudflare zone name containing the hostnames.";
      example = "example.com";
    };

    apiTokenFile = lib.mkOption {
      type = lib.types.str;
      description = "Path to a file containing the Cloudflare API token (Zone:DNS:Edit permission required).";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.cloudflare-ddns = {
      description = "Update Cloudflare DNS records";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${script}/bin/cloudflare-ddns";
      };
    };

    systemd.timers.cloudflare-ddns = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = "5min";
      };
    };
  };
}
