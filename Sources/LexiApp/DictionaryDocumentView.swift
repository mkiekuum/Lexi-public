import AppKit
import SwiftUI
import WebKit
import LexiCore

struct DictionaryDocumentView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var contentHeight: CGFloat = 40
    @Environment(\.lexiFontFamily) private var fontFamily
    @Environment(\.lexiFontSizeOffset) private var fontSizeOffset

    let document: DictionaryStructuredDocument
    let entryTitle: String
    let entryFullTitle: String
    let showsDocumentHeading: Bool
    let highlightSourceID: String?
    let onReference: (String) -> Void

    var body: some View {
        DictionaryWebView(
            html: html,
            contentHeight: $contentHeight,
            onReference: onReference
        )
        .frame(height: max(contentHeight, 40))
    }

    var html: String {
        let dark = colorScheme == .dark
        let foreground = dark ? "#e5e7eb" : "#252a30"
        let secondary = dark ? "#a7adb5" : "#67707a"
        let background = "transparent"
        let fontStack = LexiFontSupport.cssFamily(fontFamily)
        let accent = dark ? "#9bc5a0" : "#547e5d"
        let marker = dark ? "#35483d" : "#e0ebe1"
        let markerText = dark ? "#dce8de" : "#304c37"
        let baseHeading = document.heading.joined()
        let hasRuby = document.headingSegments.contains { $0.kind == "ruby" && $0.reading != nil }
        let headingKey = titleKey(baseHeading)
        let showHeading = showsDocumentHeading && ((
            headingKey != titleKey(entryTitle) && headingKey != titleKey(entryFullTitle)
        ) || hasRuby)
        var content = ""
        if showHeading {
            let heading = document.headingSegments.isEmpty
                ? escape(document.reading)
                : render(document.headingSegments)
            if !heading.isEmpty { content += "<div class=\"heading\">\(heading)</div>" }
        }
        if showsDocumentHeading && !document.writtenForms.isEmpty {
            let forms = document.writtenForms.filter { form in
                !(showHeading && document.headingSegments.contains { ($0.styles ?? []).contains("heading-written") }) && titleKey(form) != titleKey(entryTitle) && titleKey(form) != titleKey(entryFullTitle)
            }
            if !forms.isEmpty {
                content += "<div class=\"written\">\(forms.map(escape).joined(separator: "・"))</div>"
            }
        }
        if !document.accent.isEmpty {
            content += "<div class=\"accent\">\(escape(document.accent))</div>"
        }
        for section in document.sections {
            content += render(section, highlightSourceID: verifiedHighlightSourceID)
        }
        return """
        <!doctype html>
        <html lang="ja">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
        <script>
        document.addEventListener('toggle', function(event) {
          if (event.target && event.target.tagName === 'DETAILS') {
            if (event.target.open && !event.target.dataset.loaded) {
              const template = event.target.querySelector('template.related-template');
              const content = event.target.querySelector('.related-content');
              if (template && content) {
                content.innerHTML = template.innerHTML;
                template.remove();
                event.target.dataset.loaded = 'true';
              }
            }
            requestAnimationFrame(function() {
              window.webkit.messageHandlers.contentHeight.postMessage(
                Math.ceil(document.body.getBoundingClientRect().height)
              );
            });
          }
        }, true);
        </script>
        <style>
        :root { color-scheme: \(dark ? "dark" : "light"); }
        html, body { margin: 0; padding: 0; background: \(background); color: \(foreground); }
        body { font: \(15 + fontSizeOffset)px/1.95 \(fontStack); overflow-wrap: anywhere; }
        .heading { font-size: \(15 + fontSizeOffset)px; font-weight: 500; margin: 0 0 3px; }
        .heading-reading { font-size: 1.05em; }
        .heading-written { color: \(secondary); font-size: .82em; }
        .written { color: \(secondary); font-size: \(13 + fontSizeOffset)px; }
        .accent { color: \(secondary); font-size: \(12 + fontSizeOffset)px; }
        .section { display: grid; grid-template-columns: 1.6em minmax(0, 1fr); column-gap: .8em; margin: 12px 0; }
        .section.unnumbered { grid-template-columns: minmax(0, 1fr); column-gap: 0; }
        .unnumbered .number { display: none; }
        .unnumbered .section-text { grid-column: 1; }
        .number { color: \(accent); font-weight: 600; text-align: right; }
        .label { color: \(secondary); font-size: \(12 + fontSizeOffset)px; grid-column: 2; }
        .section-text { grid-column: 2; }
        .section-text { min-width: 0; overflow-wrap: anywhere; }
        .example { color: \(secondary); }
        .selected-example { color: \(markerText); font-weight: 500; background: \(marker); border-radius: 3px; padding: .05em .15em; box-decoration-break: clone; -webkit-box-decoration-break: clone; }
        .selected-example .example, .selected-example a, .selected-example rt { color: inherit; }
        .annotation { color: \(secondary); font-size: .72em; }
        .image-caption { color: \(secondary); font-size: \(12 + fontSizeOffset)px; }
        a { color: \(accent); text-decoration: none; }
        ruby { ruby-position: over; ruby-align: center; white-space: nowrap; }
        rt { color: \(secondary); font-size: .64em; line-height: 1.1; font-weight: normal; }
        .grammar { color: \(foreground); font-size: .96em; white-space: nowrap; }
        .grammar-sahen { font-size: .66em; vertical-align: super; line-height: 0; font-weight: 600; }
        .grammar-end { margin-right: .48em; }
        .related-disclosure { margin: 8px 0; }
        .related-disclosure summary { cursor: pointer; color: \(secondary); font-size: \(12 + fontSizeOffset)px; font-weight: 600; list-style: none; user-select: none; }
        .related-disclosure summary::-webkit-details-marker { display: none; }
        .related-disclosure summary::before { content: "›"; display: inline-block; width: 1.2em; color: \(accent); transition: transform .12s ease; }
        .related-disclosure[open] summary::before { transform: rotate(90deg); }
        .related-content { display: flex; flex-wrap: wrap; column-gap: .12em; row-gap: .18em; line-height: 1.8; padding: 3px 0 0 1.2em; }
        .related-item { white-space: normal; }
        .related-separator { color: \(secondary); }
        </style>
        </head>
        <body>\(content)</body>
        </html>
        """
    }

    private var verifiedHighlightSourceID: String? {
        guard let highlightSourceID,
              DictionarySourceIdentity.referenceCount(in: document, sourceKey: highlightSourceID) == 1
        else { return nil }
        return highlightSourceID
    }

    private func render(_ section: DictionarySection, highlightSourceID: String?) -> String {
        if section.kind == "related" {
            return renderRelatedSection(section)
        }
        let number = section.number.isEmpty ? (section.kind == "example" ? "例" : "") : section.number
        let label = section.label.isEmpty ? "" : "<div class=\"label\">\(escape(section.label))</div>"
        let text = render(section.segments, fallback: section.text, highlightSourceID: highlightSourceID)
        let indentation = Double(max(0, min(section.depth ?? 0, 6))) * 1.2
        let unnumbered = number.isEmpty && section.label.isEmpty ? " unnumbered" : ""
        return """
        <div class="section\(unnumbered)" style="margin-left:\(indentation)em">
          <div class="number">\(escape(number))</div>
          \(label)
          <div class="section-text">\(text)</div>
        </div>
        """
    }

    private func renderRelatedSection(_ section: DictionarySection) -> String {
        let label = section.label.isEmpty ? "類語・関連語" : section.label
        let count = relatedItemCount(section)
        let content = renderRelated(section.segments, fallback: section.text)
        return """
        <details class="related-disclosure">
          <summary>\(escape(label))（\(count)）</summary>
          <template class="related-template">\(content)</template>
          <div class="related-content"></div>
        </details>
        """
    }

    private func render(
        _ segments: [DictionarySegment],
        fallback: String = "",
        highlightSourceID: String? = nil
    ) -> String {
        guard !segments.isEmpty else { return escape(fallback) }
        let segments = (Int(document.parserVersion) ?? 0) < 7 ? DictionaryDisplayRepair.repair(segments) : segments
        var output = ""
        var marked = false
        for (index, segment) in segments.enumerated() {
            let isTarget = highlightSourceID.flatMap { key in segment.sourceID.map { DictionarySourceIdentity.matches($0, key) } } ?? false
            if isTarget && !marked { output += "<mark class=\"selected-example\">"; marked = true }
            if !isTarget && marked { output += "</mark>"; marked = false }
            let text = escape(segment.text)
            var rendered: String
            switch segment.kind {
            case "ruby":
                if let reading = segment.reading, !reading.isEmpty {
                    let ruby = "<ruby>\(text)<rt>\(escape(reading))</rt></ruby>"
                    rendered = internalLink(segment.target, title: segment.text, content: ruby)
                } else { rendered = text }
            case "grammar":
                let end = index + 1 < segments.count && segments[index + 1].kind != "grammar" ? " grammar-end" : ""
                let raised = ["スル", "する", "タリ", "ナリ"].contains(segment.text) ? " grammar-sahen" : ""
                rendered = "<span class=\"grammar\(raised)\(end)\">\(text)</span>"
            case "reading":
                rendered = "<span class=\"written\">\(text)</span>"
            case "example":
                rendered = "<span class=\"example\">\(text)</span>"
            case "annotation":
                rendered = "<sup class=\"annotation\" title=\"常用外音訓\">\(text)</sup>"
            case "break":
                rendered = "<br>"
            case "image":
                rendered = "<span class=\"image-caption\">\(text)</span>"
            case "link":
                rendered = internalLink(segment.target, title: segment.text, content: text)
            default:
                rendered = text
            }
            for style in segment.styles ?? [] {
                switch style {
                case "strong": rendered = "<strong>\(rendered)</strong>"
                case "emphasis": rendered = "<em>\(rendered)</em>"
                case "small": rendered = "<small>\(rendered)</small>"
                case "superscript": rendered = "<sup>\(rendered)</sup>"
                case "subscript": rendered = "<sub>\(rendered)</sub>"
                case "underline": rendered = "<u>\(rendered)</u>"
                case "heading-reading": rendered = "<span class=\"heading-reading\">\(rendered)</span>"
                case "heading-written": rendered = "<span class=\"heading-written\">\(rendered)</span>"
                default: break
                }
            }
            output += rendered
        }
        if marked { output += "</mark>" }
        return output
    }

    private func renderRelated(_ segments: [DictionarySegment], fallback: String) -> String {
        guard !segments.isEmpty else { return renderRelatedText(fallback) }
        return ((Int(document.parserVersion) ?? 0) < 7 ? DictionaryDisplayRepair.repair(segments) : segments).map { segment in
            guard segment.kind == "text", segment.target == nil,
                  (segment.styles ?? []).isEmpty,
                  !segment.text.isEmpty else {
                return render([segment])
            }
            return renderRelatedText(segment.text)
        }.joined()
    }

    private func renderRelatedText(_ text: String) -> String {
        let terms = text.components(separatedBy: "・")
        guard !terms.isEmpty else { return escape(text) }
        return terms.enumerated().map { index, term in
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            let linked: String
            if trimmed.rangeOfCharacter(from: .letters.union(.decimalDigits)) != nil,
               let range = term.range(of: trimmed) {
                let prefix = String(term[..<range.lowerBound])
                let suffix = String(term[range.upperBound...])
                linked = escape(prefix) + searchLink(title: trimmed, content: escape(trimmed)) + escape(suffix)
            } else {
                linked = escape(term)
            }
            let separator = index == terms.count - 1 ? "" : "・"
            return "<span class=\"related-item\">\(linked)\(separator)</span>"
        }
        .joined()
    }

    private func relatedItemCount(_ section: DictionarySection) -> Int {
        let text = section.text.isEmpty ? section.segments.map(\.text).joined() : section.text
        let separators = CharacterSet(charactersIn: "・、，,/／\n\r")
        let items = text.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return max(items.count, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : 1)
    }

    private func internalLink(_ target: String?, title: String, content: String) -> String {
        guard let target,
              target.range(of: "^[0-9]{1,6}(?:-[0-9A-Fa-f]{4})?$", options: .regularExpression) != nil
        else { return content }
        return searchLink(title: title, content: content)
    }

    private func searchLink(title: String, content: String) -> String {
        var components = URLComponents()
        components.scheme = "lexi"
        components.host = "search"
        components.queryItems = [URLQueryItem(name: "text", value: title)]
        guard let url = components.url else { return content }
        return "<a href=\"\(escape(url.absoluteString))\">\(content)</a>"
    }

    private func escape(_ value: String) -> String {
        DictionaryDisplayText.clean(value)
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private func titleKey(_ value: String) -> String {
        let withoutMarkers = DictionaryDisplayText.clean(value)
            .replacingOccurrences(of: "・", with: "")
            .replacingOccurrences(of: "／", with: "")
            .replacingOccurrences(of: "┊", with: "")
            .replacingOccurrences(of: "▽", with: "")
        return String(withoutMarkers
            .precomposedStringWithCompatibilityMapping
            .filter { !$0.isPunctuation && !$0.isWhitespace }
        )
    }
}

