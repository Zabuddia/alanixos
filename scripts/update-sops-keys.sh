#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"${repo_root}/scripts/generate-sops-config.sh"

files=()
if [ "$#" -gt 0 ]; then
  for path in "$@"; do
    if [[ "$path" = /* ]]; then
      files+=("$path")
    else
      files+=("${repo_root}/${path}")
    fi
  done
else
  while IFS= read -r path; do
    files+=("$path")
  done < <(rg -l '^sops:' "${repo_root}/secrets" -g '*.yaml' -g '*.yml' | sort)
fi

if [ "${#files[@]}" -eq 0 ]; then
  echo "No sops-managed files found under ${repo_root}/secrets"
  exit 0
fi

for file in "${files[@]}"; do
  rel="${file#${repo_root}/}"
  echo "Updating recipients in ${rel}"
  sops updatekeys --yes "$file"
done
