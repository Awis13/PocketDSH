#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p .build/checks
xcrun swiftc -parse-as-library PocketDSH/HarnessProtocol.swift PocketDSH/HarnessAPI.swift PocketDSH/ImageAttachments.swift Tests/ProtocolChecks.swift -o .build/checks/protocol-checks
.build/checks/protocol-checks
xcrun swiftc -parse-as-library PocketDSH/SavedConnections.swift Tests/SavedConnectionChecks.swift -o .build/checks/connection-checks
.build/checks/connection-checks
xcrun swiftc -parse-as-library PocketDSH/HarnessProtocol.swift PocketDSH/HarnessAPI.swift PocketDSH/ImageAttachments.swift PocketDSH/CommandCatalog.swift PocketDSH/ComposerSubmission.swift PocketDSH/FullAccessConfirmation.swift Tests/ComposerSubmissionChecks.swift -o .build/checks/composer-submission-checks
.build/checks/composer-submission-checks
xcrun swiftc -parse-as-library PocketDSH/HarnessProtocol.swift PocketDSH/SessionProjection.swift Tests/SessionProjectionChecks.swift -o .build/checks/session-projection-checks
.build/checks/session-projection-checks
xcrun swiftc -parse-as-library PocketDSH/HarnessProtocol.swift PocketDSH/CommandCatalog.swift Tests/CommandCatalogChecks.swift -o .build/checks/command-catalog-checks
.build/checks/command-catalog-checks
xcrun swiftc -parse-as-library PocketDSH/HarnessProtocol.swift PocketDSH/HarnessAPI.swift PocketDSH/ImageAttachments.swift PocketDSH/CommandCatalog.swift PocketDSH/ComposerSubmission.swift PocketDSH/FullAccessConfirmation.swift Tests/FullAccessConfirmationChecks.swift -o .build/checks/full-access-checks
.build/checks/full-access-checks
# The routing check compiles no native wire: the raw-input ownership it used to
# restate is NativeCompactionInfo's, checked by Tests/NativeContextChecks.swift.
xcrun swiftc -parse-as-library PocketDSH/HarnessProtocol.swift PocketDSH/CommandCatalog.swift PocketDSH/ComposerCommandRouting.swift Tests/ComposerCommandRoutingChecks.swift -o .build/checks/composer-command-routing-checks
.build/checks/composer-command-routing-checks
# The Remote stream coordinator is the production code PocketStore drives; the
# check compiles and exercises it, not a copy of its identity rules. Its live
# probe stays opt-in through DSH_STREAM_CHECK_COOKIE / DSH_LIVE_LOG.
rm -f .build/checks/stream-checks
xcrun swiftc -parse-as-library PocketDSH/HarnessProtocol.swift PocketDSH/HarnessAPI.swift PocketDSH/RemoteStreamConnection.swift Tests/HarnessStreamChecks.swift -o .build/checks/stream-checks
.build/checks/stream-checks
