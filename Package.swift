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
//   AtlasEditor  (later) the TextKit 2 editor, with AppKit and UIKit adapters.
//   AtlasUI      (later) SwiftUI views shared by both apps.
//
// Identity, keys and crypto come from NeutrinoShared (../neutrino_shared_ios), which is added
// as a dependency when sync needs it. NeutrinoShared must never depend on this package.
let package = Package(
    name: "AtlasKit",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "AtlasCore", targets: ["AtlasCore"]),
    ],
    dependencies: [
        // The CommonMark + GFM base (SPEC §2): GitHub's cmark-gfm, as packaged by swiftlang. It is
        // used directly rather than through swift-markdown, which always enables a non-GFM
        // table-spans extension and doesn't attach GFM's autolink extension. The Atlas extensions
        // are layered on top in AtlasCore's parser.
        .package(url: "https://github.com/swiftlang/swift-cmark", from: "0.9.0"),
        // Frontmatter is YAML (SPEC §4.1, §6).
        .package(url: "https://github.com/jpsim/Yams", from: "5.1.3"),
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
        .testTarget(
            name: "AtlasCoreTests",
            dependencies: ["AtlasCore"],
            // The vendored conformance corpus, copied verbatim (scripts/sync-atlas-markdown-corpus.sh).
            resources: [.copy("Fixtures/atlas-markdown")]
        ),
    ]
)
