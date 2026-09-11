#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p .build/checks
xcrun swiftc -parse-as-library PocketDSH/HarnessProtocol.swift PocketDSH/HarnessAPI.swift PocketDSH/ImageAttachments.swift Tests/ProtocolChecks.swift -o .build/checks/protocol-checks
.build/checks/protocol-checks
xcrun swiftc -parse-as-library PocketDSH/SavedConnections.swift Tests/SavedConnectionChecks.swift -o .build/checks/connection-checks
.build/checks/connection-checks
xcrun swiftc -parse-as-library PocketDSH/HarnessProtocol.swift PocketDSH/SessionProjection.swift Tests/SessionProjectionChecks.swift -o .build/checks/session-projection-checks
.build/checks/session-projection-checks
