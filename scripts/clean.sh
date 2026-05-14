#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

find "$REPO_ROOT" \
  \( -name "*.d" -o -name "*.dia" -o -name "*.swiftdeps" -o -name "*.swiftmodule" \) \
  -not -path "*/.git/*" \
  -print -delete

echo "Done."
