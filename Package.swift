// swift-tools-version:6.0
import PackageDescription

// Each module is owned by one area and builds on its own:
//   swift build --target DashcastStream --scratch-path .build/stream
let package = Package(
    name: "Dashcast",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Dashcast", targets: ["Dashcast"]),
    ],
    targets: [
        // Shared types + protocols. Every other module depends only on this (plus system frameworks).
        .target(name: "DashcastContracts"),

        // Private CGVirtualDisplay declarations.
        .target(name: "CVirtualDisplay"),

        // Capture, virtual display, encoders, input injection.
        .target(name: "DashcastStream", dependencies: ["DashcastContracts", "CVirtualDisplay"]),

        // HTTP/WebSocket server, session logic (tiers, congestion), DashcastService orchestrator.
        .target(name: "DashcastServer", dependencies: ["DashcastContracts"]),

        // libdatachannel C API (built from source into Vendor/ by scripts/build-libdatachannel.sh).
        // libdatachannel.a is ONE merged static archive (datachannel + libjuice + usrsctp + libsrtp +
        // Mbed TLS), so the app has no dylib dependencies. The -L path is absolute (derived from this
        // manifest's location) so linking doesn't depend on the build tool's working directory.
        .target(
            name: "CDataChannel",
            linkerSettings: [
                .unsafeFlags(["-L" + String(#filePath.dropLast("Package.swift".count)) + "Vendor/libdatachannel/lib"]),
                .linkedLibrary("datachannel"), .linkedLibrary("c++"),
            ]
        ),

        // WebRTC peer (H.264 + Opus RTP) for HTTP mode.
        .target(
            name: "DashcastRTC",
            dependencies: ["DashcastContracts", "CDataChannel"],
            linkerSettings: [.linkedFramework("AudioToolbox")]
        ),

        // Topology detection, loopback alias helper, Cloudflare DNS, certificates, router setup.
        .target(name: "DashcastNetwork", dependencies: ["DashcastContracts"]),

        // SwiftUI app; wires the concrete implementations together.
        .executableTarget(
            name: "Dashcast",
            dependencies: ["DashcastContracts", "DashcastStream", "DashcastServer", "DashcastNetwork", "DashcastRTC"]
        ),

        .testTarget(name: "DashcastStreamTests", dependencies: ["DashcastStream"]),
        .testTarget(name: "DashcastServerTests", dependencies: ["DashcastServer"]),
        .testTarget(name: "DashcastNetworkTests", dependencies: ["DashcastNetwork"]),
        // The app's pure pieces: permission-panel placement, connection copy, certificate files.
        .testTarget(name: "DashcastAppTests", dependencies: ["Dashcast"]),
        // DashcastServer only for the opt-in real-server + real-client Chrome run (ServerInteropTests).
        .testTarget(name: "DashcastRTCTests", dependencies: ["DashcastRTC", "CDataChannel", "DashcastServer"]),
    ],
    swiftLanguageModes: [.v5]
)
