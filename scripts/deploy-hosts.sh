#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/deploy-hosts.sh [options] <host> [<host> ...]

Push the current branch, update the repo on remote hosts, and rebuild there.

Options:
  --user USER         SSH username to use when no explicit target is set
  --ssh HOST=TARGET   Override the SSH target for one flake host
  --remote-repo PATH  Repo path on the remote host (default: ~/.nixos)
  --action ACTION     nixos-rebuild action: switch (default), boot, test, dry-activate
  --branch BRANCH     Git branch to deploy (default: current branch)
  --no-push           Do not push before deploying; use current remote branch state
  -h, --help          Show this help

Examples:
  ./scripts/deploy-hosts.sh randy-big-nixos
  ./scripts/deploy-hosts.sh randy-big-nixos alan-big-nixos
  ./scripts/deploy-hosts.sh --ssh randy-big-nixos=buddia@100.64.0.10 randy-big-nixos
EOF
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
default_user="${TARGET_USER:-buddia}"
remote_repo=".nixos"
action="switch"
branch=""
push_first=1
hosts=()

declare -A ssh_targets=()

die() {
  echo "$*" >&2
  exit 1
}

local_repo_status() {
  git -C "$repo_root" status --short
}

ensure_pushable_tree() {
  local status

  if ! git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    die "deploy-hosts.sh must run from inside a git worktree"
  fi

  status="$(local_repo_status)"
  if [ -n "$status" ]; then
    cat <<EOF >&2
Refusing to deploy from a dirty git tree.
Commit, stash, or discard changes first:

$status
EOF
    exit 1
  fi
}

warn_if_dirty_without_push() {
  local status

  status="$(local_repo_status)"
  if [ -n "$status" ]; then
    cat <<EOF
Warning: local git tree is dirty, but --no-push was used.
These local changes will not be deployed:

$status
EOF
  fi
}

resolve_branch() {
  local current_branch

  if [ -n "$branch" ]; then
    return
  fi

  current_branch="$(git -C "$repo_root" branch --show-current)"
  if [ -z "$current_branch" ]; then
    die "Cannot determine current branch; set one with --branch"
  fi

  branch="$current_branch"
}

push_branch() {
  echo "Pushing branch ${branch} to origin"
  git -C "$repo_root" push origin "HEAD:refs/heads/${branch}"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
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
    --remote-repo)
      remote_repo="$2"
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
    --branch)
      branch="$2"
      shift 2
      ;;
    --no-push)
      push_first=0
      shift
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

resolve_branch

if [ "$push_first" -eq 1 ]; then
  ensure_pushable_tree
  push_branch
else
  warn_if_dirty_without_push
fi

read -r -d '' remote_script <<'EOF' || true
set -euo pipefail

repo_arg="$1"
branch="$2"
host="$3"
action="$4"

case "$repo_arg" in
  "~")
    repo="$HOME"
    ;;
  "~/"*)
    repo="$HOME/${repo_arg#~/}"
    ;;
  /*)
    repo="$repo_arg"
    ;;
  *)
    repo="$HOME/$repo_arg"
    ;;
esac

if [ ! -d "$repo/.git" ]; then
  echo "Remote repo not found at $repo" >&2
  exit 1
fi

if [ -n "$(git -C "$repo" status --short)" ]; then
  echo "Remote repo at $repo is dirty; refusing to deploy" >&2
  git -C "$repo" status --short >&2
  exit 1
fi

git -C "$repo" fetch origin "$branch"

if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
  git -C "$repo" checkout "$branch"
else
  git -C "$repo" checkout -b "$branch" --track "origin/$branch"
fi

git -C "$repo" pull --ff-only origin "$branch"

if command -v doas >/dev/null 2>&1; then
  elevate="doas"
elif command -v sudo >/dev/null 2>&1; then
  elevate="sudo"
else
  echo "Need doas or sudo on remote host" >&2
  exit 1
fi

exec "$elevate" nixos-rebuild "$action" --flake "$repo#$host"
EOF

for host in "${hosts[@]}"; do
  ssh_target="${ssh_targets[$host]:-${default_user}@${host}}"
  echo "Deploying ${host} via ${ssh_target}"
  ssh "$ssh_target" bash -s -- "$remote_repo" "$branch" "$host" "$action" <<<"$remote_script"
done
