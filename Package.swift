// swift-tools-version:5.5

import PackageDescription

let package = Package(name: "HibiraPush",
                      platforms: [.macOS("12.0"),
                                  .iOS("15.0")],
                      products: [
                        .library(name: "HibiraPush",
                                 targets: ["HibiraPush"])
                      ],
                      dependencies: [
                        .package(url: "https://github.com/Quick/Nimble",
                                 .upToNextMajor(from: "9.2.0")),
                        .package(url: "https://github.com/AliSoftware/OHHTTPStubs",
                                 .upToNextMajor(from: "9.1.0"))
                      ],
                      targets: [
                        .target(name: "HibiraPush"),
                        .testTarget(name: "HibiraPushTests",
                                    dependencies: ["HibiraPush",
                                                   "Nimble",
                                                   .product(name: "OHHTTPStubs", package: "OHHTTPStubs"),
                                                   .product(name: "OHHTTPStubsSwift", package: "OHHTTPStubs")])
                      ],
                      swiftLanguageVersions: [.v5])
