// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SwiftTerm",
    platforms: [.iOS(.v13), .macOS(.v10_15)],
    products: [.library(name: "SwiftTerm", targets: ["SwiftTerm"])],
    targets: [.target(name: "SwiftTerm", path: "Sources/SwiftTerm")],
    swiftLanguageVersions: [.v5]
)
