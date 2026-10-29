// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SentwiseMail",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SentwiseMail", targets: ["SentwiseMail"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.25.0"),
        .package(url: "https://github.com/apple/swift-nio-imap.git", from: "0.2.0"),
        // Transitive via swift-nio-imap; declared explicitly so the app target
        // links it — IMAP APPEND's AppendOptions uses OrderedDictionary.
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0")
    ],
    targets: [
        .target(
            name: "SentwiseMail",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOTLS", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "NIOIMAP", package: "swift-nio-imap"),
                .product(name: "OrderedCollections", package: "swift-collections")
            ]
        ),
        .testTarget(
            name: "SentwiseMailTests",
            dependencies: [
                "SentwiseMail",
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "NIOTLS", package: "swift-nio")
            ]
        )
    ]
)
