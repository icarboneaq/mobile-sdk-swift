// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SpruceIDMobileSdk",
    platforms: [
        .iOS(.v14)
    ],
    products: [
        .library(
            name: "SpruceIDMobileSdk",
            targets: ["SpruceIDMobileSdk"])
    ],
    dependencies: [
        .package(path: "../mobile-sdk-rs"),
        // .package(path: "../mobile-sdk-rs"),
        .package(url: "https://github.com/apple/swift-algorithms", from: "1.2.0")
    ],
    targets: [
        .target(
            name: "SpruceIDMobileSdk",
            dependencies: [
                .product(name: "SpruceIDMobileSdkRs", package: "mobile-sdk-rs"),
                .product(name: "Algorithms", package: "swift-algorithms")
            ]
        ),
        .testTarget(
            name: "SpruceIDMobileSdkTests",
            dependencies: ["SpruceIDMobileSdk"])
    ]
)
