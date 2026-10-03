// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "RuuviMac", platforms: [.macOS(.v13)], products: [
    .executable(name: "RuuviMac", targets: ["RuuviMac"])
], dependencies: [
    .package(path: "Vendor/BTKit"),
    .package(url: "https://github.com/swift-server-community/mqtt-nio.git", exact: "2.13.0"),
    // Keep transitive dependencies on a tested Swift 5.10-compatible set.
    .package(url: "https://github.com/apple/swift-nio.git", exact: "2.80.0"),
    .package(url: "https://github.com/apple/swift-nio-ssl.git", exact: "2.30.0"),
    .package(url: "https://github.com/apple/swift-nio-transport-services.git", exact: "1.23.0"),
    .package(url: "https://github.com/apple/swift-collections.git", exact: "1.1.4"),
    .package(url: "https://github.com/apple/swift-log.git", exact: "1.6.2"),
    .package(url: "https://github.com/apple/swift-atomics.git", exact: "1.2.0"),
    .package(url: "https://github.com/apple/swift-system.git", exact: "1.4.0")
], targets: [
    .target(name: "RuuviCore", dependencies: [.product(name: "BTKit", package: "BTKit")]),
    .target(name: "RuuviMQTT", dependencies: ["RuuviCore", .product(name: "MQTTNIO", package: "mqtt-nio")]),
    .executableTarget(name: "RuuviMac", dependencies: ["RuuviCore", "RuuviMQTT"]),
    .testTarget(name: "RuuviCoreTests", dependencies: ["RuuviCore", "RuuviMQTT", .product(name: "MQTTNIO", package: "mqtt-nio")])
])
