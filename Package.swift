// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Lingohub",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v14),
        .macOS(.v10_15)
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "Lingohub",
            targets: ["Lingohub"]),
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", .upToNextMajor(from: "0.9.19")),
        .package(url: "https://github.com/WeTransfer/Mocker.git", .upToNextMajor(from: "3.0.2"))
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "Lingohub",
            dependencies: ["ZIPFoundation"]),
        .testTarget(
            name: "LingohubTests",
            dependencies: ["Lingohub", "Mocker"],
            resources: [
                .process("Resources/empty.json"),
                .process("Resources/update_200.json"),
                .process("Resources/update_401.json"),
                .process("Resources/update.zip"),
                .process("Resources/Localization")
                // .process("Resources/update")
            ]
        ),
    ]
)
