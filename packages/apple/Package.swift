// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KinenApple",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "KinenCore", targets: ["KinenCore"])],
    targets: [.target(name: "KinenCore")]
)
