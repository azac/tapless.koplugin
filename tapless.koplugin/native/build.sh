#!/bin/sh
# The existing libtapless-core.so is preserved; build the three portable variants.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec python3 "$root/build_variants.py" "$@"
