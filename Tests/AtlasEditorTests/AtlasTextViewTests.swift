import AtlasCore
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
}
