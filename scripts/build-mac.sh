#!/bin/bash
# Build the Mac Catalyst app. Two modes, deliberately not interchangeable:
#
#   build-mac.sh            signed build (the documented contract)
#   build-mac.sh adhoc      headless verification build
#
# The signed build signs with the development team from Config/Local.xcconfig
# (copy of Config/Local.xcconfig.example) or the DEVELOPMENT_TEAM environment
# variable, and keeps the app's real identity: the bundle id prefix, the
# application identifier and the keychain access groups from Mac.entitlements.
# SecureConnection persists its cookie in the Keychain under that identity, so
# the installed app is the signed one. The ad-hoc mode exists so the gate can
# verify compilation and linking for the Catalyst target without any team; its
# bundle is not the installed app.
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-signed}"
case "$MODE" in
  signed)
    # Team resolution: an explicit DEVELOPMENT_TEAM environment variable wins;
    # otherwise the developer's Config/Local.xcconfig (copied from
    # Config/Local.xcconfig.example) flows in through Build.xcconfig.
    if [ -n "${DEVELOPMENT_TEAM:-}" ]; then
      TEAM_ARG="DEVELOPMENT_TEAM=${DEVELOPMENT_TEAM}"
    elif [ -f Config/Local.xcconfig ]; then
      TEAM_ARG=""
    else
      echo "FAIL: no development team: set DEVELOPMENT_TEAM or copy Config/Local.xcconfig.example to Config/Local.xcconfig" >&2
      exit 1
    fi
    xcodebuild -project PocketDSH.xcodeproj -scheme PocketDSH \
      -configuration Debug -destination 'platform=macOS,variant=Mac Catalyst' \
      -derivedDataPath .build -allowProvisioningUpdates -jobs 2 \
      $TEAM_ARG build
    ;;
  adhoc)
    xcodebuild -project PocketDSH.xcodeproj -scheme PocketDSH \
      -configuration Debug -destination 'platform=macOS,variant=Mac Catalyst' \
      -derivedDataPath .build -jobs 2 \
      CODE_SIGN_IDENTITY=- CODE_SIGN_ENTITLEMENTS=PocketDSH/Empty.entitlements build
    ;;
  *)
    echo "unknown build mode: $MODE (expected: signed, adhoc)" >&2
    exit 2
    ;;
esac
mkdir -p output/mac
ditto .build/Build/Products/Debug-maccatalyst/PocketDSH.app output/mac/PocketDSH.app
# Signature regression check: the bundle must carry the signature its mode
# promises. The validators are shared with the gate (scripts/sign-checks.sh),
# which proves them headless on controlled fixtures; "codesign --verify" alone
# only proves a signature is present, not which kind it is.
. ./scripts/sign-checks.sh
if [ "$MODE" = "signed" ]; then
  validate_signed_bundle output/mac/PocketDSH.app
else
  validate_adhoc_bundle output/mac/PocketDSH.app
fi
