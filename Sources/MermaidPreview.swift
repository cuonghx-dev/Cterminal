import AppKit
import WebKit

// MARK: - Source extraction

/// Turns terminal text into Mermaid source. Terminal output (e.g. Claude Code's
/// rendered markdown) shows code blocks as indented text, sometimes with a bare
/// `mermaid` label or the original ``` fences, so both the selection path and the
/// screen-scan path normalize through here.
enum MermaidSourceExtractor {
    private static let diagramKeywords: [String] = [
        "flowchart", "graph", "sequenceDiagram", "classDiagram", "stateDiagram",
        "stateDiagram-v2", "erDiagram", "journey", "gantt", "pie", "quadrantChart",
        "requirementDiagram", "gitGraph", "C4Context", "C4Container", "C4Component",
        "C4Dynamic", "C4Deployment", "mindmap", "timeline", "zenuml", "sankey-beta",
        "xychart-beta", "block-beta", "packet-beta", "kanban", "architecture-beta",
    ]

    /// Normalize user-selected text: drop fences / `mermaid` labels and common indentation.
    static func normalize(_ text: String) -> String? {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        lines = lines.map { stripTrailingWhitespace($0) }

        while let first = lines.first, isBlank(first) || isFenceOrLabel(first) {
            lines.removeFirst()
        }
        while let last = lines.last, isBlank(last) || isClosingFence(last) {
            lines.removeLast()
        }
        guard !lines.isEmpty else { return nil }
        let source = dedent(lines).joined(separator: "\n")
        return source.isEmpty ? nil : source
    }

    /// Find the last Mermaid block in a chunk of screen text.
    static func lastBlock(in text: String) -> String? {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { stripTrailingWhitespace($0) }

        // Prefer an explicit label/fence; fall back to a bare diagram keyword line.
        var startIndex: Int?
        for index in stride(from: lines.count - 1, through: 0, by: -1) {
            let line = lines[index]
            if isFenceOrLabel(line) {
                startIndex = index + 1
                break
            }
            if startsWithDiagramKeyword(line) {
                startIndex = index
                break
            }
        }
        guard var start = startIndex else { return nil }
        while start < lines.count, isBlank(lines[start]) { start += 1 }
        guard start < lines.count, startsWithDiagramKeyword(lines[start]) else { return nil }

        let baseIndent = indentation(of: lines[start])
        var collected: [String] = [lines[start]]
        var blankRun = 0
        var index = start + 1
        while index < lines.count {
            let line = lines[index]
            if isClosingFence(line) { break }
            if isBlank(line) {
                blankRun += 1
                if blankRun >= 2 { break }
                collected.append(line)
                index += 1
                continue
            }
            // Text that dedents past the block's first line belongs to the
            // surrounding output, not the diagram. After a blank line, body
            // lines must stay indented under the header, otherwise the blank
            // ended the code block and prose resumed at the same margin.
            let indent = indentation(of: line)
            if indent < baseIndent || (blankRun > 0 && indent <= baseIndent) { break }
            blankRun = 0
            collected.append(line)
            index += 1
        }
        while let last = collected.last, isBlank(last) { collected.removeLast() }
        return normalize(collected.joined(separator: "\n"))
    }

    // MARK: Helpers

    private static func isBlank(_ line: String) -> Bool {
        line.allSatisfy { $0 == " " || $0 == "\t" || $0 == "\u{00A0}" }
    }

    private static func trimmed(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespaces)
    }

    private static func isFenceOrLabel(_ line: String) -> Bool {
        let t = trimmed(line).lowercased()
        return t == "mermaid" || t == "```mermaid" || t == "``` mermaid" || t == "~~~mermaid"
    }

    private static func isClosingFence(_ line: String) -> Bool {
        let t = trimmed(line)
        return t == "```" || t == "~~~"
    }

    private static func startsWithDiagramKeyword(_ line: String) -> Bool {
        let t = trimmed(line)
        guard let word = t.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == ";" }).first else {
            return false
        }
        if t.hasPrefix("%%{") || t.hasPrefix("---") { return false }
        return diagramKeywords.contains(String(word))
    }

    private static func indentation(of line: String) -> Int {
        var count = 0
        for ch in line {
            if ch == " " || ch == "\u{00A0}" { count += 1 } else if ch == "\t" { count += 4 } else { break }
        }
        return count
    }

    private static func stripTrailingWhitespace(_ line: String) -> String {
        var s = Substring(line)
        while let last = s.last, last == " " || last == "\t" || last == "\u{00A0}" { s = s.dropLast() }
        return String(s)
    }

    private static func dedent(_ lines: [String]) -> [String] {
        let indents = lines.filter { !isBlank($0) }.map { indentation(of: $0) }
        guard let minIndent = indents.min(), minIndent > 0 else { return lines }
        return lines.map { line in
            var removed = 0
            var s = Substring(line)
            while removed < minIndent, let first = s.first, first == " " || first == "\t" || first == "\u{00A0}" {
                removed += first == "\t" ? 4 : 1
                s = s.dropFirst()
            }
            return String(s)
        }
    }
}

