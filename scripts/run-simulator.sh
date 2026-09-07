#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
SIMULATOR_ID="${POCKET_SIMULATOR_ID:?Set POCKET_SIMULATOR_ID from xcrun simctl list devices}"
export POCKET_SIMULATOR_ID="$SIMULATOR_ID"
mkdir -p .build
xcodegen generate
xcodebuild -project PocketDSH.xcodeproj -scheme PocketDSH -configuration Debug \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" -derivedDataPath .build \
  CODE_SIGN_IDENTITY=- build > .build/run-build.log 2>&1
xcrun simctl install "$SIMULATOR_ID" .build/Build/Products/Debug-iphonesimulator/PocketDSH.app
python3 - <<'PY'
import os,pathlib,re,subprocess
log=pathlib.Path.home()/'.dsh/web.stdout.log'
matches=re.findall(r'dsh web: (http://127\.0\.0\.1:3080/\?token=\S+)',log.read_text())
if not matches:raise SystemExit('No current DSH launch URL found')
env=os.environ.copy();env['SIMCTL_CHILD_DSH_LOGIN_URL']=matches[-1]
subprocess.run(['xcrun','simctl','launch','--terminate-running-process',env['POCKET_SIMULATOR_ID'],'dev.awis.PocketDSH'],env=env,check=True)
PY
open -a Simulator
