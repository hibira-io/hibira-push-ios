// swift-tools-version:5.5

import PackageDescription

let package = Package(name: "HikibiPush",
                      platforms: [.macOS("12.0"),
                                  .iOS("15.0")],
                      products: [
                        .library(name: "HikibiPush",
                                 targets: ["HikibiPush"])
                      ],
                      dependencies: [
                        .package(url: "https://github.com/Quick/Nimble",
                                 .upToNextMajor(from: "9.2.0")),
                        .package(url: "https://github.com/AliSoftware/OHHTTPStubs",
                                 .upToNextMajor(from: "9.1.0"))
                      ],
                      targets: [
                        .target(name: "HikibiPush"),
                        .testTarget(name: "HikibiPushTests",
                                    dependencies: ["HikibiPush",
                                                   "Nimble",
                                                   .product(name: "OHHTTPStubs", package: "OHHTTPStubs"),
                                                   .product(name: "OHHTTPStubsSwift", package: "OHHTTPStubs")])
                      ],
                      swiftLanguageVersions: [.v5])