// MARK: - Terminal text access

extension TerminalSurface {
    /// Plain text of the current selection, if any.
    func selectedText() -> String? {
        guard let surface, ghostty_surface_has_selection(surface) else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let ptr = text.text, text.text_len > 0 else { return nil }
        return String(decoding: Data(bytes: ptr, count: Int(text.text_len)), as: UTF8.self)
    }

    /// Plain text of everything currently visible in the viewport.
    func viewportText() -> String? {
        guard let surface else { return nil }
        var text = ghostty_text_s()
        let sel = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        guard ghostty_surface_read_text(surface, sel, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let ptr = text.text, text.text_len > 0 else { return nil }
        return String(decoding: Data(bytes: ptr, count: Int(text.text_len)), as: UTF8.self)
    }

    /// Mermaid source from the selection, or else the last block visible on screen.
    func mermaidSource() -> String? {
        if let selection = selectedText(), let source = MermaidSourceExtractor.normalize(selection) {
            return source
        }
        if let screen = viewportText() {
            return MermaidSourceExtractor.lastBlock(in: screen)
        }
        return nil
    }
}

// MARK: - Preview window

/// One reusable window that renders Mermaid with a bundled, offline mermaid.js.
final class MermaidPreviewController: NSWindowController, WKNavigationDelegate, WKScriptMessageHandler {
    static let shared = MermaidPreviewController()

    private let webView: WKWebView
    private var pendingSource: String?
    private var pageLoaded = false

    private static let mermaidScript: String? = {
        guard let url = Bundle.main.url(forResource: "mermaid.min", withExtension: "js", subdirectory: "mermaid")
            ?? Bundle.main.url(forResource: "mermaid.min", withExtension: "js") else {
            NSLog("Mermaid: mermaid.min.js missing from bundle")
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }()

    private init() {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        if let script = Self.mermaidScript {
            controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        config.userContentController = controller

        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 640), configuration: config)
        webView.allowsMagnification = true
        webView.setValue(false, forKey: "drawsBackground")

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false)
        window.title = "Mermaid Preview"
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.setFrameAutosaveName("cter.mermaidPreview")
        window.center()

        super.init(window: window)
        webView.navigationDelegate = self
        controller.add(WeakScriptMessageHandler(self), name: "cter")
        webView.loadHTMLString(Self.pageHTML, baseURL: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(source: String) {
        pendingSource = source
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        if pageLoaded { flush() }
    }

    /// Render whatever Mermaid the focused terminal offers, or beep.
    static func renderFromFocusedSurface(_ surface: TerminalSurface?) {
        guard let source = surface?.mermaidSource() else {
            NSSound.beep()
            NSLog("Mermaid: no mermaid source in selection or viewport")
            return
        }
        shared.show(source: source)
    }

    private func flush() {
        guard let source = pendingSource else { return }
        pendingSource = nil
        guard let data = try? JSONSerialization.data(withJSONObject: [source]),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.cterRender(\(json)[0])")
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoaded = true
        flush()
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // Only the initial in-memory page; terminal text is untrusted, never navigate.
        decisionHandler(navigationAction.navigationType == .other && !pageLoaded ? .allow : .cancel)
    }

    // MARK: WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
        let payload = body["text"] as? String ?? ""
        switch action {
        case "copySVG", "copySource":
            let pb = NSPasteboard.general
            pb.clearContents()
            if action == "copySVG", let data = payload.data(using: .utf8) {
                pb.setData(data, forType: NSPasteboard.PasteboardType("public.svg-image"))
            }
            pb.setString(payload, forType: .string)
        default:
            break
        }
    }

