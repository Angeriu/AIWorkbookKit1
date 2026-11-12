// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "AIWorkbookKit",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "AIWorkbookKit", targets: ["AIWorkbookKit"])
    ],
    targets: [
        .target(name: "AIWorkbookKit")
    ]
)
