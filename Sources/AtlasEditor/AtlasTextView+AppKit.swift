#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import AtlasCore

/// The Atlas editor on macOS: a TextKit 2 text view over the page's Markdown. The text is the
/// file, always; styling and Live Preview are attributes only, so what's saved is exactly what
/// was typed.
@MainActor
public final class AtlasTextView: NSTextView {
    private let styling = EditorStyling()

    public var mode: EditorMode {
        get { styling.mode }
        set { styling.mode = newValue; restyle() }
    }

    public var theme: EditorTheme {
        get { styling.theme }
        set { styling.theme = newValue; restyle() }
    }

    /// The syntax map of the current text.
    public var syntax: PageSyntax { styling.syntax }

    /// Called after every change to the text, typed or programmatic.
    public var onTextChange: ((String) -> Void)?

    /// Called when a link is clicked (see `MarkdownEditing.shouldOpenLink`).
    public var onOpenLink: ((LinkTarget) -> Void)?

    /// Suggestions for a wiki link being typed: pages from the text so far, or the named page's
    /// headings once a `#` is typed (`LinkCompletionContext.page`). Without it, typing `[[`
    /// suggests nothing.
    public var linkCompletions: ((LinkCompletionContext) -> [LinkCompletion])?
    private var offered: [LinkCompletion] = []

    public convenience init() { self.init(frame: .zero) }

    override public convenience init(frame: NSRect) {
        // An explicit TextKit 2 stack: content storage, layout manager, container.
        let content = NSTextContentStorage()
        let layout = NSTextLayoutManager()
        content.addTextLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: frame.width, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.textContainer = container
        self.init(frame: frame, textContainer: container)
    }

    override public init(frame: NSRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        // Markdown is plain text: no rich-text paste, and no substitutions that would change it.
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        smartInsertDeleteEnabled = false
        textContainerInset = NSSize(width: 8, height: 12)
        isVerticallyResizable = true
        autoresizingMask = [.width]
        typingAttributes = styling.baseAttributes
    }

    override public var string: String {
        didSet { restyle(); onTextChange?(string) }
    }

    private var selection: Range<Int> {
        let r = selectedRange()
        return r.location..<(r.location + r.length)
    }

    private func restyle() {
        guard let storage = textStorage, !hasMarkedText() else { return }
        styling.restyleAll(storage, selection: selection)
        typingAttributes = styling.baseAttributes
    }

    override public func didChangeText() {
        super.didChangeText()
        restyle()
        onTextChange?(string)
        offerLinkCompletions()
    }

    // MARK: Wiki links

    private var completionContext: LinkCompletionContext? {
        guard linkCompletions != nil, selection.isEmpty else { return nil }
        return MarkdownEditing.linkCompletionContext(in: string, cursor: selection.lowerBound, syntax: syntax)
    }

    /// Typing inside `[[` opens the system completion list, narrowed as the typing goes on.
    private func offerLinkCompletions() {
        guard !hasMarkedText(), window != nil, let context = completionContext, let provider = linkCompletions else { return }
        offered = provider(context)
        if !offered.isEmpty { complete(nil) }
    }

    /// The completions for a wiki link being typed. Exposed for tests; the system list calls
    /// `completions(forPartialWordRange:indexOfSelectedItem:)`.
    public func currentLinkCompletions() -> [LinkCompletion] {
        guard let context = completionContext, let provider = linkCompletions else { return [] }
        offered = provider(context)
        return offered
    }

    override public var rangeForUserCompletion: NSRange {
        guard let context = completionContext else { return super.rangeForUserCompletion }
        return NSRange(location: context.range.lowerBound, length: context.range.count)
    }

    override public func completions(forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String]? {
        guard completionContext != nil else { return super.completions(forPartialWordRange: charRange, indexOfSelectedItem: index) }
        index.pointee = 0
        return offered.map { c in c.detail.map { "\(c.title) — \($0)" } ?? c.title }
    }

    override public func insertCompletion(_ word: String, forPartialWordRange charRange: NSRange, movement: Int, isFinal flag: Bool) {
        guard let context = completionContext else {
            return super.insertCompletion(word, forPartialWordRange: charRange, movement: movement, isFinal: flag)
        }
        // Only a final choice by Return, Tab or click inserts: arrowing through the list
        // previews nothing, and Escape leaves the typed text as it was.
        guard flag, movement != NSCancelTextMovement, movement != NSOtherTextMovement || !word.isEmpty else { return }
        let shown = offered.map { c in c.detail.map { "\(c.title) — \($0)" } ?? c.title }
        guard let i = shown.firstIndex(of: word) else { return }
        acceptLinkCompletion(offered[i], in: context)
    }

    /// Inserts a suggestion for the wiki link being typed.
    public func acceptLinkCompletion(_ completion: LinkCompletion, in context: LinkCompletionContext? = nil) {
        guard let context = context ?? completionContext else { return }
        perform(MarkdownEditing.accept(completion, in: context, text: string), actionName: "Insert Link")
    }

    /// Selects the start of a heading or block on this page and scrolls it to the top, with a
    /// brief highlight. False if the page has no such heading or block.
    @discardableResult
    public func reveal(_ anchor: EditorAnchor) -> Bool {
        guard let range = syntax.anchor(heading: anchor.heading, blockId: anchor.blockId, in: string) else { return false }
        let r = NSRange(location: range.lowerBound, length: range.count)
        setSelectedRange(NSRange(location: range.lowerBound, length: 0))
        scrollRangeToVisible(r)
        // Scrolled into view it may sit at the bottom; a link's target reads better at the top.
        if let layout = textLayoutManager, let content = textContentStorage,
           let start = content.location(content.documentRange.location, offsetBy: range.lowerBound),
           let upTo = NSTextRange(location: content.documentRange.location, end: start) {
            layout.ensureLayout(for: upTo)
            if let fragment = layout.textLayoutFragment(for: start) {
                scroll(NSPoint(x: 0, y: max(0, fragment.layoutFragmentFrame.minY + textContainerOrigin.y - 8)))
            }
        }
        if window != nil { showFindIndicator(for: r) }
        return true
    }

