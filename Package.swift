// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ZebTrace",
    defaultLocalization: "en",
    platforms: [.macOS("14.2")],
    products: [
        .executable(name: "ZebTrace", targets: ["ZebTrace"]),
        .executable(name: "ZebTraceAnalyze", targets: ["ZebTraceAnalyze"]),
        .library(name: "ZebTraceCore", targets: ["ZebTraceCore"]),
        .library(name: "ZebTraceAnalysis", targets: ["ZebTraceAnalysis"]),
    ],
    targets: [
        .target(name: "ZebTraceCore", resources: [.process("Resources")]),
        .target(name: "ZebTraceAnalysis", dependencies: ["ZebTraceCore"]),
        .executableTarget(name: "ZebTrace", dependencies: ["ZebTraceCore", "ZebTraceAnalysis"]),
        .executableTarget(name: "ZebTraceAnalyze", dependencies: ["ZebTraceAnalysis"], path: "Tools/ZebTraceAnalyze"),
        .testTarget(name: "ZebTraceCoreTests", dependencies: ["ZebTraceCore"]),
        .testTarget(name: "ZebTraceAnalysisTests", dependencies: ["ZebTraceAnalysis"]),
    ]
)
