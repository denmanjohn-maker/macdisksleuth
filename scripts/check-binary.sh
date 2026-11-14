#!/usr/bin/env bash
# Verify a Mach-O binary is universal (arm64 + x86_64) and that every slice
# targets macOS 13, so it launches on Intel Macs back to Ventura.
# Usage: scripts/check-binary.sh <binary> [expected-minos, default 13.0]
set -euo pipefail
bin=${1:?usage: check-binary.sh <binary> [minos]}
want=${2:-13.0}

lipo -info "$bin"
lipo "$bin" -verify_arch arm64 x86_64 \
  || { echo "error: $bin is not universal (needs arm64 and x86_64)" >&2; exit 1; }

for arch in arm64 x86_64; do
  minos=$(otool -arch "$arch" -l "$bin" | awk '/LC_BUILD_VERSION/{found=1} found && $1=="minos"{print $2; exit}')
  echo "$arch: minos $minos"
  [ "$minos" = "$want" ] \
    || { echo "error: $arch slice of $bin targets macOS $minos, expected $want" >&2; exit 1; }
done
