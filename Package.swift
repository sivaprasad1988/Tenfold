// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Tenfold",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Tenfold", path: "Sources/Tenfold")
    ]
)
