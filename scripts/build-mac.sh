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
codesign --verify --deep --strict output/mac/PocketDSH.app
# Signature regression check: the bundle must carry the signature its mode
# promises. "codesign --verify" alone only proves a signature is present.
ENT=$(codesign -d --entitlements - output/mac/PocketDSH.app 2>/dev/null || true)
if [ "$MODE" = "signed" ]; then
  echo "$ENT" | grep -q "application-identifier" || { echo "FAIL: signed bundle lost its application identifier" >&2; exit 1; }
  echo "$ENT" | grep -q "keychain-access-groups" || { echo "FAIL: signed bundle lost its keychain access groups" >&2; exit 1; }
  TID=$(/usr/libexec/PlistBuddy -c "Print :TeamIdentifier" output/mac/PocketDSH.app 2>/dev/null || true)
  [ -n "$TID" ] || { echo "FAIL: signed bundle has no TeamIdentifier" >&2; exit 1; }
  echo "OK: signed bundle carries identity, application identifier and keychain groups"
else
  # Capture before grep: with pipefail, grep -q's early exit would SIGPIPE
  # codesign and fail the pipeline on a match that arrives too early.
  CSOUT=$(codesign -dvvv output/mac/PocketDSH.app 2>&1 || true)
  echo "$CSOUT" | grep -q "flags=0x2(adhoc)" || { echo "FAIL: adhoc bundle is not ad-hoc signed" >&2; exit 1; }
  echo "OK: adhoc bundle is ad-hoc signed"
fi
