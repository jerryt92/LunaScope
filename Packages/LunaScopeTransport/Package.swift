// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LunaScopeTransport",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "LunaTransportApple", targets: ["LunaTransportApple"]),
        .library(name: "LunaTransportProtocol", targets: ["LunaTransportProtocol"]),
    ],
    dependencies: [
        .package(url: "https://github.com/erik-sutton95/OpenCine.git",
                 revision: "80247e711f82520f64fb2d35420eba78ca353268"),
    ],
    targets: [
        .target(name: "LunaTransportKCP", exclude: ["LICENSE"]),
        .target(name: "LunaTransportProtocol", dependencies: [
            .product(name: "OpenCineMedia", package: "OpenCine"),
        ]),
        .target(name: "LunaTransportApple", dependencies: [
            "LunaTransportProtocol", "LunaTransportKCP",
            .product(name: "OpenCineCore", package: "OpenCine"),
            .product(name: "OpenCineMedia", package: "OpenCine"),
            .product(name: "OpenCineMotion", package: "OpenCine"),
            .product(name: "OpenCineCameraVocabulary", package: "OpenCine"),
        ]),
    ]
)
