#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import AtlasCore

/// The grip shown in the left margin beside the block under the pointer. Dragging it moves the
/// block (`AtlasTextView.moveBlock`): a line shows where it will land.
final class BlockHandleView: NSView {
    weak var owner: AtlasTextView?
    /// The block it moves, as a range of the page's text.
    var block: Range<Int>?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let image = NSImageView(image: NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "Drag to move")!)
        image.contentTintColor = .tertiaryLabelColor
        image.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        image.frame = bounds
        image.autoresizingMask = [.width, .height]
        addSubview(image)
        toolTip = "Drag to move this block"
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) {
        NSCursor.closedHand.push()
        owner?.blockDrag(began: event)
    }

    override func mouseDragged(with event: NSEvent) { owner?.blockDrag(moved: event) }

    override func mouseUp(with event: NSEvent) {
        NSCursor.pop()
        owner?.blockDrag(ended: event)
    }
}

extension AtlasTextView {
    /// The blocks a handle moves, for the current text.
    var dragBlocks: [Range<Int>] { MarkdownEditing.dragBlocks(in: string, syntax: syntax) }

    /// Moves the block starting at `offset` to before the block starting at `target` (the end of
    /// the page when nil), as one undoable edit. False when it would stay where it is.
    @discardableResult
    public func moveBlock(at offset: Int, before target: Int?) -> Bool {
        guard let block = dragBlocks.first(where: { $0.lowerBound == offset }),
              let edit = MarkdownEditing.moveBlock(block, before: target, in: string) else { return false }
        AtlasLog.editor.info("Moved a block from \(offset) to \(target.map(String.init) ?? "the end")")
        perform(edit, actionName: "Move Block")
        return true
    }

    /// The rectangle, in this view, of the first line of the text at `offset`.
    func lineRect(at offset: Int) -> NSRect? {
        guard let layout = textLayoutManager, let content = textContentStorage,
              let location = content.location(content.documentRange.location, offsetBy: offset),
              let fragment = laidOut(layout, content, location) else { return nil }
        let frame = fragment.layoutFragmentFrame
        let line = fragment.textLineFragments.first?.typographicBounds ?? CGRect(origin: .zero, size: frame.size)
        return NSRect(x: frame.minX + textContainerOrigin.x, y: frame.minY + line.minY + textContainerOrigin.y,
                      width: frame.width, height: line.height)
    }

    /// The fragment at `location`, laid out with everything before it so its frame is where it
    /// really is (TextKit 2 lays out lazily).
    private func laidOut(_ layout: NSTextLayoutManager, _ content: NSTextContentStorage, _ location: NSTextLocation) -> NSTextLayoutFragment? {
        if let upTo = NSTextRange(location: content.documentRange.location, end: location) { layout.ensureLayout(for: upTo) }
        return layout.textLayoutFragment(for: location)
    }

    /// The bottom of the text at `offset`'s paragraph, in this view.
    func paragraphBottom(at offset: Int) -> CGFloat? {
        guard let layout = textLayoutManager, let content = textContentStorage,
              let location = content.location(content.documentRange.location, offsetBy: max(0, offset - 1)),
              let fragment = laidOut(layout, content, location) else { return nil }
        return fragment.layoutFragmentFrame.maxY + textContainerOrigin.y
    }

    /// Shows the handle beside the block under `point`, or hides it.
    func showBlockHandle(at point: NSPoint) {
        guard isEditable, blockDragState == nil else { return }
        let index = characterIndexForInsertion(at: NSPoint(x: max(point.x, textContainerOrigin.x + 10), y: point.y))
        guard let block = dragBlocks.first(where: { $0.lowerBound <= index && index <= $0.upperBound }),
              let line = lineRect(at: block.lowerBound) else {
            blockHandle.isHidden = true
            return
        }
        blockHandle.block = block
        let size: CGFloat = 16
        blockHandle.frame = NSRect(x: max(1, textContainerOrigin.x - size - 2), y: line.midY - size / 2, width: size, height: size)
        blockHandle.isHidden = false
    }

    // MARK: Dragging

    func blockDrag(began event: NSEvent) {
        guard let block = blockHandle.block else { return }
        blockDragState = BlockDragState(block: block, target: block.lowerBound)
        dropIndicator.isHidden = true
    }

    func blockDrag(moved event: NSEvent) {
        guard var state = blockDragState else { return }
        autoscroll(with: event)
        let point = convert(event.locationInWindow, from: nil)
        // Before the first block whose first line's middle is below the pointer; else the end.
        let blocks = dragBlocks
        var target: Int?? = .some(nil)
        var y: CGFloat = blocks.last.flatMap { paragraphBottom(at: $0.upperBound) } ?? 0
        for block in blocks {
            guard let line = lineRect(at: block.lowerBound) else { continue }
            if line.midY > point.y {
                target = .some(block.lowerBound)
                y = line.minY - 2
                break
            }
        }
        state.target = target ?? nil
        blockDragState = state
        dropIndicator.frame = NSRect(x: textContainerOrigin.x, y: y - 1, width: bounds.width - 2 * textContainerOrigin.x, height: 2)
        dropIndicator.isHidden = false
    }

    func blockDrag(ended event: NSEvent) {
        defer {
            blockDragState = nil
            dropIndicator.isHidden = true
            blockHandle.isHidden = true
        }
        guard let state = blockDragState, !dropIndicator.isHidden else { return }
        moveBlock(at: state.block.lowerBound, before: state.target)
    }
}

/// A block being dragged by its handle, and where it would land.
struct BlockDragState {
    var block: Range<Int>
    var target: Int?
}
#endif
