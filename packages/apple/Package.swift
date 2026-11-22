// swift-tools-version: 5.9
import PackageDescription

let artifacts = "https://raw.githubusercontent.com/swift-developer-tools/swift-libgit2/2c58c9b3d70168b5118d8020937e4e652c18be80/swift-libgit2-base/lib"

let package = Package(
    name: "KinenApple",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "KinenCore", targets: ["KinenCore"])],
    targets: [
        .binaryTarget(name: "libgit2", url: "\(artifacts)/libgit2.zip",
                      checksum: "ce79659d81426d6ebfd49cb05a37b8792a8ea459276ed1fb69f09ca0b501f20b"),
        .binaryTarget(name: "libssh2", url: "\(artifacts)/libssh2.zip",
                      checksum: "728ec284f5fb27ea71da85027e29314eb7d8aa6022ccee55e4f9f69ddec9bd74"),
        .binaryTarget(name: "libssl", url: "\(artifacts)/libssl.zip",
                      checksum: "168aa8d3f299ab27bf8d3930f87f5b5883f3dfc3090e389c7bd030ede3052582"),
        .binaryTarget(name: "libcrypto", url: "\(artifacts)/libcrypto.zip",
                      checksum: "c3bc28f0a252b60189e931540e1efaad7e3479e69b3fa9acf1d134835f9a1fb7"),
        .target(name: "KinenGitBridge", dependencies: ["libgit2", "libssh2", "libssl", "libcrypto"],
                linkerSettings: [.linkedLibrary("z"), .linkedLibrary("iconv"),
                                 .linkedFramework("Security"), .linkedFramework("CoreFoundation")]),
        .target(name: "KinenCore", dependencies: ["KinenGitBridge"]),
        .testTarget(name: "KinenCoreTests", dependencies: ["KinenCore"])
    ]
)
