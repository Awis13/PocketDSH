#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
sh scripts/check-protocol.sh
xcrun swiftc -parse-as-library PocketDSH/MarkdownBlocks.swift Tests/MarkdownChecks.swift -o .build/checks/markdown-checks
.build/checks/markdown-checks
node --test plugins/dsh-voice/voice.test.mjs
