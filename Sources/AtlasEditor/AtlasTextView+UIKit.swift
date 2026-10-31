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

    /// Called when a link is tapped (see `MarkdownEditing.shouldOpenLink`).
    public var onOpenLink: ((LinkTarget) -> Void)?

    /// Suggestions for a wiki link being typed, shown above the keyboard.
    public var linkCompletions: ((LinkCompletionContext) -> [LinkCompletion])?
    private lazy var suggestionBar = LinkSuggestionBar { [weak self] in self?.acceptSuggestion($0) }

    /// The `/` menu's commands, shown above the keyboard. Nil turns the menu off.
    public var slashCommands: (() -> [SlashCommand])? = { SlashCommand.builtIn() }
    /// What the bar offers while a `/` command is typed.
    public private(set) var currentSlashCommands: [SlashCommand] = []

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
        updateSuggestions()
    }

    public func textViewDidChangeSelection(_ textView: UITextView) {
        guard markedTextRange == nil else { return }
        styling.selectionChanged(textStorage, to: selection)
        updateSuggestions()
    }

    // MARK: Wiki links

    private var completionContext: LinkCompletionContext? {
        guard linkCompletions != nil, selection.isEmpty else { return nil }
        return MarkdownEditing.linkCompletionContext(in: text, cursor: selection.lowerBound, syntax: syntax)
    }

    /// What the suggestion bar offers right now.
    public var currentLinkCompletions: [LinkCompletion] { suggestionBar.completions }

    private var slashContext: SlashContext? {
        guard slashCommands != nil, selection.isEmpty, completionContext == nil else { return nil }
        return MarkdownEditing.slashContext(in: text, cursor: selection.lowerBound, syntax: syntax)
    }

    private func updateSuggestions() {
        var completions = completionContext.flatMap { context in linkCompletions?(context) } ?? []
        currentSlashCommands = []
        if completions.isEmpty, let context = slashContext, let provider = slashCommands {
            currentSlashCommands = Array(MarkdownEditing.slashCommands(provider(), matching: context.query).prefix(8))
            // The bar shows commands as suggestions; the target carries the command's id.
            completions = currentSlashCommands.map { LinkCompletion(title: $0.title, target: $0.id) }
        }
        suggestionBar.isCommands = !currentSlashCommands.isEmpty
        suggestionBar.completions = Array(completions.prefix(8))
        let wanted: UIView? = completions.isEmpty ? nil : suggestionBar
        if inputAccessoryView !== wanted {
            inputAccessoryView = wanted
            reloadInputViews()
        }
    }

    private func acceptSuggestion(_ suggestion: LinkCompletion) {
        if let command = currentSlashCommands.first(where: { $0.id == suggestion.target }) {
            applySlashCommand(command)
        } else {
            acceptLinkCompletion(suggestion)
        }
    }

    /// Runs a `/` command in place of the `/` being typed.
    public func applySlashCommand(_ command: SlashCommand) {
        guard let context = slashContext else { return }
        perform(MarkdownEditing.apply(command, in: context, text: text))
        updateSuggestions()
    }

    /// Inserts a suggestion for the wiki link being typed.
    public func acceptLinkCompletion(_ completion: LinkCompletion) {
        guard let context = completionContext else { return }
        perform(MarkdownEditing.accept(completion, in: context, text: text))
        updateSuggestions()
    }

    /// Puts the cursor at the start of a heading or block on this page and scrolls to it.
    /// False if the page has no such heading or block.
    @discardableResult
    public func reveal(_ anchor: EditorAnchor) -> Bool {
        guard let range = syntax.anchor(heading: anchor.heading, blockId: anchor.blockId, in: text) else { return false }
        selectedRange = NSRange(location: range.lowerBound, length: 0)
        scrollRangeToVisible(NSRange(location: range.lowerBound, length: range.count))
        return true
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

    /// A copied link (a URL, with its title as HTML) pastes as `[Title](url)`; anything else
    /// pastes as plain text.
    override public func paste(_ sender: Any?) {
        let board = UIPasteboard.general
        let html = (board.value(forPasteboardType: "public.html") as? String)
            ?? board.data(forPasteboardType: "public.html").flatMap { String(data: $0, encoding: .utf8) }
        if let plain = board.string,
           let edit = MarkdownEditing.pasteLink(plain: plain, html: html, in: text, selection: selection, syntax: syntax) {
            perform(edit)
            return
        }
        super.paste(sender)
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
            UIKeyCommand(title: "Move Up", action: #selector(moveLinesUp(_:)), input: UIKeyCommand.inputUpArrow, modifierFlags: [.command, .alternate]),
            UIKeyCommand(title: "Move Down", action: #selector(moveLinesDown(_:)), input: UIKeyCommand.inputDownArrow, modifierFlags: [.command, .alternate]),
        ]
    }

    @objc public func outdent(_ sender: Any?) {
        if let edit = MarkdownEditing.outdent(in: text, selection: selection, syntax: syntax) { perform(edit) }
    }

    /// Moves the selected lines, or the block they're in, up or down past the next block.
    @objc public func moveLinesUp(_ sender: Any?) { move(.up) }
    @objc public func moveLinesDown(_ sender: Any?) { move(.down) }

    private func move(_ direction: MoveDirection) {
        if let edit = MarkdownEditing.moveLines(direction, in: text, selection: selection, syntax: syntax) {
            perform(edit)
            scrollRangeToVisible(selectedRange)
        }
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

    /// A tap on a checkbox ticks it; a tap on a link shown as a link follows it.
    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        guard let position = closestPosition(to: gesture.location(in: self)) else { return }
        let offset = self.offset(from: beginningOfDocument, to: position)
        if let edit = MarkdownEditing.toggleTask(at: offset, in: text, syntax: syntax) {
            perform(edit)
        } else if let onOpenLink, let target = MarkdownEditing.shouldOpenLink(at: offset, in: syntax, selection: tapSelection, mode: mode, commandKey: false) {
            onOpenLink(target)
        }
    }

    /// The selection before the tap moved it: whether the link showed as a link is decided by
    /// where the cursor was.
    private var tapSelection = 0..<0

    override public func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        tapSelection = selection
        super.touchesBegan(touches, with: event)
    }
}
/// The suggestions above the keyboard: a row of buttons, one per page, or per `/` command.
final class LinkSuggestionBar: UIInputView {
    var completions: [LinkCompletion] = [] { didSet { if completions != oldValue { rebuild() } } }
    var isCommands = false
    private let accept: (LinkCompletion) -> Void
    private let stack = UIStackView()

    init(accept: @escaping (LinkCompletion) -> Void) {
        self.accept = accept
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 44), inputViewStyle: .keyboard)
        autoresizingMask = .flexibleWidth
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used from a storyboard") }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for completion in completions {
            var config = UIButton.Configuration.gray()
            config.title = completion.title
            config.subtitle = completion.detail
            config.cornerStyle = .capsule
            let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in self?.accept(completion) })
            button.accessibilityLabel = isCommands ? completion.title : "Link to \(completion.title)"
            stack.addArrangedSubview(button)
        }
    }
}
#endif
