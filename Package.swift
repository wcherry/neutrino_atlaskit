// swift-tools-version: 5.9
import PackageDescription

// The code Neutrino Atlas shares between its macOS and iOS apps: the Atlas Markdown dialect,
// the page index, the editor and the shared views. See neutrino/agent_docs/neutrino-atlas.md
// (constraint 6) and the dialect's spec, neutrino/specs/atlas-markdown/SPEC.md.
//
// It is consumed by local path (`../neutrino_atlaskit`) by both Atlas apps, so a change here
// reaches both the next time they build. Run the tests on macOS and iOS.
//
// Layers, added as each gets code:
//
//   AtlasCore    Foundation, cmark-gfm, Yams and the system SQLite only. The Atlas Markdown
//                tree, parser and serializer, extraction (§6), link resolution (§7) and the
//                vault index, and later sync. Must stay linkable from share extensions,
//                widgets and App Intents: no UI frameworks.
//   AtlasDrive   Sync's transport: the vault on Neutrino Drive (HTTP, folders, and encryption
//                with NeutrinoCrypto). Kept out of AtlasCore so the engine and everything else
//                there stay testable without libsodium or a network.
//   AtlasEditor  The TextKit 2 editor: AtlasTextView for AppKit and UIKit, and AtlasEditorView for
//                SwiftUI. Its styling and Markdown commands are Foundation-only and tested
//                without a UI. Depends on AtlasCore only.
//   AtlasUI      (later) SwiftUI views shared by both apps.
//
// Identity, keys and crypto come from NeutrinoShared (../neutrino_shared_ios), consumed by local
// path like every other Neutrino Apple client, so this repository sits beside it. NeutrinoShared
// must never depend on this package.
let package = Package(
    name: "AtlasKit",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "AtlasCore", targets: ["AtlasCore"]),
        .library(name: "AtlasDrive", targets: ["AtlasDrive"]),
        .library(name: "AtlasEditor", targets: ["AtlasEditor"]),
    ],
    dependencies: [
        // The CommonMark + GFM base (SPEC §2): GitHub's cmark-gfm, as packaged by swiftlang. It is
        // used directly rather than through swift-markdown, which always enables a non-GFM
        // table-spans extension and doesn't attach GFM's autolink extension. The Atlas extensions
        // are layered on top in AtlasCore's parser.
        .package(url: "https://github.com/swiftlang/swift-cmark", from: "0.9.0"),
        // Frontmatter is YAML (SPEC §4.1, §6).
        .package(url: "https://github.com/jpsim/Yams", from: "5.1.3"),
        .package(path: "../neutrino_shared_ios"),
    ],
    targets: [
        .target(
            name: "AtlasCore",
            dependencies: [
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
                "Yams",
            ]
        ),
        .target(
            name: "AtlasDrive",
            dependencies: [
                "AtlasCore",
                .product(name: "NeutrinoCore", package: "neutrino_shared_ios"),
                .product(name: "NeutrinoCrypto", package: "neutrino_shared_ios"),
            ]
        ),
        .target(
            name: "AtlasEditor",
            dependencies: ["AtlasCore"]
        ),
        .testTarget(
            name: "AtlasEditorTests",
            dependencies: ["AtlasEditor"]
        ),
        .testTarget(
            name: "AtlasDriveTests",
            dependencies: ["AtlasDrive", .product(name: "NeutrinoCrypto", package: "neutrino_shared_ios")]
        ),
        .testTarget(
            name: "AtlasCoreTests",
            dependencies: ["AtlasCore"],
            // The vendored conformance corpus, copied verbatim (scripts/sync-atlas-markdown-corpus.sh).
            resources: [.copy("Fixtures/atlas-markdown")]
        ),
    ]
)
