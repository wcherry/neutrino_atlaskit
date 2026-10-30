#if canImport(SwiftUI) && (canImport(AppKit) || canImport(UIKit))
import SwiftUI

/// The editor for SwiftUI, bound to a page's Markdown.
public struct AtlasEditorView {
    @Binding var text: String
    var mode: EditorMode
    var theme: EditorTheme
    var onOpenLink: ((LinkTarget) -> Void)?
    var linkCompletions: ((String) -> [LinkCompletion])?

    /// `onOpenLink` is called when a link is clicked or tapped; `linkCompletions` suggests pages
    /// while a `[[wiki link]]` is typed.
    public init(text: Binding<String>, mode: EditorMode = .livePreview, theme: EditorTheme = EditorTheme(),
                onOpenLink: ((LinkTarget) -> Void)? = nil, linkCompletions: ((String) -> [LinkCompletion])? = nil) {
        _text = text
        self.mode = mode
        self.theme = theme
        self.onOpenLink = onOpenLink
        self.linkCompletions = linkCompletions
    }

    public final class Coordinator {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
    }

    public func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    @MainActor
    private func update(_ view: AtlasTextView, _ coordinator: Coordinator) {
        coordinator.text = $text
        view.onOpenLink = onOpenLink
        view.linkCompletions = linkCompletions
        if view.mode != mode { view.mode = mode }
        if view.theme.fontSize != theme.fontSize { view.theme = theme }
    }
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
    }
}
#endif

#endif
