#!/bin/bash
set -euo pipefail
root="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec python3 "$root/附件/scripts/entry.py" "$@"
