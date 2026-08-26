#!/bin/bash
set -Eeuo pipefail

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
workflow_path="${1:-.github/workflows/release.yml}"
if [ "$#" -gt 1 ]; then
  printf '%s\n' 'usage: validate-workflow.sh [workflow-path]' >&2
  exit 64
fi
exec python3 "$script_dir/app-release.py" validate-workflow "$workflow_path"
