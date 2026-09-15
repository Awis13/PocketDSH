#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Headless gate build: ad-hoc identity and empty entitlements, so it needs no
# development team. The bundle is not launched here; runtime entitlements are
# set again by the developer signing in Xcode.
xcodebuild -project PocketDSH.xcodeproj -scheme PocketDSH \
  -configuration Debug -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath .build -allowProvisioningUpdates -jobs 2 \
  CODE_SIGN_IDENTITY=- CODE_SIGN_ENTITLEMENTS=PocketDSH/Empty.entitlements build
mkdir -p output/mac
ditto .build/Build/Products/Debug-maccatalyst/PocketDSH.app output/mac/PocketDSH.app
codesign --verify --deep --strict output/mac/PocketDSH.app
