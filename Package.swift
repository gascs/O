// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "O",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "O", targets: ["MoleLiteApp"]),
        .library(name: "MoleLiteCore", targets: ["MoleLiteCore"])
    ],
    targets: [
        .target(
            name: "MoleLiteCore",
            path: "Sources/MoleLiteCore"
        ),
        .executableTarget(
            name: "MoleLiteApp",
            dependencies: ["MoleLiteCore"],
            path: "Sources/MoleLiteApp"
        ),
        .testTarget(
            name: "MoleLiteCoreTests",
            dependencies: ["MoleLiteCore"],
            path: "Tests/MoleLiteCoreTests"
        )
    ]
)
