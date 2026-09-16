#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p .build/checks
swift test --package-path NativeHarness --jobs 4
# swift test does not link the executable product; build it explicitly so the
# signal probe always runs against a fresh NativeHarness/.build/debug/harness.
swift build --package-path NativeHarness --product harness --jobs 2
python3 scripts/probe-native-host-signals.py --binary NativeHarness/.build/debug/harness
xcrun swiftc -parse-as-library Shared/NativeWire.swift PocketDSH/HarnessProtocol.swift PocketDSH/ShellBlockInteraction.swift Tests/ShellBlockChecks.swift -o .build/checks/shell-block-checks
.build/checks/shell-block-checks
xcrun swiftc -parse-as-library PocketDSH/HarnessProtocol.swift PocketDSH/HarnessAPI.swift Shared/NativeWire.swift PocketDSH/ShellBlockInteraction.swift PocketDSH/NativeChatConnection.swift PocketDSH/TerminalPresentation.swift PocketDSH/PaneFocusNavigator.swift Tests/NativeChatChecks.swift -o .build/checks/native-chat-checks
.build/checks/native-chat-checks
# Compile the opt-in isolated host/restart probe; it never runs against production here.
xcrun swiftc -parse-as-library PocketDSH/HarnessProtocol.swift PocketDSH/HarnessAPI.swift Shared/NativeWire.swift PocketDSH/ShellBlockInteraction.swift PocketDSH/NativeChatConnection.swift Tests/NativeRequestReplayChecks.swift -o .build/checks/native-request-replay
xcrun swiftc -parse-as-library PocketDSH/HarnessProtocol.swift PocketDSH/HarnessAPI.swift Shared/NativeWire.swift PocketDSH/ShellBlockInteraction.swift PocketDSH/NativeChatConnection.swift Tests/NativeContextChecks.swift -o .build/checks/native-context-checks
.build/checks/native-context-checks
xcrun swiftc -parse-as-library Shared/NativeWire.swift Tests/NativeQueueChecks.swift -o .build/checks/native-queue-checks
.build/checks/native-queue-checks
