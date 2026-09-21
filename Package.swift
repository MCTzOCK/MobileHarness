// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MobileHarness",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        /// The AI agent harness library for iOS and macOS applications.
        .library(
            name: "MobileHarness",
            targets: ["MobileHarness"]
        ),
    ],
    targets: [
        .target(
            name: "MobileHarness",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ]
        ),
        .testTarget(
            name: "MobileHarnessTests",
            dependencies: ["MobileHarness"]
        ),
    ]
)
