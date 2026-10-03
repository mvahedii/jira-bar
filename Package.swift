// swift-tools-version: 6.0
import Foundation
import PackageDescription

// With only the Command Line Tools installed, the UI target needs the macOS 26 SDK while the test
// macros need the default one. Scripts/test.sh sets this flag so tests build just the core library.
let coreOnly = ProcessInfo.processInfo.environment["JIRABAR_CORE_ONLY"] != nil

var products: [Product] = []
var targets: [Target] = [
    .target(
        name: "JiraBarCore",
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .testTarget(
        name: "JiraBarCoreTests",
        dependencies: ["JiraBarCore"],
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
]

if !coreOnly {
    products.append(.executable(name: "JiraBar", targets: ["JiraBar"]))
    targets.append(
        .executableTarget(
            name: "JiraBar",
            dependencies: ["JiraBarCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    )
}

let package = Package(
    name: "JiraBar",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
