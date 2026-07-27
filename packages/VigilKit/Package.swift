// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "VigilKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "VigilKit", targets: ["VigilKit"])
    ],
    targets: [
        .target(
            name: "VigilKit",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(name: "VigilKitTests", dependencies: ["VigilKit"]),
    ]
)
