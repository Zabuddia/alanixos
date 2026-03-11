#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'EOF'
Usage: ./scripts/show-service-addresses.sh [host]

Print WAN, cluster-private, and Tor onion addresses for every cluster service.
If an address type is not enabled or unavailable, prints "none".
EOF
}

if [[ $# -gt 1 ]]; then
  usage
  exit 1
fi

host="${1:-$(hostname -s)}"

for cmd in nix jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd" >&2
    exit 1
  fi
done

cluster_json="$(
  cd "$repo_root" &&
    nix eval --json ".#nixosConfigurations.${host}.config.alanix.cluster" 2>/dev/null
)" || {
  echo "Could not evaluate cluster config for host '${host}'" >&2
  exit 1
}

failover_json="$(
  cd "$repo_root" &&
    nix eval --json ".#nixosConfigurations.${host}.config.alanix.serviceFailover.instances" 2>/dev/null
)" || {
  failover_json="{}"
}

cluster_addr="$(jq -r --arg host "$host" '.nodes[$host].clusterAddress // empty' <<<"$cluster_json")"

read_onion_cmd='
  shopt -s nullglob
  for f in /var/lib/tor/onion/*/hostname; do
    name="$(basename "$(dirname "$f")")"
    addr="$(tr -d "\r\n" < "$f")"
    printf "%s=%s\n" "$name" "$addr"
  done
'

onion_lines=""
if jq -e '.services | to_entries | any(.value.torAccess.enable == true)' >/dev/null <<<"$cluster_json"; then
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    onion_lines="$(bash -c "$read_onion_cmd" 2>/dev/null || true)"
  elif command -v doas >/dev/null 2>&1; then
    onion_lines="$(doas bash -c "$read_onion_cmd" 2>/dev/null || true)"
  elif command -v sudo >/dev/null 2>&1; then
    onion_lines="$(sudo bash -c "$read_onion_cmd" 2>/dev/null || true)"
  fi
fi

declare -A onion_by_name=()
while IFS='=' read -r name addr; do
  [[ -n "${name:-}" ]] || continue
  onion_by_name["$name"]="$addr"
done <<<"$onion_lines"

printf "%-14s %-8s %-62s %-28s %s\n" "service" "role" "onion" "cluster" "wan"
printf "%-14s %-8s %-62s %-28s %s\n" "------" "----" "-----" "---------" "---"

while IFS= read -r svc; do
  enabled="$(jq -r --arg s "$svc" '.services[$s].enable // false' <<<"$cluster_json")"

  role="none"
  if [[ "$enabled" == "true" ]] && [[ "$(jq -r --arg s "$svc" '.[$s].enable // false' <<<"$failover_json")" == "true" ]]; then
    marker_path="$(jq -r --arg s "$svc" '.[$s].activeMarkerPath // empty' <<<"$failover_json")"
    if [[ -n "$marker_path" ]]; then
      if [[ -f "$marker_path" ]]; then
        role="active"
      else
        role="standby"
      fi
    fi
  fi

  onion="none"
  if [[ "$enabled" == "true" ]] && [[ "$(jq -r --arg s "$svc" '.services[$s].torAccess.enable // false' <<<"$cluster_json")" == "true" ]]; then
    onion_name="$(jq -r --arg s "$svc" '.services[$s].torAccess.onionServiceName // empty' <<<"$cluster_json")"
    if [[ -n "$onion_name" ]]; then
      onion="${onion_by_name[$onion_name]:-none}"
    fi
  fi

  cluster_url="none"
  if [[ "$enabled" == "true" ]] && [[ "$(jq -r --arg s "$svc" '.services[$s].clusterAccess.enable // false' <<<"$cluster_json")" == "true" ]]; then
    cluster_port="$(jq -r --arg s "$svc" '.services[$s].clusterAccess.port // empty' <<<"$cluster_json")"
    if [[ -n "$cluster_addr" && -n "$cluster_port" ]]; then
      cluster_url="http://${cluster_addr}:${cluster_port}"
    fi
  fi

  wan="none"
  if [[ "$enabled" == "true" ]] && [[ "$(jq -r --arg s "$svc" '.services[$s].wanAccess.enable // false' <<<"$cluster_json")" == "true" ]]; then
    wan_domain="$(jq -r --arg s "$svc" '.services[$s].wanAccess.domain // empty' <<<"$cluster_json")"
    if [[ -n "$wan_domain" ]]; then
      wan="https://${wan_domain}"
    fi
  fi

  printf "%-14s %-8s %-62s %-28s %s\n" "$svc" "$role" "$onion" "$cluster_url" "$wan"
done < <(jq -r '.services | keys[]' <<<"$cluster_json")
