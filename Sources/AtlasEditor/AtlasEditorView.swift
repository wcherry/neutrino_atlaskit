#if canImport(SwiftUI) && (canImport(AppKit) || canImport(UIKit))
import SwiftUI

/// The editor for SwiftUI, bound to a page's Markdown.
public struct AtlasEditorView {
    @Binding var text: String
    var mode: EditorMode
    var theme: EditorTheme
    var onOpenLink: ((LinkTarget) -> Void)?
    var linkCompletions: ((LinkCompletionContext) -> [LinkCompletion])?
    var anchor: EditorAnchor?
    var slashCommands: (() -> [SlashCommand])?
    var imageData: ((ImageSource) -> Data?)?
    var imagesVersion: Int
    var importImages: (([ImageImport]) -> [String])?
    var insertion: ImageInsertion?

    /// `onOpenLink` is called when a link is clicked or tapped; `linkCompletions` suggests pages,
    /// and then headings, while a `[[wiki link]]` is typed. A new `anchor` is shown once, when
    /// it's set: set it with the text of the page it's on. `slashCommands` is the `/` menu,
    /// `SlashCommand.builtIn()` when nil. `imageData` gives the bytes of the images Live Preview
    /// shows; they're decoded once, and again when `imagesVersion` changes, so change it when the
    /// files they come from do. `importImages` saves images pasted or dropped, and returns the
    /// target to embed each by; a new `insertion` adds images at the cursor, once.
    public init(text: Binding<String>, mode: EditorMode = .livePreview, theme: EditorTheme = EditorTheme(),
                onOpenLink: ((LinkTarget) -> Void)? = nil, linkCompletions: ((LinkCompletionContext) -> [LinkCompletion])? = nil,
                anchor: EditorAnchor? = nil, slashCommands: (() -> [SlashCommand])? = nil,
                imageData: ((ImageSource) -> Data?)? = nil, imagesVersion: Int = 0,
                importImages: (([ImageImport]) -> [String])? = nil, insertion: ImageInsertion? = nil) {
        _text = text
        self.mode = mode
        self.theme = theme
        self.onOpenLink = onOpenLink
        self.linkCompletions = linkCompletions
        self.anchor = anchor
        self.slashCommands = slashCommands
        self.imageData = imageData
        self.imagesVersion = imagesVersion
        self.importImages = importImages
        self.insertion = insertion
    }

    public final class Coordinator {
        var text: Binding<String>
        var revealed: UUID?
        var imagesVersion: Int?
        var inserted: UUID?
        init(text: Binding<String>) { self.text = text }
    }

    public func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    @MainActor
    private func update(_ view: AtlasTextView, _ coordinator: Coordinator) {
        coordinator.text = $text
        view.onOpenLink = onOpenLink
        view.linkCompletions = linkCompletions
        view.slashCommands = slashCommands ?? { SlashCommand.builtIn() }
        if view.mode != mode { view.mode = mode }
        if view.theme.fontSize != theme.fontSize { view.theme = theme }
        if coordinator.imagesVersion != imagesVersion || (view.imageData == nil) != (imageData == nil) {
            coordinator.imagesVersion = imagesVersion
            view.imageData = imageData
        }
        view.importImages = importImages
        if let insertion, insertion.id != coordinator.inserted {
            coordinator.inserted = insertion.id
            DispatchQueue.main.async { view.insertImages(insertion.images) }
        }
    }

    /// Shows a new anchor, after the text is in place and laid out.
    @MainActor
    private func reveal(_ view: AtlasTextView, _ coordinator: Coordinator) {
        guard let anchor, anchor.id != coordinator.revealed else { return }
        coordinator.revealed = anchor.id
        DispatchQueue.main.async { view.reveal(anchor) }
    }
}

/// Images for the editor to add at the cursor, from a picker: each new one is inserted once.
public struct ImageInsertion: Equatable, Sendable {
    public let id = UUID()
    public var images: [ImageImport]

    public init(images: [ImageImport]) { self.images = images }
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
extension AtlasEditorView: NSViewRepresentable {
    public func makeNSView(context: Context) -> NSScrollView {
        let (scroll, view) = AtlasTextView.scrollable()
        view.mode = mode
        view.theme = theme
        view.string = text
        view.onTextChange = { [coordinator = context.coordinator] new in
            if coordinator.text.wrappedValue != new { coordinator.text.wrappedValue = new }
        }
        return scroll
    }

    public func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? AtlasTextView else { return }
        update(view, context.coordinator)
        if view.string != text { view.string = text }
        reveal(view, context.coordinator)
    }
}
#else
extension AtlasEditorView: UIViewRepresentable {
    public func makeUIView(context: Context) -> AtlasTextView {
        let view = AtlasTextView()
        view.mode = mode
        view.theme = theme
        view.text = text
        view.onTextChange = { [coordinator = context.coordinator] new in
            if coordinator.text.wrappedValue != new { coordinator.text.wrappedValue = new }
        }
        return view
    }

    public func updateUIView(_ view: AtlasTextView, context: Context) {
        update(view, context.coordinator)
        if view.text != text { view.text = text }
        reveal(view, context.coordinator)
    }
}
#endif

#endif
