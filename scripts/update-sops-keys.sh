#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"${repo_root}/scripts/generate-sops-config.sh"

list_sops_files() {
  if command -v rg >/dev/null 2>&1; then
    rg -l '^sops:' "${repo_root}/secrets" -g '*.yaml' -g '*.yml' | sort
    return
  fi

  find "${repo_root}/secrets" -type f \( -name '*.yaml' -o -name '*.yml' \) -print0 \
    | while IFS= read -r -d '' path; do
        if grep -q '^sops:' "$path"; then
          printf '%s\n' "$path"
        fi
      done \
    | sort
}

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
  done < <(list_sops_files)
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
