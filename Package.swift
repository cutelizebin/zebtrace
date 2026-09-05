// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ZebTrace",
    defaultLocalization: "en",
    platforms: [.macOS("14.2")],
    products: [
        .executable(name: "ZebTrace", targets: ["ZebTrace"]),
        .library(name: "ZebTraceCore", targets: ["ZebTraceCore"]),
    ],
    targets: [
        .target(name: "ZebTraceCore", resources: [.process("Resources")]),
        .executableTarget(name: "ZebTrace", dependencies: ["ZebTraceCore"]),
        .testTarget(name: "ZebTraceCoreTests", dependencies: ["ZebTraceCore"]),
    ]
)
