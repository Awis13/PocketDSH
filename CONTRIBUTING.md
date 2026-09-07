# Contributing

Keep changes small and preserve iPhone, iPad, and Mac Catalyst behavior. Start with `scripts/check.sh`, then build the affected platform. UI changes should include a fresh screenshot with demonstration data.

The protocol and Markdown checks run without a live server. Voice tests use mocked upstream requests. Tests named `Live*` and the `check-*-live` scripts are opt-in: read them first, supply your own environment, and expect some to create sessions or submit prompts. They are not part of CI.

Regenerate `PocketDSH.xcodeproj` with XcodeGen after editing `project.yml`. Keep local settings in `Config/Local.xcconfig`. Do not commit build output, private conversations, authentication links, server addresses, signing assets, or device identifiers.

The project is published for inspection. No open-source license has been selected yet; ask the maintainer before redistribution.
