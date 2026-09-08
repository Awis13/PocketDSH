#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p .build/checks
swift test --package-path NativeHarness --jobs 4
xcrun swiftc -parse-as-library PocketDSH/HarnessProtocol.swift PocketDSH/ShellBlockInteraction.swift Tests/ShellBlockChecks.swift -o .build/checks/shell-block-checks
.build/checks/shell-block-checks
xcrun swiftc -parse-as-library PocketDSH/HarnessProtocol.swift PocketDSH/HarnessAPI.swift Shared/NativeWire.swift PocketDSH/ShellBlockInteraction.swift PocketDSH/NativeChatConnection.swift Tests/NativeChatChecks.swift -o .build/checks/native-chat-checks
.build/checks/native-chat-checks
# Compile the opt-in isolated host/restart probe; it never runs against production here.
xcrun swiftc -parse-as-library PocketDSH/HarnessProtocol.swift PocketDSH/HarnessAPI.swift Shared/NativeWire.swift PocketDSH/ShellBlockInteraction.swift PocketDSH/NativeChatConnection.swift Tests/NativeRequestReplayChecks.swift -o .build/checks/native-request-replay
