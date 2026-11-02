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

    /// The `/` menu's commands. Nil turns the menu off.
    public var slashCommands: (() -> [SlashCommand])? = { SlashCommand.builtIn() }
    private var offeredCommands: [SlashCommand] = []

    /// The bytes of an image the page shows (`![[photo.png]]`, `![](photo.png)`), for Live
    /// Preview to draw in place of its Markdown. Nil, or nil bytes, leave the Markdown showing.
    public var imageData: ((ImageSource) -> Data?)? {
        didSet { reloadImages() }
    }
    private var decodedImages: [ImageSource: CGImage?] = [:]
    private let imageFragments = ImageFragments()
    private var styledWidth: CGFloat = 0

    /// Saves images pasted, dropped or picked (`insertImages`) into the vault, and returns the
    /// link target for each, in order. Nil leaves pasting and dropping as they were.
    public var importImages: (([ImageImport]) -> [String])?

    /// Forgets the decoded images and asks `imageData` again, for when the vault's files change.
    public func reloadImages() {
        decodedImages = [:]
        restyle()
    }

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
        imageFragments.padding = styling.theme.imagePadding
        textLayoutManager?.delegate = imageFragments
        registerForDraggedTypes(registeredDraggedTypes + [.fileURL, .png, .tiff, Self.jpeg, Self.heic])
        styling.image = { [weak self] in self?.shownImage($0) }
    }

    private func shownImage(_ found: BlockImage) -> ShownImage? {
        guard let imageData, let container = textContainer else { return nil }
        let available = container.size.width - 2 * container.lineFragmentPadding
        guard available > 0 else { return nil }
        if decodedImages[found.source] == nil { decodedImages[found.source] = Self.decode(found.source, imageData) }
        guard let image = decodedImages[found.source] ?? nil else { return nil }
        let size = ShownImage.size(of: image, width: found.width, available: available)
        return size.width > 0 ? ShownImage(image: image, size: size) : nil
    }

    /// Images are sized to the width, so a new width lays them out again.
    override public func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard imageData != nil, newSize.width != styledWidth else { return }
        styledWidth = newSize.width
        DispatchQueue.main.async { [weak self] in self?.restyle() }
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

    private var slashContext: SlashContext? {
        guard slashCommands != nil, selection.isEmpty, completionContext == nil else { return nil }
        return MarkdownEditing.slashContext(in: string, cursor: selection.lowerBound, syntax: syntax)
    }

    /// Typing inside `[[`, or a `/` command, opens the system completion list, narrowed as the
    /// typing goes on.
    private func offerLinkCompletions() {
        guard !hasMarkedText(), window != nil else { return }
        if let context = completionContext, let provider = linkCompletions {
            offered = provider(context)
            if !offered.isEmpty { complete(nil) }
        } else if slashContext != nil, !currentSlashCommands().isEmpty {
            complete(nil)
        }
    }

    /// The `/` commands for what's typed after the `/`. Exposed for tests, like
    /// `currentLinkCompletions`.
    public func currentSlashCommands() -> [SlashCommand] {
        guard let context = slashContext, let provider = slashCommands else { return [] }
        offeredCommands = MarkdownEditing.slashCommands(provider(), matching: context.query)
        return offeredCommands
    }

    /// Runs a `/` command in place of the `/` being typed.
    public func applySlashCommand(_ command: SlashCommand, in context: SlashContext? = nil) {
        guard let context = context ?? slashContext else { return }
        perform(MarkdownEditing.apply(command, in: context, text: string), actionName: command.title)
    }

    /// The completions for a wiki link being typed. Exposed for tests; the system list calls
    /// `completions(forPartialWordRange:indexOfSelectedItem:)`.
    public func currentLinkCompletions() -> [LinkCompletion] {
        guard let context = completionContext, let provider = linkCompletions else { return [] }
        offered = provider(context)
        return offered
    }

    override public var rangeForUserCompletion: NSRange {
        if let context = completionContext { return NSRange(location: context.range.lowerBound, length: context.range.count) }
        if let context = slashContext { return NSRange(location: context.range.lowerBound, length: context.range.count) }
        return super.rangeForUserCompletion
    }

    override public func completions(forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String]? {
        if completionContext != nil {
            index.pointee = 0
            return offered.map { c in c.detail.map { "\(c.title) — \($0)" } ?? c.title }
        }
        if slashContext != nil {
            index.pointee = 0
            return currentSlashCommands().map(\.title)
        }
        return super.completions(forPartialWordRange: charRange, indexOfSelectedItem: index)
    }

    override public func insertCompletion(_ word: String, forPartialWordRange charRange: NSRange, movement: Int, isFinal flag: Bool) {
        // Only a final choice by Return, Tab or click inserts: arrowing through the list
        // previews nothing, and Escape leaves the typed text as it was.
        let chosen = flag && movement != NSCancelTextMovement && (movement != NSOtherTextMovement || !word.isEmpty)
        if let context = completionContext {
            guard chosen else { return }
            let shown = offered.map { c in c.detail.map { "\(c.title) — \($0)" } ?? c.title }
            guard let i = shown.firstIndex(of: word) else { return }
            acceptLinkCompletion(offered[i], in: context)
        } else if let context = slashContext {
            guard chosen, let command = offeredCommands.first(where: { $0.title == word }) else { return }
            applySlashCommand(command, in: context)
        } else {
            super.insertCompletion(word, forPartialWordRange: charRange, movement: movement, isFinal: flag)
        }
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
        // Image files (a Finder copy), or an image with no text (a screenshot).
        if importImages != nil {
            let images = Self.images(on: board, preferText: true)
            AtlasLog.editor.info("Paste: \(Self.describe(board)) → \(images.isEmpty ? "as text" : "\(images.count) image(s)")")
            if !images.isEmpty {
                insertImages(images)
                return
            }
        }
        if let plain = board.string(forType: .string),
           let edit = MarkdownEditing.pasteLink(plain: plain, html: board.string(forType: .html), in: string, selection: selection, syntax: syntax) {
            perform(edit, actionName: "Paste")
            return
        }
        super.paste(sender)
    }

    // MARK: Images

    private static let jpeg = NSPasteboard.PasteboardType("public.jpeg")
    private static let heic = NSPasteboard.PasteboardType("public.heic")

    /// Adds images at the selection: `importImages` saves them, and each is embedded on a line
    /// of its own, which Live Preview shows as the image. One undoable edit.
    public func insertImages(_ images: [ImageImport]) {
        guard let importImages, !images.isEmpty else {
            AtlasLog.images.notice("Insert of \(images.count) image(s) ignored: \(self.importImages == nil ? "the app takes no images" : "none")")
            return
        }
        let targets = importImages(images)
        AtlasLog.images.info("Inserting \(images.count) image(s) at \(self.selection.lowerBound): \(targets.map { "![[\($0)]]" }.joined(separator: ", "))")
        if let edit = MarkdownEditing.insertEmbeds(targets, in: string, selection: selection) {
            perform(edit, actionName: targets.count == 1 ? "Insert Image" : "Insert Images")
        }
    }

    /// The images on a pasteboard: image files, else image data, as PNG for TIFF. With
    /// `preferText`, image data that comes with text (a copy from a document) is left to paste as text.
    static func images(on board: NSPasteboard, preferText: Bool) -> [ImageImport] {
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls.compactMap { url in
                guard let data = try? Data(contentsOf: url), ImageImport.fileExtension(of: data) != nil else { return nil }
                return ImageImport(data: data, name: url.lastPathComponent)
            }
        }
        if preferText, board.string(forType: .string) != nil { return [] }
        for type in [NSPasteboard.PasteboardType.png, jpeg, heic] {
            if let data = board.data(forType: type) { return [ImageImport(data: data)] }
        }
        if let tiff = board.data(forType: .tiff), let png = ShownImage.png(from: tiff) { return [ImageImport(data: png)] }
        return []
    }

    /// A pasteboard's types and file names, for the log.
    static func describe(_ board: NSPasteboard) -> String {
        let types = board.types?.map(\.rawValue).joined(separator: ", ") ?? "none"
        let urls = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        return "types [\(types)]" + (urls.isEmpty ? "" : ", files [\(urls.map(\.lastPathComponent).joined(separator: ", "))]")
    }

    /// Whether a drag carries images, judged without reading files: called as it moves.
    private static func carriesImages(_ board: NSPasteboard) -> Bool {
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls.contains { MarkdownEditing.imageExtensions.contains($0.pathExtension.lowercased()) }
        }
        return board.availableType(from: [.png, .tiff, jpeg, heic]) != nil
    }

    override public func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = super.draggingUpdated(sender)
        return importImages != nil && Self.carriesImages(sender.draggingPasteboard) ? .copy : operation
    }

    /// Images dropped on the page go in where they're dropped.
    override public func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let board = sender.draggingPasteboard
        guard importImages != nil, Self.carriesImages(board) else {
            AtlasLog.editor.info("Drop: \(Self.describe(board)) → as text")
            return super.performDragOperation(sender)
        }
        let images = Self.images(on: board, preferText: false)
        AtlasLog.editor.info("Drop: \(Self.describe(board)) → \(images.count) image(s)")
        guard !images.isEmpty else { return false }
        let at = characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))
        window?.makeFirstResponder(self)
        setSelectedRange(NSRange(location: at, length: 0))
        insertImages(images)
        return true
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

    /// Moves the selected lines, or the block they're in, up or down past the next block.
    @objc public func moveLinesUp(_ sender: Any?) { move(.up) }
    @objc public func moveLinesDown(_ sender: Any?) { move(.down) }

    private func move(_ direction: MoveDirection) {
        if let edit = MarkdownEditing.moveLines(direction, in: string, selection: selection, syntax: syntax) {
            perform(edit, actionName: direction == .up ? "Move Up" : "Move Down")
            scrollRangeToVisible(selectedRange())
        }
    }

    private func wrap(_ marker: String, _ name: String) {
        perform(MarkdownEditing.toggleWrap(marker, in: string, selection: selection), actionName: name)
    }

    override public func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, event.modifierFlags.intersection([.shift, .command, .option, .control]) == [.command, .option] {
            switch event.specialKey {
            case .upArrow?: moveLinesUp(nil); return true
            case .downArrow?: moveLinesDown(nil); return true
            default: break
            }
        }
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
            // A click on an image shows its Markdown, to edit; it doesn't follow the embed.
            if modifiers.isEmpty, let block = styling.imageBlocks.first(where: { $0.lowerBound <= index && index <= $0.upperBound }) {
                window?.makeFirstResponder(self)
                setSelectedRange(NSRange(location: block.upperBound, length: 0))
                return
            }
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
