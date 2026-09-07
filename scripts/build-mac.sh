#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -project PocketDSH.xcodeproj -scheme PocketDSH \
  -configuration Debug -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath .build -allowProvisioningUpdates build
mkdir -p output/mac
ditto .build/Build/Products/Debug-maccatalyst/PocketDSH.app output/mac/PocketDSH.app
codesign --verify --deep --strict output/mac/PocketDSH.app
