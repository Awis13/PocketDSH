# Build and installation

## Xcode

Install Xcode with iOS and Mac Catalyst support. Open the checked-in project directly, or install XcodeGen and run `xcodegen generate`. The app uses SwiftUI, UIKit, and system frameworks only.

`Config/Build.xcconfig` optionally includes `Config/Local.xcconfig`. Copy the example and enter your own development team for signing. Never commit certificates, provisioning profiles, credentials, or local configuration.

For a Mac build, run `scripts/build-mac.sh`. The result is `output/mac/PocketDSH.app`. The script does not replace an installed app.

## iPhone and iPad

Select your device in Xcode, enable development signing, and run. Device trust and Developer Mode may need to be enabled on the device.

For an AltStore import, first build for an **iOS device**, then package the app:

```sh
xcodebuild -project PocketDSH.xcodeproj -scheme PocketDSH \
  -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath .build -allowProvisioningUpdates build
python3 scripts/package-ipa.py \
  .build/Build/Products/Debug-iphoneos/PocketDSH.app output/PocketDSH.ipa
```

Import that IPA using AltStore's My Apps “+” button. Signing, app limits, and refresh requirements are controlled by Apple and AltStore. Packaging does not bypass them. The packager excludes macOS resource metadata and verifies the ZIP; a valid archive alone does not guarantee signing or installation succeeds.

## Connect

Open Connection and paste the server's sign-in URL. On another device, `127.0.0.1` refers to that device, so use the server's reachable HTTPS hostname instead. Preserve its port and sign-in token. Do not publish or share the complete sign-in URL.

Session cookies are stored in Keychain. Draft text, theme preferences, and cached image drafts are stored locally. The client sends prompts and attachments to the configured Harness server.

## Reproduce screenshots

Debug builds accept `DSH_DEMO=1` in their launch environment. This loads an offline transcript without contacting Harness. Use launch arguments `-harness.theme dracula` and `-harness.terminalInput YES` to choose the screenshot appearance. These are demonstration fixtures, not a production connection mode.
