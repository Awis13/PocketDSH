// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NativeHarness",
    platforms: [.macOS(.v14)],
    products: [.library(name: "HarnessCore", targets: ["HarnessCore"]),
               .executable(name: "harness", targets: ["harness"])],
    targets: [.systemLibrary(name: "CSQLite"),
              .target(name: "CPTY"),
              .target(name: "HarnessCore", dependencies: ["CSQLite", "CPTY"]),
              .executableTarget(name: "harness", dependencies: ["HarnessCore"]),
              .testTarget(name: "HarnessCoreTests", dependencies: ["HarnessCore", "CSQLite"]),
              .testTarget(name: "HarnessHostTests", dependencies: ["harness", "HarnessCore"])]
)
