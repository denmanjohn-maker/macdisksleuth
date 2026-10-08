#!/usr/bin/env bash
# Verify the version in Version.swift and App/project.yml agree.
# With an argument (e.g. v0.2.0 or 0.2.0), also verify it matches the tag.
set -euo pipefail
cd "$(dirname "$0")/.."

kit=$(sed -n 's/.*static let string = "\(.*\)".*/\1/p' Sources/DiskSleuthKit/Version.swift)
app=$(sed -n 's/.*MARKETING_VERSION: "\(.*\)".*/\1/p' App/project.yml)

echo "DiskSleuthVersion.string = $kit"
echo "MARKETING_VERSION        = $app"
[ -n "$kit" ] && [ "$kit" = "$app" ] || { echo "error: versions disagree" >&2; exit 1; }

if [ $# -gt 0 ]; then
  want=${1#v}
  echo "tag                      = $want"
  [ "$kit" = "$want" ] || { echo "error: tag does not match source version" >&2; exit 1; }
fi