    // MARK: Page

    private static let pageHTML = #"""
    <!doctype html>
    <html>
    <head>
    <meta charset="utf-8">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval'; style-src 'unsafe-inline'; img-src data:; font-src data:">
    <style>
      :root { color-scheme: light dark; --bg: #ffffff; --fg: #1d1d1f; --muted: #6e6e73; --bar: rgba(0,0,0,0.04); --border: rgba(0,0,0,0.12); --err: #c62828; }
      @media (prefers-color-scheme: dark) {
        :root { --bg: #1e1e1e; --fg: #e8e8e8; --muted: #a0a0a5; --bar: rgba(255,255,255,0.05); --border: rgba(255,255,255,0.14); --err: #ff6b6b; }
      }
      html, body { margin: 0; height: 100%; background: var(--bg); color: var(--fg); font: 13px -apple-system, system-ui, sans-serif; }
      #bar { position: sticky; top: 0; display: flex; gap: 6px; padding: 8px 10px; background: var(--bar); border-bottom: 1px solid var(--border); backdrop-filter: blur(8px); z-index: 1; }
      #bar button { font: inherit; padding: 3px 10px; border-radius: 6px; border: 1px solid var(--border); background: var(--bg); color: var(--fg); cursor: pointer; }
      #bar button:active { opacity: 0.7; }
      #status { margin-left: auto; color: var(--muted); align-self: center; }
      #diagram { padding: 24px; display: flex; justify-content: center; }
      #diagram svg { max-width: 100%; height: auto; }
      #error { display: none; padding: 16px 24px; color: var(--err); white-space: pre-wrap; font-family: ui-monospace, Menlo, monospace; }
      #source { display: none; margin: 0 24px 24px; padding: 12px; border: 1px solid var(--border); border-radius: 8px; white-space: pre; overflow: auto; font-family: ui-monospace, Menlo, monospace; color: var(--muted); }
    </style>
    </head>
    <body>
    <div id="bar">
      <button id="copySvg">Copy SVG</button>
      <button id="copySrc">Copy Source</button>
      <button id="toggleSrc">Show Source</button>
      <span id="status"></span>
    </div>
    <div id="error"></div>
    <div id="diagram"></div>
    <pre id="source"></pre>
    <script>
      (function () {
        const post = (action, text) => window.webkit.messageHandlers.cter.postMessage({ action, text: text || "" });
        const $ = (id) => document.getElementById(id);
        let current = "";
        let seq = 0;
        const dark = () => window.matchMedia("(prefers-color-scheme: dark)").matches;

        function status(text) {
          $("status").textContent = text;
          if (text) setTimeout(() => { if ($("status").textContent === text) $("status").textContent = ""; }, 1500);
        }

        async function render(source) {
          current = source;
          $("source").textContent = source;
          $("error").style.display = "none";
          if (typeof mermaid === "undefined") {
            $("error").textContent = "mermaid.js failed to load.";
            $("error").style.display = "block";
            return;
          }
          mermaid.initialize({ startOnLoad: false, securityLevel: "strict", theme: dark() ? "dark" : "default" });
          const id = "cter-mermaid-" + (++seq);
          try {
            const { svg } = await mermaid.render(id, source);
            $("diagram").innerHTML = svg;
          } catch (e) {
            document.getElementById("d" + id)?.remove();
            $("diagram").innerHTML = "";
            $("error").textContent = String((e && e.message) || e);
            $("error").style.display = "block";
            $("source").style.display = "block";
            $("toggleSrc").textContent = "Hide Source";
          }
        }

        window.cterRender = render;
        $("copySvg").onclick = () => {
          const svg = document.querySelector("#diagram svg");
          if (!svg) return;
          post("copySVG", new XMLSerializer().serializeToString(svg));
          status("SVG copied");
        };
        $("copySrc").onclick = () => { post("copySource", current); status("Source copied"); };
        $("toggleSrc").onclick = () => {
          const el = $("source");
          const show = el.style.display !== "block";
          el.style.display = show ? "block" : "none";
          $("toggleSrc").textContent = show ? "Hide Source" : "Show Source";
        };
        window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => { if (current) render(current); });
      })();
    </script>
    </body>
    </html>
    """#
}

/// Breaks the WKUserContentController -> handler retain cycle.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
