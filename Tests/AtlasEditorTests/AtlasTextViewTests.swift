import AtlasCore
import ImageIO
import XCTest
@testable import AtlasEditor
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#else
import UIKit
#endif

/// The real text view: TextKit 2, styles applied to its storage, commands wired to its keys.
@MainActor
final class AtlasTextViewTests: XCTestCase {
    private func make(_ text: String) -> AtlasTextView {
        let view = AtlasTextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        view.string = text
        #else
        view.text = text
        #endif
        return view
    }

    private func content(_ view: AtlasTextView) -> String {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        return view.string
        #else
        return view.text
        #endif
    }

    private func select(_ view: AtlasTextView, _ r: NSRange) {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        view.setSelectedRange(r)
        #else
        view.selectedRange = r
        #endif
    }

    private func storage(_ view: AtlasTextView) -> NSTextStorage {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        return view.textStorage!
        #else
        return view.textStorage
        #endif
    }

    private func isHidden(_ view: AtlasTextView, at offset: Int) -> Bool {
        let font = storage(view).attribute(.font, at: offset, effectiveRange: nil) as! PlatformFont
        return font.pointSize < 1
    }

    func testUsesTextKit2() {
        XCTAssertNotNil(make("x").textLayoutManager)
    }

    func testLivePreviewFollowsTheSelection() {
        let view = make("Some **bold** text\n")
        select(view, NSRange(location: 0, length: 0))
        XCTAssertTrue(isHidden(view, at: 5), "`**` hidden with the cursor elsewhere")
        select(view, NSRange(location: 8, length: 0))
        XCTAssertFalse(isHidden(view, at: 5), "`**` shown with the cursor in the bold")
        let font = storage(view).attribute(.font, at: 8, effectiveRange: nil) as! PlatformFont
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold))
        #else
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.traitBold))
        #endif
        view.mode = .source
        select(view, NSRange(location: 0, length: 0))
        XCTAssertFalse(isHidden(view, at: 5))
    }

    func testTheTextIsNeverChangedByStyling() {
        let page = "# A\n\n- [ ] t **b** [[P|x]]\n"
        let view = make(page)
        for offset in 0...page.utf16.count { select(view, NSRange(location: offset, length: 0)) }
        XCTAssertEqual(content(view), page)
    }

    func testReturnContinuesAList() {
        let view = make("- one")
        select(view, NSRange(location: 5, length: 0))
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        view.insertNewline(nil)
        view.insertText("two", replacementRange: view.selectedRange())
        #else
        view.insertText("\n")
        view.insertText("two")
        #endif
        XCTAssertEqual(content(view), "- one\n- two")
    }

    func testTabIndentsAndTaskTogglesInPlace() {
        var changes: [String] = []
        let view = make("- [ ] a\n- [ ] b")
        view.onTextChange = { changes.append($0) }
        select(view, NSRange(location: 13, length: 0))
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        view.insertTab(nil)
        #else
        view.insertText("\t")
        #endif
        XCTAssertEqual(content(view), "- [ ] a\n  - [ ] b")
        view.toggleTask(nil)
        XCTAssertEqual(content(view), "- [ ] a\n  - [x] b")
        XCTAssertEqual(changes.last, "- [ ] a\n  - [x] b")
    }

    func testMovingLinesKeepsTheCursorAndReportsTheChange() {
        var changes: [String] = []
        let view = make("- a\n- b\n  - b1")
        view.onTextChange = { changes.append($0) }
        select(view, NSRange(location: 6, length: 0))
        view.moveLinesUp(nil)
        XCTAssertEqual(content(view), "- b\n  - b1\n- a")
        XCTAssertEqual(selected(view), NSRange(location: 2, length: 0))
        view.moveLinesDown(nil)
        XCTAssertEqual(content(view), "- a\n- b\n  - b1")
        XCTAssertEqual(changes.last, "- a\n- b\n  - b1")
    }

    private func png(width: Int, height: Int) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 1, green: 0.5, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let out = NSMutableData()
        let destination = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return out as Data
    }

    private func fragment(_ view: AtlasTextView, at offset: Int) -> NSTextLayoutFragment? {
        guard let layout = view.textLayoutManager, let content = layout.textContentManager,
              let location = content.location(content.documentRange.location, offsetBy: offset) else { return nil }
        layout.ensureLayout(for: layout.documentRange)
        return layout.textLayoutFragment(for: location)
    }

    func testAnImageShowsInPlaceOfItsMarkdownAwayFromTheCursor() {
        let text = "Intro\n\n![[photo.png|40]]\n\n![[missing.png]]\n\n![[wide.png]]"
        let view = make(text)
        select(view, NSRange(location: 0, length: 0))
        view.imageData = { [unowned self] source in
            guard case .embed(let ref) = source else { return nil }
            switch ref.target {
            case "photo.png": return png(width: 80, height: 40)
            case "wide.png": return png(width: 3000, height: 300)
            default: return nil
            }
        }
        let ns = text as NSString
        let photo = ns.range(of: "![[photo").location, missing = ns.range(of: "![[missing").location, wide = ns.range(of: "![[wide").location

        // The width hint, kept in proportion; a wide image fits the width.
        let shown = storage(view).attribute(.atlasImage, at: photo, effectiveRange: nil) as? ShownImage
        XCTAssertEqual(shown?.size, CGSize(width: 40, height: 20))
        XCTAssertTrue(isHidden(view, at: photo))
        let fitted = storage(view).attribute(.atlasImage, at: wide, effectiveRange: nil) as? ShownImage
        XCTAssertLessThan(fitted?.size.width ?? .infinity, 400)
        XCTAssertEqual(fitted.map { $0.size.width / $0.size.height } ?? 0, 10, accuracy: 0.3, "heights are whole points")
        // An image with no bytes leaves its Markdown.
        XCTAssertNil(storage(view).attribute(.atlasImage, at: missing, effectiveRange: nil))
        XCTAssertFalse(isHidden(view, at: missing + 3))

        // Its line is as tall as the image, and draws it.
        let line = fragment(view, at: photo)
        XCTAssertTrue(line is ImageLayoutFragment, "\(String(describing: line))")
        XCTAssertEqual(line?.layoutFragmentFrame.height ?? 0, 20 + 2 * view.theme.imagePadding, accuracy: 1)

        // With the cursor in it, the Markdown shows to edit; the text is never changed.
        select(view, NSRange(location: photo + 4, length: 0))
        XCTAssertNil(storage(view).attribute(.atlasImage, at: photo, effectiveRange: nil))
        XCTAssertFalse(isHidden(view, at: photo + 4))
        XCTAssertFalse(fragment(view, at: photo) is ImageLayoutFragment)
        XCTAssertEqual(content(view), text)
    }

    private func type(_ view: AtlasTextView, _ text: String) {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        view.insertText(text, replacementRange: view.selectedRange())
        #else
        view.insertText(text)
        #endif
    }

    func testTypingAWikiLinkSuggestsPagesAndAcceptingClosesIt() {
        let view = make("")
        var queries: [String] = []
        view.linkCompletions = { context in
            let query = context.query
            queries.append(query)
            return [LinkCompletion(title: "Plan", target: "Plan", detail: "Projects")].filter { query.isEmpty || $0.title.hasPrefix(query) }
        }
        type(view, "See [[Pl")
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        XCTAssertEqual(view.currentLinkCompletions().map(\.title), ["Plan"])
        view.acceptLinkCompletion(LinkCompletion(title: "Plan", target: "Plan"))
        #else
        XCTAssertEqual(view.currentLinkCompletions.map(\.title), ["Plan"])
        view.acceptLinkCompletion(view.currentLinkCompletions[0])
        #endif
        XCTAssertEqual(queries.last, "Pl")
        XCTAssertEqual(content(view), "See [[Plan]]")
    }

    func testTypingASlashOffersCommands() {
        let view = make("Plans")
        select(view, NSRange(location: 5, length: 0))
        type(view, " /h2")
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        XCTAssertEqual(view.currentSlashCommands().map(\.id), ["h2"])
        view.applySlashCommand(view.currentSlashCommands()[0])
        #else
        XCTAssertEqual(view.currentSlashCommands.map(\.id), ["h2"])
        view.applySlashCommand(view.currentSlashCommands[0])
        #endif
        XCTAssertEqual(content(view), "## Plans")
        view.slashCommands = nil
        type(view, " /h")
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        XCTAssertEqual(view.currentSlashCommands(), [])
        #else
        XCTAssertEqual(view.currentSlashCommands, [])
        #endif
    }

    func testRevealingAHeadingSelectsItsStart() {
        let view = make("# Top\n\n" + String(repeating: "Line\n\n", count: 80) + "## Far down\n\nText ^tail\n")
        let heading = (content(view) as NSString).range(of: "## Far down").location
        XCTAssertTrue(view.reveal(EditorAnchor(heading: "far down")))
        XCTAssertEqual(selected(view), NSRange(location: heading, length: 0))
        XCTAssertTrue(view.reveal(EditorAnchor(blockId: "tail")))
        XCTAssertEqual(selected(view).location, (content(view) as NSString).range(of: "Text ^tail").location)
        XCTAssertFalse(view.reveal(EditorAnchor(heading: "Nowhere")))
    }

    private func selected(_ view: AtlasTextView) -> NSRange {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        return view.selectedRange()
        #else
        return view.selectedRange
        #endif
    }

    func testClickingALinkShownAsALinkOpensIt() {
        let view = make("Go to [[Plan]] now\n")
        var opened: [LinkTarget] = []
        view.onOpenLink = { opened.append($0) }
        select(view, NSRange(location: 0, length: 0))
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        XCTAssertTrue(view.openLink(at: 9, commandKey: false))
        select(view, NSRange(location: 9, length: 0))
        XCTAssertFalse(view.openLink(at: 9, commandKey: false), "with the cursor in it, a click edits it")
        XCTAssertTrue(view.openLink(at: 9, commandKey: true))
        XCTAssertEqual(opened, [.wiki(WikiLinkReference(target: "Plan")), .wiki(WikiLinkReference(target: "Plan"))])
        #else
        XCTAssertEqual(MarkdownEditing.shouldOpenLink(at: 9, in: view.syntax, selection: 0..<0, mode: view.mode, commandKey: false), .wiki(WikiLinkReference(target: "Plan")))
        #endif
    }
}
