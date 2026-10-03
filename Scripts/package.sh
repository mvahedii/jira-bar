#!/bin/bash
# Builds the app and zips it for a GitHub release:   VERSION=1.0.0 Scripts/package.sh
set -euo pipefail
cd "$(dirname "$0")/.."

export VERSION="${VERSION:-1.0.0}"
Scripts/build_app.sh

ZIP="build/JiraBar-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent build/JiraBar.app "$ZIP"
echo "Created $ZIP"
shasum -a 256 "$ZIP"
