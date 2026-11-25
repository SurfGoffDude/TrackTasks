// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TrackTasks",
    platforms: [.macOS(.v26)],
    dependencies: [
        // Terminal emulator (view only, processes are PtyProcess). 1.11.2 is the last version without a Metal
        // shader: newer ones don't build without Xcode's separate Metal Toolchain.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.11.2"),
        // Updates of the published app. A binary xcframework; also brings generate_appcast, sign_update, generate_keys.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        // Pure logic: models, frontmatter/task codec, Markdown parsing, FSEvents classification.
        .target(
            name: "TrackTasksCore",
            path: "Sources/TrackTasksCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "TrackTasks",
            dependencies: [
                "TrackTasksCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/TrackTasks",
            swiftSettings: [.swiftLanguageMode(.v5)],
            // The app finds Sparkle in its bundle; build products find it next to themselves.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        // CLI: thin entry point, logic is in TrackTasksCore/CLI*.swift.
        .executableTarget(
            name: "tt",
            dependencies: ["TrackTasksCore"],
            path: "Sources/tt",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "TrackTasksCoreTests",
            dependencies: ["TrackTasksCore"],
            path: "Tests/TrackTasksCoreTests"
        ),
        // The app target itself: the job queue with a fake agent (no claude, no user data).
        .testTarget(
            name: "TrackTasksTests",
            dependencies: ["TrackTasks", "TrackTasksCore", .product(name: "Sparkle", package: "Sparkle")],
            path: "Tests/TrackTasksTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
