// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "PacketScope",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "PacketScope", targets: ["PacketScope"])],
    targets: [
        .executableTarget(name: "PacketScope"),
        .testTarget(name: "PacketScopeTests", dependencies: ["PacketScope"])
    ]
)
