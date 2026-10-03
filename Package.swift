// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "RuuviMac", platforms: [.macOS(.v13)], products: [
    .executable(name: "RuuviMac", targets: ["RuuviMac"])
], dependencies: [
    .package(path: "Vendor/BTKit")
], targets: [
    .target(name: "RuuviCore", dependencies: [.product(name: "BTKit", package: "BTKit")]),
    .executableTarget(name: "RuuviMac", dependencies: ["RuuviCore"]),
    .testTarget(name: "RuuviCoreTests", dependencies: ["RuuviCore"])
])