    /// A copied link (a URL, with its title as HTML) pastes as `[Title](url)`; anything else
    /// pastes as plain text.
    override public func paste(_ sender: Any?) {
        let board = NSPasteboard.general
        if let plain = board.string(forType: .string),
           let edit = MarkdownEditing.pasteLink(plain: plain, html: board.string(forType: .html), in: string, selection: selection, syntax: syntax) {
            perform(edit, actionName: "Paste")
            return
        }
        super.paste(sender)
    }

    /// Follows the link at a character, if a click there should (see `shouldOpenLink`).
    @discardableResult
    public func openLink(at index: Int, commandKey: Bool) -> Bool {
        guard let onOpenLink, let target = MarkdownEditing.shouldOpenLink(at: index, in: syntax, selection: selection, mode: mode, commandKey: commandKey) else { return false }
        onOpenLink(target)
        return true
    }

    override public func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        guard let storage = textStorage, !hasMarkedText() else { return }
        styling.selectionChanged(storage, to: selection)
    }

    // MARK: Editing

    /// Makes an edit through the text system, so it's undoable like typing.
    public func perform(_ edit: TextEdit, actionName: String? = nil) {
        let r = NSRange(location: edit.range.lowerBound, length: edit.range.count)
        guard shouldChangeText(in: r, replacementString: edit.replacement) else { return }
        textStorage?.replaceCharacters(in: r, with: NSAttributedString(string: edit.replacement, attributes: styling.baseAttributes))
        didChangeText()
        if let actionName { undoManager?.setActionName(actionName) }
        setSelectedRange(NSRange(location: edit.selection.lowerBound, length: edit.selection.count))
    }

    override public func insertNewline(_ sender: Any?) {
        if let edit = MarkdownEditing.newline(in: string, selection: selection, syntax: syntax) {
            perform(edit)
        } else {
            super.insertNewline(sender)
        }
    }

    override public func insertTab(_ sender: Any?) {
        if let edit = MarkdownEditing.indent(in: string, selection: selection, syntax: syntax) {
            perform(edit, actionName: "Indent")
        } else {
            super.insertTab(sender)
        }
    }

    override public func insertBacktab(_ sender: Any?) {
        if let edit = MarkdownEditing.outdent(in: string, selection: selection, syntax: syntax) {
            perform(edit, actionName: "Outdent")
        } else {
            super.insertBacktab(sender)
        }
    }

    @objc public func toggleStrong(_ sender: Any?) { wrap("**", "Bold") }
    @objc public func toggleEmphasis(_ sender: Any?) { wrap("_", "Italic") }
    @objc public func toggleInlineCode(_ sender: Any?) { wrap("`", "Code") }
    @objc public func toggleStrikethrough(_ sender: Any?) { wrap("~~", "Strikethrough") }
    @objc public func toggleHighlight(_ sender: Any?) { wrap("==", "Highlight") }

    /// Ticks or unticks the task on the cursor's line.
    @objc public func toggleTask(_ sender: Any?) {
        if let edit = MarkdownEditing.toggleTask(at: selection.lowerBound, onLine: true, in: string, syntax: syntax) {
            let keep = selectedRange()
            perform(edit, actionName: "Toggle Task")
            setSelectedRange(keep)
        }
    }

    private func wrap(_ marker: String, _ name: String) {
        perform(MarkdownEditing.toggleWrap(marker, in: string, selection: selection), actionName: name)
    }

    override public func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers {
        case "b": toggleStrong(nil); return true
        case "i": toggleEmphasis(nil); return true
        case "e": toggleInlineCode(nil); return true
        case "\r": toggleTask(nil); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    /// A click on a checkbox ticks it, without moving the cursor. A click on a link follows it
    /// (with ⌘, or in Live Preview when the cursor isn't in it).
    override public func mouseDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.shift, .command, .option, .control])
        if event.clickCount == 1, modifiers.isEmpty || modifiers == .command {
            let point = convert(event.locationInWindow, from: nil)
            let index = characterIndex(forInsertionAt: point)
            if openLink(at: index, commandKey: modifiers == .command) { return }
        }
        if event.clickCount == 1, modifiers.isEmpty {
            let index = characterIndex(forInsertionAt: convert(event.locationInWindow, from: nil))
            if let edit = MarkdownEditing.toggleTask(at: index, in: string, syntax: syntax) {
                let keep = selectedRange()
                perform(edit, actionName: "Toggle Task")
                setSelectedRange(keep)
                return
            }
        }
        super.mouseDown(with: event)
    }

    /// The character under a point (in the view's coordinates), rather than the insertion point
    /// nearest it: a click on the right half of a link's last character is still on the link,
    /// and a click past the end of a line is on nothing.
    private func characterIndex(forInsertionAt point: NSPoint) -> Int {
        guard let window else { return characterIndexForInsertion(at: point) }
        let screen = window.convertPoint(toScreen: convert(point, to: nil))
        let index = characterIndex(for: screen)
        return index == NSNotFound ? characterIndexForInsertion(at: point) : index
    }

    /// The view in a scroll view, ready to put in a window.
    public static func scrollable(frame: NSRect = .zero) -> (scrollView: NSScrollView, textView: AtlasTextView) {
        let scroll = NSScrollView(frame: frame)
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let text = AtlasTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        text.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        scroll.documentView = text
        return (scroll, text)
    }
}
#endif
