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

    /// A click on a checkbox ticks it, without moving the cursor.
    override public func mouseDown(with event: NSEvent) {
        if event.clickCount == 1, event.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty {
            let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
            if let edit = MarkdownEditing.toggleTask(at: index, in: string, syntax: syntax) {
                let keep = selectedRange()
                perform(edit, actionName: "Toggle Task")
                setSelectedRange(keep)
                return
            }
        }
        super.mouseDown(with: event)
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
