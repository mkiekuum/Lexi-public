import AppKit
import SwiftUI

/// All insertion paths use plain strings; toolbar paste never depends on the key window's responder.
final class PlainNoteTextView: NSTextView {
    var focusWhenAttached = false
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard focusWhenAttached, let window else { return }
        focusWhenAttached = false
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window else { return }
            window.makeFirstResponder(self)
        }
    }
    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }
    override func pasteAsRichText(_ sender: Any?) { pasteAsPlainText(sender) }
    override func pasteAsPlainText(_ sender: Any?) {
        paste(from: .general)
    }
    func paste(from board: NSPasteboard) {
        let plain = board.string(forType: .string)
            ?? board.data(forType: .rtf).flatMap {
                try? NSAttributedString(data: $0, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil).string
            }
            ?? board.data(forType: .html).flatMap {
                try? NSAttributedString(data: $0, options: [.documentType: NSAttributedString.DocumentType.html], documentAttributes: nil).string
            }
        guard let plain else { return }
        insertText(plain, replacementRange: selectedRange())
    }
}

@MainActor final class PlainNoteController: ObservableObject {
    weak var editor: PlainNoteTextView?
    func paste() {
        guard let editor else { return }
        editor.window?.makeFirstResponder(editor)
        editor.pasteAsPlainText(nil)
    }
}

struct PlainNoteEditor: NSViewRepresentable {
    @Environment(\.lexiFontFamily) private var fontFamily
    @Environment(\.lexiFontSizeOffset) private var fontSizeOffset
    @Binding var text: String
    let controller: PlainNoteController
    let focusChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let editor = PlainNoteTextView(frame: .zero)
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.font = LexiFontSupport.nativeFont(fontFamily, size: LexiTypography.body + CGFloat(fontSizeOffset))
        editor.textColor = .labelColor
        editor.drawsBackground = false
        editor.textContainerInset = NSSize(width: 9, height: 10)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.string = text
        editor.delegate = context.coordinator
        editor.setAccessibilityIdentifier("noteEditor")
        editor.setAccessibilityLabel("ノートを編集")
        editor.focusWhenAttached = true
        scroll.documentView = editor
        controller.editor = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? PlainNoteTextView else { return }
        let desiredFont = LexiFontSupport.nativeFont(fontFamily, size: LexiTypography.body + CGFloat(fontSizeOffset))
        if editor.font != desiredFont { editor.font = desiredFont }
        if editor.string != text {
            let selection = editor.selectedRange()
            editor.string = text
            let length = (text as NSString).length
            let start = min(selection.location, length)
            editor.setSelectedRange(NSRange(location: start, length: min(selection.length, length - start)))
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlainNoteEditor
        init(_ parent: PlainNoteEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            if let editor = notification.object as? NSTextView { parent.text = editor.string }
        }
        func textDidBeginEditing(_ notification: Notification) { parent.focusChanged(true) }
        func textDidEndEditing(_ notification: Notification) { parent.focusChanged(false) }
    }
}
