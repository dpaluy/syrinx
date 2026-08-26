#!/bin/bash
set -Eeuo pipefail

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
exec python3 "$script_dir/app-release.py" verify "$@"
