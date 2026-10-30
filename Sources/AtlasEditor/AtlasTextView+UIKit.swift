#if canImport(UIKit) && !os(watchOS)
import AtlasCore
import UIKit

/// The Atlas editor on iOS: a TextKit 2 text view over the page's Markdown. The text is the
/// file, always; styling and Live Preview are attributes only.
///
/// The view is its own `UITextViewDelegate`, to see selection changes; use `onTextChange`
/// rather than replacing `delegate`.
@MainActor
public final class AtlasTextView: UITextView, UITextViewDelegate {
    private let styling = EditorStyling()

    public var mode: EditorMode {
        get { styling.mode }
        set { styling.mode = newValue; restyle() }
    }

    public var theme: EditorTheme {
        get { styling.theme }
        set { styling.theme = newValue; restyle() }
    }

    public var syntax: PageSyntax { styling.syntax }

    /// Called after every change to the text, typed or programmatic.
    public var onTextChange: ((String) -> Void)?

    public convenience init() { self.init(frame: .zero) }

    public convenience init(frame: CGRect) {
        let content = NSTextContentStorage()
        let layout = NSTextLayoutManager()
        content.addTextLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: frame.width, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.textContainer = container
        self.init(frame: frame, textContainer: container)
    }

    override public init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        delegate = self
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        autocapitalizationType = .sentences
        dataDetectorTypes = []
        alwaysBounceVertical = true
        textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        typingAttributes = styling.baseAttributes
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)
    }

    override public var text: String! {
        didSet { restyle(); onTextChange?(text) }
    }

    private var selection: Range<Int> {
        let r = selectedRange
        return r.location..<(r.location + r.length)
    }

    private func restyle() {
        guard markedTextRange == nil else { return }
        let keep = selectedRange
        styling.restyleAll(textStorage, selection: selection)
        typingAttributes = styling.baseAttributes
        if selectedRange != keep { selectedRange = keep }
    }

    public func textViewDidChange(_ textView: UITextView) {
        restyle()
        onTextChange?(text)
    }

    public func textViewDidChangeSelection(_ textView: UITextView) {
        guard markedTextRange == nil else { return }
        styling.selectionChanged(textStorage, to: selection)
    }

    // MARK: Editing

    /// Makes an edit through the text input system, so it's undoable like typing.
    public func perform(_ edit: TextEdit) {
        guard let start = position(from: beginningOfDocument, offset: edit.range.lowerBound),
              let end = position(from: beginningOfDocument, offset: edit.range.upperBound),
              let range = textRange(from: start, to: end) else { return }
        replace(range, withText: edit.replacement)
        restyle()
        onTextChange?(text)
        selectedRange = NSRange(location: edit.selection.lowerBound, length: edit.selection.count)
    }

    override public func insertText(_ text: String) {
        if text == "\n", let edit = MarkdownEditing.newline(in: self.text, selection: selection, syntax: syntax) {
            perform(edit)
        } else if text == "\t", let edit = MarkdownEditing.indent(in: self.text, selection: selection, syntax: syntax) {
            perform(edit)
        } else {
            super.insertText(text)
        }
    }

    override public var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(input: "\t", modifierFlags: .shift, action: #selector(outdent(_:))),
            UIKeyCommand(title: "Bold", action: #selector(toggleStrong(_:)), input: "b", modifierFlags: .command),
            UIKeyCommand(title: "Italic", action: #selector(toggleEmphasis(_:)), input: "i", modifierFlags: .command),
            UIKeyCommand(title: "Code", action: #selector(toggleInlineCode(_:)), input: "e", modifierFlags: .command),
            UIKeyCommand(title: "Toggle Task", action: #selector(toggleTask(_:)), input: "\r", modifierFlags: .command),
        ]
    }

    @objc public func outdent(_ sender: Any?) {
        if let edit = MarkdownEditing.outdent(in: text, selection: selection, syntax: syntax) { perform(edit) }
    }

    @objc public func toggleStrong(_ sender: Any?) { perform(MarkdownEditing.toggleWrap("**", in: text, selection: selection)) }
    @objc public func toggleEmphasis(_ sender: Any?) { perform(MarkdownEditing.toggleWrap("_", in: text, selection: selection)) }
    @objc public func toggleInlineCode(_ sender: Any?) { perform(MarkdownEditing.toggleWrap("`", in: text, selection: selection)) }
    @objc public func toggleStrikethrough(_ sender: Any?) { perform(MarkdownEditing.toggleWrap("~~", in: text, selection: selection)) }
    @objc public func toggleHighlight(_ sender: Any?) { perform(MarkdownEditing.toggleWrap("==", in: text, selection: selection)) }

    @objc public func toggleTask(_ sender: Any?) {
        if let edit = MarkdownEditing.toggleTask(at: selection.lowerBound, onLine: true, in: text, syntax: syntax) {
            let keep = selectedRange
            perform(edit)
            selectedRange = keep
        }
    }

    /// A tap on a checkbox ticks it.
    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        guard let position = closestPosition(to: gesture.location(in: self)) else { return }
        let offset = self.offset(from: beginningOfDocument, to: position)
        if let edit = MarkdownEditing.toggleTask(at: offset, in: text, syntax: syntax) {
            perform(edit)
        }
    }
}
#endif
