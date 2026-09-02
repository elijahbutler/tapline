// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "TaplinePackages",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
        .watchOS(.v11),
    ],
    products: [
        .library(name: "CaptureCore", targets: ["CaptureCore"]),
        .library(name: "CaptureStore", targets: ["CaptureStore"]),
        .library(name: "DeliveryKit", targets: ["DeliveryKit"]),
        .library(name: "EndpointSecurity", targets: ["EndpointSecurity"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/groue/GRDB.swift.git",
            exact: "7.11.1"
        ),
    ],
    targets: [
        .target(
            name: "CaptureCore",
            path: "Packages/CaptureCore/Sources"
        ),
        .target(
            name: "EndpointSecurity",
            path: "Packages/EndpointSecurity/Sources"
        ),
        .target(
            name: "DeliveryKit",
            dependencies: ["CaptureCore", "EndpointSecurity"],
            path: "Packages/DeliveryKit/Sources"
        ),
        .target(
            name: "CaptureStore",
            dependencies: [
                "CaptureCore",
                "DeliveryKit",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Packages/CaptureStore/Sources"
        ),
        .testTarget(
            name: "CaptureCoreTests",
            dependencies: ["CaptureCore"],
            path: "Packages/CaptureCore/Tests"
        ),
        .testTarget(
            name: "EndpointSecurityTests",
            dependencies: ["EndpointSecurity"],
            path: "Packages/EndpointSecurity/Tests"
        ),
        .testTarget(
            name: "DeliveryKitTests",
            dependencies: ["DeliveryKit", "EndpointSecurity"],
            path: "Packages/DeliveryKit/Tests"
        ),
        .testTarget(
            name: "CaptureStoreTests",
            dependencies: ["CaptureStore", "CaptureCore", "DeliveryKit"],
            path: "Packages/CaptureStore/Tests"
        ),
    ]
)

