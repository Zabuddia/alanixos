#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/generate-sops-config.sh [--stdout|--check]

Render .sops.yaml from secrets/keys.nix.
EOF
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
target="${repo_root}/.sops.yaml"
mode="write"

case "${1-}" in
  "")
    ;;
  --stdout)
    mode="stdout"
    shift
    ;;
  --check)
    mode="check"
    shift
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac

if [ "$#" -ne 0 ]; then
  usage >&2
  exit 1
fi

tmp="$(mktemp)"
cleanup() {
  rm -f "$tmp"
}
trap cleanup EXIT

nix eval --raw --file "${repo_root}/secrets/render-sops-config.nix" > "$tmp"

case "$mode" in
  stdout)
    cat "$tmp"
    ;;
  check)
    if [ -f "$target" ] && cmp -s "$tmp" "$target"; then
      echo ".sops.yaml is up to date"
    else
      echo ".sops.yaml is out of date; run ./scripts/generate-sops-config.sh" >&2
      exit 1
    fi
    ;;
  write)
    if [ -f "$target" ] && cmp -s "$tmp" "$target"; then
      echo "No changes to ${target}"
    else
      mv "$tmp" "$target"
      trap - EXIT
      echo "Wrote ${target}"
    fi
    ;;
esac
