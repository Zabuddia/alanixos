#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'EOF'
Usage: ./scripts/show-service-addresses.sh [host]

Print the current service exposure for a host under the Phase A active/passive model.
WAN, WireGuard, and Tor addresses are only shown as live on the active node.
EOF
}

if [[ $# -gt 1 ]]; then
  usage >&2
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
    nix eval --json "path:$repo_root#nixosConfigurations.${host}.config.alanix.cluster" 2>/dev/null
)" || {
  echo "Could not evaluate cluster config for host '${host}'" >&2
  exit 1
}

role="$(jq -r '.role' <<<"$cluster_json")"
wg_ip="$(jq -r '.currentNode.vpnIp' <<<"$cluster_json")"
active_node="$(jq -r '.activeNodeName' <<<"$cluster_json")"

read_onion_cmd='
  shopt -s nullglob
  if compgen -G "/run/tor/onion/*/hostname" > /dev/null; then
    roots=(/run/tor/onion)
  elif compgen -G "/var/lib/tor/onion/*/hostname" > /dev/null; then
    roots=(/var/lib/tor/onion)
  else
    roots=()
  fi

  for root in "${roots[@]}"; do
    for f in "$root"/*/hostname; do
      name="$(basename "$(dirname "$f")")"
      addr="$(tr -d "\r\n" < "$f")"
      printf "%s=%s\n" "$name" "$addr"
    done
  done
'

onion_lines=""
if [[ "$role" == "active" ]]; then
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    onion_lines="$(bash -c "$read_onion_cmd" 2>/dev/null || true)"
  elif command -v sudo >/dev/null 2>&1; then
    onion_lines="$(sudo bash -c "$read_onion_cmd" 2>/dev/null || true)"
  elif command -v doas >/dev/null 2>&1; then
    onion_lines="$(doas bash -c "$read_onion_cmd" 2>/dev/null || true)"
  fi
fi

declare -A onion_by_name=()
while IFS='=' read -r name addr; do
  [[ -n "${name:-}" ]] || continue
  onion_by_name["$name"]="$addr"
done <<<"$onion_lines"

printf "host=%s role=%s active_node=%s wg_ip=%s\n" "$host" "$role" "$active_node" "$wg_ip"
printf "%-14s %-8s %-40s %-28s %s\n" "service" "role" "tor" "wireguard" "wan"
printf "%-14s %-8s %-40s %-28s %s\n" "------" "----" "---" "---------" "---"

while IFS= read -r svc; do
  enabled="$(jq -r --arg s "$svc" '.services[$s].enable // false' <<<"$cluster_json")"
  if [[ "$enabled" != "true" ]]; then
    continue
  fi

  service_role="$role"
  tor_url="none"
  wireguard_url="none"
  wan_url="none"

  if [[ "$role" == "active" ]]; then
    tor_enabled="$(jq -r --arg s "$svc" '.services[$s].access.tor.enable // false' <<<"$cluster_json")"
    if [[ "$tor_enabled" == "true" ]]; then
      onion_name="$(jq -r --arg s "$svc" '.services[$s].access.tor.serviceName // empty' <<<"$cluster_json")"
      onion_host="${onion_by_name[$onion_name]:-}"
      if [[ -n "$onion_host" ]]; then
        tor_url="http://${onion_host}"
      fi
    fi

    wg_enabled="$(jq -r --arg s "$svc" '.services[$s].access.wireguard.enable // false' <<<"$cluster_json")"
    if [[ "$wg_enabled" == "true" ]]; then
      wg_port="$(jq -r --arg s "$svc" '.services[$s].access.wireguard.port // empty' <<<"$cluster_json")"
      wireguard_url="http://${wg_ip}:${wg_port}"
    fi

    wan_enabled="$(jq -r --arg s "$svc" '.services[$s].access.wan.enable // false' <<<"$cluster_json")"
    if [[ "$wan_enabled" == "true" ]]; then
      wan_domain="$(jq -r --arg s "$svc" '.services[$s].access.wan.domain // empty' <<<"$cluster_json")"
      wan_url="https://${wan_domain}"
    fi
  fi

  printf "%-14s %-8s %-40s %-28s %s\n" "$svc" "$service_role" "$tor_url" "$wireguard_url" "$wan_url"
done < <(jq -r '.services | keys[]' <<<"$cluster_json")
