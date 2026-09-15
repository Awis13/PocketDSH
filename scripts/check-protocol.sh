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
# The carrier-lifecycle check compiles the real carrier loop and the production
# confirmation seam together: a pending full-access confirmation is dropped by the
# carrier's failure and ready edges, so the combined carrier -> confirmation path
# is exercised, not the two isolated halves.
xcrun swiftc -parse-as-library PocketDSH/HarnessProtocol.swift PocketDSH/HarnessAPI.swift PocketDSH/ImageAttachments.swift PocketDSH/CommandCatalog.swift PocketDSH/ComposerSubmission.swift PocketDSH/FullAccessConfirmation.swift PocketDSH/RemoteStreamConnection.swift Tests/FullAccessCarrierLifecycleChecks.swift -o .build/checks/full-access-carrier-checks
.build/checks/full-access-carrier-checks
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
# The model-selection check drives the production PocketStore: its selectModel,
# refresh, select and disconnect paths run unchanged on a parked transport, so
# the ownership, liveness and accepted-response rules are exercised on the
# production objects. The store pulls the whole app closure (NativeClient ->
# SwiftTerm), so this line builds the vendored SwiftTerm module first and
# compiles the closure for Mac Catalyst, where UIKit is available. The @main
# attribute is stripped from a throwaway copy of the app entry, keeping the
# check file the single entry point.
ARCH=$(uname -m)
CATALYST_TARGET="${ARCH}-apple-ios17.0-macabi"
IOSUPPORT="$(xcrun --sdk macosx --show-sdk-path)/System/iOSSupport"
xcrun swiftc -target "${CATALYST_TARGET}" -Fsystem "${IOSUPPORT}/System/Library/Frameworks" -module-name SwiftTerm -emit-module -emit-module-path .build/checks/SwiftTerm.swiftmodule -emit-library -o .build/checks/libSwiftTerm.dylib $(find Vendor/SwiftTerm/Sources/SwiftTerm -name "*.swift")
sed '/^@main$/d' PocketDSH/PocketDSHApp.swift > .build/checks/PocketDSHApp.nomain.swift
xcrun swiftc -target "${CATALYST_TARGET}" -Fsystem "${IOSUPPORT}/System/Library/Frameworks" -parse-as-library -I .build/checks -L .build/checks -lSwiftTerm -Xlinker -rpath -Xlinker @loader_path $(ls PocketDSH/*.swift | grep -v "PocketDSHApp.swift") .build/checks/PocketDSHApp.nomain.swift Shared/NativeWire.swift Tests/ModelSelectionChecks.swift -o .build/checks/model-selection-checks
.build/checks/model-selection-checks
