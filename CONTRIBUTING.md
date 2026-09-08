# Contributing

Keep changes small and preserve iPhone, iPad, and Mac Catalyst behavior. Start with `scripts/check.sh`, then build the affected platform. UI changes should include a fresh screenshot with demonstration data.

`sh scripts/check.sh` runs protocol, Markdown, Native Harness core/real-PTY tests, native transcript/editor checks, and mocked voice tests without a model or existing server. `sh scripts/check-native.sh` runs just the native checks. Xcode/Swift 6 is required; Node is only needed for the optional DSH voice plugin tests.

Tests named `Live*`, `NativeRecoveryChecks`, benchmark scripts and the `check-*-live` scripts are opt-in: read them first, supply your own environment, and expect some to create sessions or submit prompts. They are not part of CI. `NativeRecoveryChecks` requires `HARNESS_BASE_URL` and `HARNESS_MODEL`, launches its own host on port 8787 and must use an isolated directory. `probe-native-*.py` starts local fixtures and exercises process/transport boundaries; Python is a development helper, not a native runtime dependency.

Regenerate `PocketDSH.xcodeproj` with XcodeGen after editing `project.yml`. Keep local settings in `Config/Local.xcconfig`. Do not commit build output, private conversations, authentication links, server addresses, signing assets, or device identifiers.

The project is published for inspection. No open-source license has been selected yet; ask the maintainer before redistribution.
