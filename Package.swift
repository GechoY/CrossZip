// swift-tools-version: 5.9
import PackageDescription
import Foundation

let nativeLibraries = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Vendor/Native/lib").path

let package = Package(
    name: "CrossZip",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CrossZipCore", targets: ["CrossZipCore"]),
        .executable(name: "CrossZip", targets: ["CrossZip"]),
        .executable(name: "crosszip-cli", targets: ["CrossZipCLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20")
    ],
    targets: [
        .systemLibrary(name: "CLibArchive"),
        .target(name: "CrossZipCore", dependencies: ["CLibArchive"], linkerSettings: [
            .unsafeFlags([nativeLibraries + "/libarchive.a", nativeLibraries + "/liblzma.a"]),
            .linkedLibrary("z"), .linkedLibrary("bz2"), .linkedLibrary("iconv")
        ]),
        .executableTarget(name: "CrossZip", dependencies: ["CrossZipCore"]),
        .executableTarget(name: "CrossZipCLI", dependencies: ["CrossZipCore"]),
        .testTarget(name: "CrossZipCoreTests", dependencies: ["CrossZipCore", "ZIPFoundation"], resources: [.copy("Fixtures")]),
        .testTarget(name: "CrossZipAppTests", dependencies: ["CrossZip", "CrossZipCore"])
    ]
)
