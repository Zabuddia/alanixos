#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

usage() {
  cat <<'EOF'
Usage: ./scripts/update-all-latest.sh [--switch]

Updates all flake inputs to latest versions.

Options:
  --switch   run `nrs` after updating
EOF
}

do_switch=false
if [[ $# -gt 1 ]]; then
  usage
  exit 1
fi
if [[ $# -eq 1 ]]; then
  if [[ "$1" == "--switch" ]]; then
    do_switch=true
  else
    usage
    exit 1
  fi
fi

echo "Updating all flake inputs to latest..."
nix flake update

echo
echo "Done."
echo "  git diff flake.lock"
echo "  nrs"
echo

if [[ "$do_switch" == true ]]; then
  echo "Running nrs..."
  nrs
fi