private struct DictionaryWebView: NSViewRepresentable {
    let html: String
    @Binding var contentHeight: CGFloat
    let onReference: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onReference: onReference, contentHeight: $contentHeight)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(context.coordinator, name: "contentHeight")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.underPageBackgroundColor = .clear
        context.coordinator.load(html, in: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onReference = onReference
        context.coordinator.contentHeight = $contentHeight
        context.coordinator.update(html, in: webView)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "contentHeight")
        webView.navigationDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var onReference: (String) -> Void
        var contentHeight: Binding<CGFloat>
        private var loadedHTML = ""

        init(onReference: @escaping (String) -> Void, contentHeight: Binding<CGFloat>) {
            self.onReference = onReference
            self.contentHeight = contentHeight
        }

        func load(_ html: String, in webView: WKWebView) {
            guard loadedHTML != html else { return }
            loadedHTML = html
            contentHeight.wrappedValue = 40
            webView.loadHTMLString(html, baseURL: nil)
        }

        func update(_ html: String, in webView: WKWebView) {
            if loadedHTML != html {
                load(html, in: webView)
            } else {
                measure(in: webView)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            measure(in: webView)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "contentHeight",
                  let height = message.body as? NSNumber else { return }
            DispatchQueue.main.async {
                self.contentHeight.wrappedValue = CGFloat(height.doubleValue + 2)
            }
        }

        private func measure(in webView: WKWebView) {
            webView.evaluateJavaScript("document.body.getBoundingClientRect().height") { [weak self] value, _ in
                guard let height = value as? NSNumber else { return }
                DispatchQueue.main.async {
                    self?.contentHeight.wrappedValue = CGFloat(height.doubleValue + 2)
                }
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            if url.scheme == "about" {
                decisionHandler(.allow)
                return
            }
            guard navigationAction.navigationType == .linkActivated,
                  url.scheme == "lexi", url.host == "search",
                  let title = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "text" })?.value,
                  !title.isEmpty else {
                decisionHandler(.cancel)
                return
            }
            onReference(title)
            decisionHandler(.cancel)
        }
    }
}
