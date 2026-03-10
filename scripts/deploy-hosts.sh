#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/deploy-hosts.sh [options] <host> [<host> ...]

Deploy one or more nixosConfigurations to remote machines using nixos-rebuild.

Options:
  --build-on-target   Build on the remote host instead of the local machine
  --user USER         SSH username to use when no explicit target is set
  --ssh HOST=TARGET   Override the SSH target for one flake host
  --action ACTION     nixos-rebuild action: switch (default), boot, test, dry-activate
  -h, --help          Show this help

Examples:
  ./scripts/deploy-hosts.sh randy-big-nixos
  ./scripts/deploy-hosts.sh randy-big-nixos alan-big-nixos
  ./scripts/deploy-hosts.sh --build-on-target randy-big-nixos
  ./scripts/deploy-hosts.sh --ssh randy-big-nixos=buddia@100.64.0.10 randy-big-nixos
EOF
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
default_user="${TARGET_USER:-buddia}"
action="switch"
build_on_target=0
hosts=()

declare -A ssh_targets=()

warn_untracked_files() {
  local untracked

  if ! git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    return
  fi

  untracked="$(git -C "$repo_root" ls-files --others --exclude-standard)"
  if [ -n "$untracked" ]; then
    cat <<EOF
Warning: untracked files are not included in flake deployments.
Add them to git first if the remote build needs them:

$untracked
EOF
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --build-on-target)
      build_on_target=1
      shift
      ;;
    --user)
      default_user="$2"
      shift 2
      ;;
    --ssh)
      if [[ "$2" != *=* ]]; then
        echo "--ssh expects HOST=TARGET" >&2
        exit 1
      fi
      ssh_targets["${2%%=*}"]="${2#*=}"
      shift 2
      ;;
    --action)
      case "$2" in
        switch|boot|test|dry-activate)
          action="$2"
          ;;
        *)
          echo "Unsupported action: $2" >&2
          exit 1
          ;;
      esac
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      hosts+=("$1")
      shift
      ;;
  esac
done

if [ "$#" -gt 0 ]; then
  hosts+=("$@")
fi

if [ "${#hosts[@]}" -eq 0 ]; then
  usage >&2
  exit 1
fi

warn_untracked_files

for host in "${hosts[@]}"; do
  ssh_target="${ssh_targets[$host]:-${default_user}@${host}}"

  cmd=(
    nixos-rebuild
    "$action"
    --flake "${repo_root}#${host}"
    --target-host "$ssh_target"
    --sudo
  )

  if [ "$build_on_target" -eq 1 ]; then
    cmd+=(--build-host "$ssh_target")
  fi

  echo "Deploying ${host} via ${ssh_target}"
  "${cmd[@]}"
done
