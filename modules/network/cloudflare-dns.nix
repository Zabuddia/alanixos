{ config, lib, pkgs, ... }:
let
  cfg = config.alanix.cloudflare.dns;
  types = lib.types;

  supportedRecordTypes = [
    "A"
    "AAAA"
    "CAA"
    "CNAME"
    "MX"
    "NS"
    "TXT"
  ];

  supportedProxiedTypes = [
    "A"
    "AAAA"
    "CNAME"
  ];

  recordIdentity =
    zoneName: record:
    "${zoneName}:${record.type}:${record.name}:${record.content}:${
      if record.priority == null then "null" else toString record.priority
    }";

  declaredRecordIdentities =
    lib.flatten (
      lib.mapAttrsToList
        (zoneName: zoneCfg: map (record: recordIdentity zoneName record) zoneCfg.records)
        cfg.zones
    );

  zonesFile = pkgs.writeText "alanix-cloudflare-dns-records.json" (
    builtins.toJSON {
      zones = lib.mapAttrs (_: zoneCfg: {
        inherit (zoneCfg) deleteUnmanaged;
        records = map
          (record:
            {
              inherit (record)
                name
                type
                content
                ttl
                ;
            }
            // lib.optionalAttrs (record.priority != null) {
              priority = record.priority;
            }
            // lib.optionalAttrs (record.proxied != null) {
              proxied = record.proxied;
            }
            // lib.optionalAttrs (record.comment != null) {
              comment = record.comment;
            })
          zoneCfg.records;
      }) cfg.zones;
    }
  );

  reconcileScript = pkgs.writeText "alanix-cloudflare-dns.py" ''
    #!/usr/bin/env python3
    import json
    import os
    import sys
    import urllib.error
    import urllib.parse
    import urllib.request

    API_BASE = "https://api.cloudflare.com/client/v4"
    MANAGED_COMMENT_PREFIX = "alanix.cloudflare.dns"


    class CloudflareError(Exception):
        pass


    def load_config(path):
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)


    def require_token():
        token = os.environ.get("CLOUDFLARE_API_TOKEN")
        if not token:
            raise CloudflareError("CLOUDFLARE_API_TOKEN is not set")
        return token


    def request(token, method, path, params=None, payload=None):
        url = API_BASE + path
        if params:
            url += "?" + urllib.parse.urlencode(params)

        data = None
        headers = {
            "Authorization": "Bearer " + token,
            "Content-Type": "application/json",
        }
        if payload is not None:
            data = json.dumps(payload).encode("utf-8")

        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=30) as response:
                body = json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            details = exc.read().decode("utf-8", errors="replace")
            raise CloudflareError(f"{method} {path} failed: HTTP {exc.code}: {details}") from exc
        except urllib.error.URLError as exc:
            raise CloudflareError(f"{method} {path} failed: {exc}") from exc

        if not body.get("success", False):
            raise CloudflareError(f"{method} {path} failed: {body.get('errors', body)}")
        return body


    def paged(token, path, params=None):
        params = dict(params or {})
        params.setdefault("per_page", 100)
        page = 1
        results = []
        while True:
            params["page"] = page
            body = request(token, "GET", path, params=params)
            results.extend(body.get("result", []))
            info = body.get("result_info") or {}
            total_pages = info.get("total_pages")
            if total_pages is None or page >= total_pages:
                return results
            page += 1


    def zone_id(token, zone_name):
        zones = paged(token, "/zones", {"name": zone_name, "status": "active"})
        matches = [zone for zone in zones if zone.get("name") == zone_name]
        if len(matches) != 1:
            raise CloudflareError(f"expected exactly one active Cloudflare zone named {zone_name}, got {len(matches)}")
        return matches[0]["id"]


    def fqdn(zone_name, name):
        clean = name.rstrip(".")
        if clean == "@" or clean == zone_name:
            return zone_name
        if clean.endswith("." + zone_name):
            return clean
        return clean + "." + zone_name


    def desired_payload(zone_name, record):
        payload = {
            "type": record["type"],
            "name": fqdn(zone_name, record["name"]),
            "content": record["content"],
            "ttl": int(record.get("ttl", 1)),
            "comment": MANAGED_COMMENT_PREFIX,
        }
        if record.get("priority") is not None:
            payload["priority"] = int(record["priority"])
        if record.get("proxied") is not None:
            payload["proxied"] = bool(record["proxied"])
        if record.get("comment"):
            payload["comment"] = MANAGED_COMMENT_PREFIX + ": " + record["comment"]
        return payload


    def identity(record):
        return (
            record.get("type"),
            record.get("name"),
            record.get("content"),
            record.get("priority"),
        )


    def is_managed(record):
        return (record.get("comment") or "").startswith(MANAGED_COMMENT_PREFIX)


    def needs_update(existing, payload):
        for key, value in payload.items():
            if key == "ttl":
                if int(existing.get(key, 0)) != int(value):
                    return True
            elif existing.get(key) != value:
                return True
        return False


    def create_record(token, zone_id, payload):
        created = request(token, "POST", f"/zones/{zone_id}/dns_records", payload=payload)["result"]
        print(f"created {payload['type']} {payload['name']} -> {payload['content']}")
        return created


    def update_record(token, zone_id, existing, payload):
        updated = request(token, "PATCH", f"/zones/{zone_id}/dns_records/{existing['id']}", payload=payload)["result"]
        print(f"updated {payload['type']} {payload['name']} -> {payload['content']}")
        return updated


    def delete_record(token, zone_id, record, reason):
        request(token, "DELETE", f"/zones/{zone_id}/dns_records/{record['id']}")
        print(f"deleted {record.get('type')} {record.get('name')} -> {record.get('content')} ({reason})")


    def reconcile_zone(token, zone_name, zone_cfg):
        zid = zone_id(token, zone_name)
        desired = [desired_payload(zone_name, record) for record in zone_cfg.get("records", [])]
        desired_by_identity = {identity(record): record for record in desired}

        existing = paged(token, f"/zones/{zid}/dns_records")

        for payload in desired:
            matches = [record for record in existing if identity(record) == identity(payload)]
            if matches:
                primary = matches[0]
                if needs_update(primary, payload):
                    primary = update_record(token, zid, primary, payload)
                else:
                    print(f"ok {payload['type']} {payload['name']} -> {payload['content']}")

                for duplicate in matches[1:]:
                    if is_managed(duplicate):
                        delete_record(token, zid, duplicate, "managed duplicate")
                    else:
                        print(
                            f"left unmanaged duplicate {duplicate.get('type')} "
                            f"{duplicate.get('name')} -> {duplicate.get('content')}"
                        )
            else:
                create_record(token, zid, payload)

        if zone_cfg.get("deleteUnmanaged", True):
            for record in existing:
                if is_managed(record) and identity(record) not in desired_by_identity:
                    delete_record(token, zid, record, "removed from declaration")


    def main():
        if len(sys.argv) != 2:
            raise CloudflareError("usage: alanix-cloudflare-dns.py <records.json>")
        token = require_token()
        config = load_config(sys.argv[1])
        zones = config.get("zones") or {}
        for zone_name, zone_cfg in sorted(zones.items()):
            reconcile_zone(token, zone_name, zone_cfg)


    if __name__ == "__main__":
        try:
            main()
        except CloudflareError as exc:
            print(f"alanix-cloudflare-dns: {exc}", file=sys.stderr)
            sys.exit(1)
  '';

  serviceTarget = if cfg.cluster.enable then "alanix-cluster-active.target" else "multi-user.target";
