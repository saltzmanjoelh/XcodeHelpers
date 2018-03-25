// swift-tools-version:4.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "XcodeHelperKit",
    products: [
        // Products define the executables and libraries produced by a package, and make them visible to other packages.
        .library(
            name: "XcodeHelperKit",
            targets: ["XcodeHelperKit"]),
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
     .package(url: "https://github.com/saltzmanjoelh/ProcessRunner.git", from: "1.0.0"),
     .package(url: "https://github.com/saltzmanjoelh/DockerProcess.git", from: "1.0.0"),
     .package(url: "https://github.com/saltzmanjoelh/CliRunnable.git", from: "1.0.0"),
     .package(url: "https://github.com/saltzmanjoelh/S3Kit.git", from: "1.0.0")
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages which this package depends on.
        .target(
            name: "XcodeHelperKit",
            dependencies: ["ProcessRunner", "DockerProcess", "CliRunnable", "S3Kit"]),
        .testTarget(
            name: "XcodeHelperKitTests",
            dependencies: ["XcodeHelperKit", "ProcessRunner", "DockerProcess", "CliRunnable", "S3Kit"]),
    ]
)
