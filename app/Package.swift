// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "HexNFC",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "HexNFCKit", targets: ["HexNFCKit"]),
        .library(name: "HexNFCRecords", targets: ["HexNFCRecords"]),
        .library(name: "HexNFCStorage", targets: ["HexNFCStorage"]),
        .library(name: "HexNFCDesign", targets: ["HexNFCDesign"]),
        .library(name: "HexNFCShaders", targets: ["HexNFCShaders"]),
        .library(name: "HexNFCApp", targets: ["HexNFCApp"]),
        .library(name: "HexNFCTestKit", targets: ["HexNFCTestKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.17.0"),
    ],
    targets: [
        .target(
            name: "HexNFCRecords",
            path: "Sources/HexNFCRecords",
            resources: [
                .process("Resources"),
            ]
        ),
        .target(
            name: "HexNFCKit",
            dependencies: ["HexNFCRecords"],
            path: "Sources/HexNFCKit"
        ),
        .target(
            name: "HexNFCStorage",
            dependencies: ["HexNFCRecords"],
            path: "Sources/HexNFCStorage"
        ),
        .target(
            name: "HexNFCShaders",
            path: "Sources/HexNFCShaders",
            resources: [
                .process("Metal"),
                .process("Haptics/Patterns"),
            ]
        ),
        .target(
            name: "HexNFCDesign",
            dependencies: ["HexNFCShaders"],
            path: "Sources/HexNFCDesign"
        ),
        // Vendored byte for byte from hexpro-dev/hex-promo at
        // fd09a670b80c228e0740036b0442bd2078415e05, so it carries no local
        // edits and this repo's linters skip it. The file at
        // Sources/HexPromoKit/PROVENANCE.md records the pin, a sha256 and line
        // count per file, the one upstream file deliberately left behind, and
        // the re-sync steps. Read it before touching anything in that
        // directory; the commit above is checked against its Commit row by the
        // HexPromoKitTests suite.
        // Product-less on purpose: HexNFCApp is the only consumer, so SPM links
        // it transitively and the Xcode app target needs no new entry under
        // Frameworks, Libraries and Embedded Content.
        //
        // The exclude is not optional. PROVENANCE.md sits inside the target
        // directory, and an undeclared non-source file there makes SPM warn
        // about an unhandled resource on every build. Nothing may be listed
        // that is not really present either: an exclude naming a missing path
        // warns "Invalid Exclude: File not found" on every build, test and
        // Xcode open, though not on swift package resolve, which never loads
        // the target graph the check lives in.
        .target(
            name: "HexPromoKit",
            path: "Sources/HexPromoKit",
            exclude: ["PROVENANCE.md"]
        ),
        .target(
            name: "HexNFCApp",
            dependencies: [
                "HexNFCKit",
                "HexNFCStorage",
                "HexNFCDesign",
                "HexNFCTestKit",
                "HexPromoKit",
            ],
            path: "Sources/HexNFCApp"
        ),
        // Session-agnostic live/simulated test plans + runner. UI-free; depends
        // only on the record + NFC layers so it links into the shipping app
        // (the DEBUG harness drives it) and into the sim XCTest unchanged.
        .target(
            name: "HexNFCTestKit",
            dependencies: ["HexNFCKit", "HexNFCRecords"],
            path: "Sources/HexNFCTestKit"
        ),
        // Test-only chip simulator. Declared as a regular target (no product),
        // so it does not link into the shipping app. Test targets depend on it.
        .target(
            name: "HexNFCTagSim",
            dependencies: ["HexNFCKit"],
            path: "Tests/HexNFCTagSim"
        ),
        .testTarget(
            name: "HexNFCRecordsTests",
            dependencies: [
                "HexNFCRecords",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ],
            path: "Tests/HexNFCRecordsTests"
        ),
        .testTarget(
            name: "HexNFCKitTests",
            dependencies: ["HexNFCKit", "HexNFCTagSim", "HexNFCTestKit"],
            path: "Tests/HexNFCKitTests"
        ),
        .testTarget(
            name: "HexNFCStorageTests",
            dependencies: ["HexNFCStorage", "HexNFCRecords"],
            path: "Tests/HexNFCStorageTests"
        ),
        .testTarget(
            name: "HexNFCAppTests",
            dependencies: [
                "HexNFCApp",
                "HexNFCDesign",
                "HexNFCKit",
                "HexNFCRecords",
                "HexNFCShaders",
                // App-level flows now take a credential store, so their tests
                // need to name `InMemoryTagCredentialStore`.
                "HexNFCStorage",
                "HexNFCTagSim",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ],
            path: "Tests/HexNFCAppTests"
        ),
        // Upstream's own suite, ported rather than rewritten, so a re-sync can
        // be diffed against the upstream file line by line. What the port had
        // to change is recorded in Sources/HexPromoKit/PROVENANCE.md.
        .testTarget(
            name: "HexPromoKitTests",
            dependencies: ["HexPromoKit"],
            path: "Tests/HexPromoKitTests"
        ),
    ]
)