in
{
  options.alanix.cloudflare.dns = {
    enable = lib.mkEnableOption "declarative Cloudflare DNS reconciliation";

    credentialsFile = lib.mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Environment file containing CLOUDFLARE_API_TOKEN.";
    };

    interval = lib.mkOption {
      type = types.nullOr types.str;
      default = "15m";
      description = "Periodic reconciliation interval. Set to null to run only when the service starts.";
    };

    cluster.enable = lib.mkOption {
      type = types.bool;
      default = false;
      description = "Attach DNS reconciliation to alanix-cluster-active.target.";
    };

    zones = lib.mkOption {
      type = types.attrsOf (types.submodule ({ name, ... }: {
        options = {
          deleteUnmanaged = lib.mkOption {
            type = types.bool;
            default = true;
            description = ''
              Delete records previously created by this module when they are
              removed from the declaration. Unmarked Cloudflare records are left alone.
            '';
          };

          records = lib.mkOption {
            type = types.listOf (types.submodule {
              options = {
                name = lib.mkOption {
                  type = types.str;
                  description = "Record name, either relative to the zone, @, or a full domain name.";
                };

                type = lib.mkOption {
                  type = types.enum supportedRecordTypes;
                  description = "DNS record type.";
                };

                content = lib.mkOption {
                  type = types.str;
                  description = "DNS record content.";
                };

                ttl = lib.mkOption {
                  type = types.int;
                  default = 1;
                  description = "TTL in seconds. Cloudflare uses 1 for automatic TTL.";
                };

                priority = lib.mkOption {
                  type = types.nullOr types.int;
                  default = null;
                  description = "MX priority.";
                };

                proxied = lib.mkOption {
                  type = types.nullOr types.bool;
                  default = null;
                  description = "Cloudflare proxy state for A, AAAA, and CNAME records.";
                };

                comment = lib.mkOption {
                  type = types.nullOr types.str;
                  default = null;
                  description = "Optional human-readable Cloudflare record comment.";
                };
              };
            });
            default = [ ];
            description = "Records managed for the Cloudflare zone ${name}.";
          };
        };
      }));
      default = { };
      description = "Cloudflare zones and DNS records to reconcile.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions =
      [
        {
          assertion = cfg.credentialsFile != null;
          message = "alanix.cloudflare.dns.credentialsFile must be set.";
        }
        {
          assertion = cfg.zones != { };
          message = "alanix.cloudflare.dns.zones must not be empty.";
        }
        {
          assertion = declaredRecordIdentities == lib.unique declaredRecordIdentities;
          message = "alanix.cloudflare.dns records must be unique by zone, type, name, content, and priority.";
        }
        {
          assertion = !cfg.cluster.enable || config.alanix.cluster.enable;
          message = "alanix.cloudflare.dns.cluster.enable requires alanix.cluster.enable.";
        }
      ]
      ++ lib.flatten (
        lib.mapAttrsToList
          (zoneName: zoneCfg:
            map
              (record: {
                assertion =
                  record.name != ""
                  && record.content != ""
                  && (record.type != "MX" || record.priority != null)
                  && (record.proxied == null || builtins.elem record.type supportedProxiedTypes);
                message = "Invalid Cloudflare DNS record ${record.type} ${record.name} in zone ${zoneName}.";
              })
              zoneCfg.records)
          cfg.zones
      );

    systemd.services.alanix-cloudflare-dns = {
      description = "Alanix declarative Cloudflare DNS";
      wantedBy = [ serviceTarget ];
      partOf = lib.optional cfg.cluster.enable serviceTarget;
      after =
        [
          "network-online.target"
          "sops-nix.service"
        ]
        ++ lib.optional cfg.cluster.enable serviceTarget;
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.python3}/bin/python3 ${reconcileScript} ${zonesFile}";
        EnvironmentFile = cfg.credentialsFile;
      };
    };

    systemd.timers.alanix-cloudflare-dns = lib.mkIf (cfg.interval != null) {
      description = "Periodic Alanix declarative Cloudflare DNS reconciliation";
      wantedBy = [ serviceTarget ];
      partOf = lib.optional cfg.cluster.enable serviceTarget;
      timerConfig = {
        OnUnitActiveSec = cfg.interval;
        Unit = "alanix-cloudflare-dns.service";
      };
    };
  };
}
