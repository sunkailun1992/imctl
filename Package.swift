// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "imctl",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "imctl", targets: ["imctl"]),
        .executable(name: "imctld", targets: ["imctld"]),
        .executable(name: "imctl-console", targets: ["imctl-console"]),
        .library(name: "MCPTransport", targets: ["MCPTransport"]),
        .library(name: "MQTTTransport", targets: ["MQTTTransport"]),
        .library(name: "ControlCore", targets: ["ControlCore"]),
        .library(name: "AXKit", targets: ["AXKit"]),
        .library(name: "WeComAdapter", targets: ["WeComAdapter"]),
        .library(name: "WeComAPI", targets: ["WeComAPI"]),
        .library(name: "OSSClient", targets: ["OSSClient"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.0"),
        .package(url: "https://github.com/swift-server-community/mqtt-nio.git", from: "2.13.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    ],
    targets: [
        .target(name: "ControlCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "AXKit"),
        .target(name: "WeComAdapter", dependencies: ["AXKit", "ControlCore"]),
        .target(name: "MCPTransport", dependencies: ["ControlCore"]),
        .target(name: "WeComAPI", dependencies: ["ControlCore"]),
        .target(name: "OSSClient", dependencies: ["ControlCore"]),
        .target(name: "MQTTTransport", dependencies: [
            "ControlCore", "MCPTransport",
            .product(name: "MQTTNIO", package: "mqtt-nio"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOFoundationCompat", package: "swift-nio"),
        ]),
        .executableTarget(
            name: "imctld",
            dependencies: [
                "ControlCore", "AXKit", "WeComAdapter", "MCPTransport", "MQTTTransport", "WeComAPI", "OSSClient",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "imctl",
            dependencies: [
                "ControlCore", "AXKit", "WeComAdapter", "MQTTTransport", "WeComAPI", "OSSClient",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "imctl-console",
            dependencies: ["ControlCore", "AXKit", "WeComAdapter", "MCPTransport", "MQTTTransport", "WeComAPI", "OSSClient"],
            linkerSettings: [.linkedFramework("SwiftUI"), .linkedFramework("AppKit")]
        ),
        .testTarget(name: "ControlCoreTests", dependencies: ["ControlCore"]),
        .testTarget(name: "AXKitTests", dependencies: ["AXKit"]),
        .testTarget(name: "WeComAdapterTests", dependencies: ["WeComAdapter"]),
        .testTarget(name: "imctlTests", dependencies: ["imctl"]),
        .testTarget(name: "imctldTests", dependencies: ["imctld", "AXKit", "WeComAdapter", "ControlCore", "MCPTransport", "MQTTTransport", "OSSClient", "WeComAPI"]),
        .testTarget(name: "MCPTransportTests", dependencies: ["MCPTransport"]),
        .testTarget(name: "MQTTTransportTests", dependencies: ["MQTTTransport", .product(name: "MQTTNIO", package: "mqtt-nio")]),
        .testTarget(name: "WeComAPITests", dependencies: ["WeComAPI"]),
        .testTarget(name: "OSSClientTests", dependencies: ["OSSClient"]),
        .testTarget(name: "imctl-consoleTests", dependencies: ["imctl-console", "ControlCore", "AXKit", "MCPTransport", "OSSClient"]),
    ],
    swiftLanguageModes: [.v5]
)
