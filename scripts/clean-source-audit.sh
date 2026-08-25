#!/bin/sh
set -eu

if rg -n "MacParakeet|GPL-3\.0 application source|copied application" \
  --glob '!RESEARCH.md' --glob '!THIRD_PARTY_NOTICES.md' --glob '!docs/release-gates.md' \
  --glob '!scripts/clean-source-audit.sh' \
  --glob '!.build/**' --glob '!**/.build/**' \
  --glob '!.git/**' .; then
  echo "clean-source audit found a prohibited reference outside the allowed research documents" >&2
  exit 1
fi

if rg -n '\x{2014}' --hidden --glob '!.git/**' --glob '!.build/**' --glob '!**/.build/**' \
  --glob '!scripts/clean-source-audit.sh' .; then
  echo "em dash found" >&2
  exit 1
fi

echo "clean-source audit passed"
