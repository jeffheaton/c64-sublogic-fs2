// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "FS2",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "FS2", targets: ["FS2App"]),
        .executable(name: "fs2lab", targets: ["fs2lab"]),
        .executable(name: "FS2Web", targets: ["FS2Web"]),
        .library(name: "FS2Core", targets: ["FS2Core"]),
    ],
    traits: [
        // The dev-only lab inside the app (`FS2_ENGINE=lab`, `--engine lab`): on by default, so
        // `swift build`, `swift test` and `swift run` have it. `make app` builds the shipped app with
        // `--disable-default-traits`, so it links neither FS2LabKit nor M6502.
        .trait(name: "Lab", description: "Link the dev-only lab engine (FS2LabKit, M6502) into the FS2 app."),
        .default(enabledTraits: ["Lab"]),
    ],
    targets: [
        // C64 hardware models shared by the app and the lab: palette, VIC presenter, SID, keyboard matrix,
        // D64, and the session script format.
        .target(name: "C64Kit"),
        // SubLogic's logical block filesystem, the importer and the cold-start memory image.
        .target(name: "FS2Data", dependencies: ["C64Kit"]),
        // The port itself: the game's routines translated to Swift, operating on the original memory layout.
        .target(name: "FS2Core", dependencies: ["C64Kit", "FS2Data"]),
        // What every host of the engine shares (the Mac app, the web worker): the key mapping and
        // timing, the restart sequence, the demo, the SID renderer, the pacing and the per-slice step.
        .target(name: "FS2Host", dependencies: ["C64Kit", "FS2Core"]),
        // Native macOS shell. The lab is linked only with the `Lab` trait (development builds).
        .executableTarget(name: "FS2App", dependencies: [
            "FS2Host", "FS2Core", "FS2Data", "C64Kit",
            .target(name: "FS2LabKit", condition: .when(traits: ["Lab"])),
        ]),
        // The WebAssembly build (`make web`): fs2.wasm, run by the web page's worker (web/). The
        // C target declares the page's imports; on other platforms both compile to nothing.
        .target(name: "CFS2Web"),
        .executableTarget(name: "FS2Web", dependencies: ["FS2Host", "FS2Core", "FS2Data", "C64Kit", "CFS2Web"],
                          linkerSettings: [
                              // The program's stack: nested restarts run inside the frames they interrupt.
                              .unsafeFlags(["-Xlinker", "-z", "-Xlinker", "stack-size=16777216"],
                                           .when(platforms: [.wasi])),
                          ]),
        // The web build's determinism check and stack probe, native and wasm (`make web-check`).
        .executableTarget(name: "fs2check", dependencies: ["FS2Host", "FS2Core", "FS2Data", "C64Kit"],
                          linkerSettings: [
                              .unsafeFlags(["-Xlinker", "-z", "-Xlinker", "stack-size=16777216"],
                                           .when(platforms: [.wasi])),
                          ]),
        // The web deploy's disk image: only what the port reads, scrubbed (`make web-disk`).
        .executableTarget(name: "fs2disk", dependencies: ["FS2Data", "C64Kit"]),
        // Dev-only verification oracle: a 6502 core and C64 bus that run the original code.
        .target(name: "M6502"),
        .target(name: "FS2LabKit", dependencies: ["M6502", "C64Kit", "FS2Data", "FS2Core"]),
        .executableTarget(name: "fs2lab", dependencies: ["FS2LabKit"]),
        .testTarget(name: "C64KitTests", dependencies: ["C64Kit"]),
        .testTarget(name: "FS2DataTests", dependencies: ["FS2Data"]),
        .testTarget(name: "FS2CoreTests", dependencies: ["FS2Core"]),
        .testTarget(name: "M6502Tests", dependencies: ["M6502"]),
        .testTarget(name: "FS2HostTests", dependencies: ["FS2Host", "FS2Core", "C64Kit"]),
        .testTarget(name: "DifferentialTests",
                    dependencies: ["FS2LabKit", "FS2Host", "FS2Core", "FS2Data", "C64Kit", "M6502"]),
        .testTarget(name: "FS2AppTests", dependencies: ["FS2App", "FS2Host", "FS2LabKit"]),
    ]
)
