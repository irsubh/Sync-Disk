// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SyncDisk",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "SyncDisk",
            targets: ["SyncDisk"]
        ),
        .executable(
            name: "SyncDiskTestRunner",
            targets: ["SyncDiskTestRunner"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "SyncDiskCore",
            dependencies: [],
            path: "Sources/SyncDisk"
        ),
        .executableTarget(
            name: "SyncDisk",
            dependencies: ["SyncDiskCore"],
            path: "Sources/SyncDiskAppEntry"
        ),
        .executableTarget(
            name: "SyncDiskTestRunner",
            dependencies: ["SyncDiskCore"],
            path: "Tests/SyncDiskTests"
        )
    ]
)
