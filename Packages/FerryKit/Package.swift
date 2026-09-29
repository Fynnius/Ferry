// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FerryKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "FerryKit", targets: ["FerryKit"]),
    ],
    targets: [
        .target(name: "FerryKit"),
        .testTarget(name: "FerryKitTests", dependencies: ["FerryKit"]),
    ]
)
