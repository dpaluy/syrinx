#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

swift test --package-path "$repo_root"
swift test --package-path "$repo_root/parrot"
