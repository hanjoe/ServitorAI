import AppKit

/// Result of rendering markdown: the styled text plus the raw text of every
/// fenced code block (indexed by the `servitor://copy-code/<item>/<n>` links).
struct RenderedMarkdown {
    let text: NSAttributedString
    let codeBlocks: [String]
}

/// Which URLs model-authored text may turn into clickable links. Anything
/// else (file://, smb://, x-apple.*://, mailto:, and the app-internal
/// servitor:// actions) stays plain text, so a prompt-injected answer can't
/// make a single click launch an app or trigger an internal action.
enum LinkPolicy {
    static func isOpenable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return url.host?.isEmpty == false
    }
}

/// A compact markdown → NSAttributedString renderer tuned for chat answers:
/// headings, bold/italic/strike, inline + fenced code, lists, quotes, rules,
/// tables, and highlighted (clickable) links including bare URLs.
enum Markdown {
    private static let T = ServitorTheme.self

    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    // MARK: - Public API

    static func render(_ source: String, item: Int) -> RenderedMarkdown {
        let msgIndex = item
        let out = NSMutableAttributedString()
        var codeBlocks: [String] = []
        var paragraph: [String] = []
        var inFence = false
        var fenceMarker = "```"
        var fenceLang = ""
        var fenceLines: [String] = []
        var table: [String] = []

        func nextCodeLink(for code: String) -> URL {
            let idx = codeBlocks.count
            codeBlocks.append(code)
            return URL(string: "servitor://copy-code/\(msgIndex)/\(idx)")!
        }

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let content = inline(paragraph.joined(separator: "\n"), font: T.bodyFont, color: T.text, codeLink: nextCodeLink)
            appendBlock(content, to: out, style: para(spacingAfter: 10))
            paragraph.removeAll()
        }

        func flushTable() {
            guard !table.isEmpty else { return }
            appendBlock(renderTable(table), to: out, style: para(spacingAfter: 10, lineBreak: .byClipping))
            table.removeAll()
        }

        func emitCode() {
            let code = fenceLines.joined(separator: "\n")
            let idx = codeBlocks.count
            codeBlocks.append(code)
            appendCodeBlock(code: code, lang: fenceLang, item: item, index: idx, to: out)
            fenceLines.removeAll()
            fenceLang = ""
        }

        for rawLine in source.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            // Fenced code
            if inFence {
                if trimmed.hasPrefix(fenceMarker) {
                    inFence = false
                    emitCode()
                } else {
                    fenceLines.append(rawLine)
                }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph(); flushTable()
                fenceMarker = String(trimmed.prefix(3))
                fenceLang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                inFence = true
                continue
            }

            // Table rows
            if trimmed.hasPrefix("|") && trimmed.dropFirst().contains("|") {
                flushParagraph()
                table.append(trimmed)
                continue
            } else {
                flushTable()
            }

            if trimmed.isEmpty { flushParagraph(); continue }

            // Heading
            if let h = headingLevel(trimmed) {
                flushParagraph()
                let sizes: [CGFloat] = [15, 13, 12, 11, 10, 10]
                let font = T.pixel(sizes[min(h.level, 6) - 1])
                let content = inline(h.text, font: font, color: T.bone, codeLink: nextCodeLink)
                appendBlock(content, to: out, style: para(spacingBefore: 6, spacingAfter: 10, lineSpacing: 6))
                continue
            }

            // Horizontal rule
            if trimmed.range(of: #"^(-{3,}|\*{3,}|_{3,})$"#, options: .regularExpression) != nil {
                flushParagraph()
                let rule = NSAttributedString(string: String(repeating: "─", count: 40), attributes: [
                    .font: T.body(T.bodySize), .foregroundColor: T.surface1,
                ])
                appendBlock(rule, to: out, style: para(spacingAfter: 8))
                continue
            }

            // List item
            if let item = listItem(rawLine) {
                flushParagraph()
                let base = CGFloat(12 + item.level * 26)
                let style = para(first: base, head: base + 26, spacingAfter: 4)
                style.tabStops = [NSTextTab(textAlignment: .left, location: base + 26)]
                let line = NSMutableAttributedString(string: item.marker + "\t", attributes: [
                    .font: T.bodyFont, .foregroundColor: T.brass,
                ])
                line.append(inline(item.text, font: T.bodyFont, color: T.text, codeLink: nextCodeLink))
                appendBlock(line, to: out, style: style)
                continue
            }

            // Blockquote
            if trimmed.hasPrefix(">") {
                flushParagraph()
                let text = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                let line = NSMutableAttributedString(string: "▌ ", attributes: [
                    .font: T.bodyFont, .foregroundColor: T.overlay0,
                ])
                line.append(inline(text, font: T.bodyFont, color: T.quote, codeLink: nextCodeLink))
                appendBlock(line, to: out, style: para(first: 8, head: 30, spacingAfter: 6))
                continue
            }

            paragraph.append(rawLine)
        }

        if inFence { emitCode() }   // unterminated fence while streaming
        flushParagraph()
        flushTable()
        return RenderedMarkdown(text: out, codeBlocks: codeBlocks)
    }

    /// Plain text (user messages): no markdown parsing, but links are highlighted.
    static func plain(_ source: String, font: NSFont, color: NSColor, style: NSParagraphStyle) -> NSAttributedString {
        let s = NSMutableAttributedString(string: source, attributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: style,
        ])
        autolink(s)
        return s
    }

    /// Raw text of every fenced code block in `source` (used for "copy last code block").
    static func codeBlocks(in source: String) -> [String] {
        var blocks: [String] = []
        var current: [String] = []
        var inFence = false
        var marker = "```"
        for line in source.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if inFence {
                if t.hasPrefix(marker) { inFence = false; blocks.append(current.joined(separator: "\n")); current = [] }
                else { current.append(line) }
            } else if t.hasPrefix("```") || t.hasPrefix("~~~") {
                inFence = true; marker = String(t.prefix(3))
            }
        }
        if inFence { blocks.append(current.joined(separator: "\n")) }
        return blocks
    }

    // MARK: - Blocks

    static func para(first: CGFloat = 0, head: CGFloat = 0, tail: CGFloat = 0,
                             spacingBefore: CGFloat = 0, spacingAfter: CGFloat = 8, lineSpacing: CGFloat = 3,
                             alignment: NSTextAlignment = .left,
                             lineBreak: NSLineBreakMode = .byWordWrapping) -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.firstLineHeadIndent = first
        p.headIndent = head
        p.tailIndent = tail
        p.paragraphSpacingBefore = spacingBefore
        p.paragraphSpacing = spacingAfter
        p.lineSpacing = lineSpacing
        p.alignment = alignment
        p.lineBreakMode = lineBreak
        return p
    }

    private static func appendBlock(_ content: NSAttributedString, to out: NSMutableAttributedString, style: NSParagraphStyle) {
        let block = NSMutableAttributedString(attributedString: content)
        block.append(NSAttributedString(string: "\n"))
        block.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: block.length))
        out.append(block)
    }

    private static func appendCodeBlock(code: String, lang: String, item: Int, index: Int, to out: NSMutableAttributedString) {
        let mono = T.body(T.codeSize)
        let headerStyle = para(first: 10, head: 10, spacingBefore: 4, spacingAfter: 0, lineSpacing: 2)
        let header = NSMutableAttributedString(string: (lang.isEmpty ? "code" : lang).lowercased() + "   ", attributes: [
            .font: T.pixel(8), .foregroundColor: T.overlay0, .backgroundColor: T.codeBg,
        ])
        header.append(NSAttributedString(string: "[ COPY ]", attributes: [
            .font: T.pixel(8), .backgroundColor: T.codeBg,
            .link: URL(string: "servitor://copy-code/\(item)/\(index)") as Any,
        ]))
        header.append(NSAttributedString(string: " ", attributes: [.backgroundColor: T.codeBg]))
        header.append(NSAttributedString(string: "\n"))
        header.addAttribute(.paragraphStyle, value: headerStyle, range: NSRange(location: 0, length: header.length))
        out.append(header)

        let bodyStyle = para(first: 10, head: 10, tail: -10, spacingAfter: 0, lineSpacing: 2, lineBreak: .byCharWrapping)
        let body = NSMutableAttributedString(string: code.isEmpty ? " " : code, attributes: [
            .font: mono, .foregroundColor: T.codeFg, .backgroundColor: T.codeBg,
        ])
        body.append(NSAttributedString(string: "\n", attributes: [.backgroundColor: T.codeBg]))
        body.addAttribute(.paragraphStyle, value: bodyStyle, range: NSRange(location: 0, length: body.length))
        out.append(body)

        // breathing room after the block
        out.append(NSAttributedString(string: "\n", attributes: [
            .font: T.body(8), .paragraphStyle: para(spacingAfter: 4),
        ]))
    }

    private static func renderTable(_ rows: [String]) -> NSAttributedString {
        func cells(_ row: String) -> [String] {
            var parts = row.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.first == "" { parts.removeFirst() }
            if parts.last == "" { parts.removeLast() }
            return parts
        }
        var grid = rows.map(cells).filter { row in
            !row.allSatisfy { $0.range(of: #"^:?-{2,}:?$"#, options: .regularExpression) != nil }
        }
        let cols = grid.map(\.count).max() ?? 0
        grid = grid.map { $0 + Array(repeating: "", count: cols - $0.count) }
        var widths = Array(repeating: 0, count: cols)
        for row in grid { for (i, c) in row.enumerated() { widths[i] = max(widths[i], c.count) } }

        let out = NSMutableAttributedString()
        for (r, row) in grid.enumerated() {
            let line = row.enumerated().map { i, c in c.padding(toLength: widths[i], withPad: " ", startingAt: 0) }
                .joined(separator: " │ ")
            out.append(NSAttributedString(string: line + (r == grid.count - 1 ? "" : "\n"), attributes: [
                .font: T.body(T.codeSize), .foregroundColor: r == 0 ? T.bone : T.text,
            ]))
        }
        return out
    }

    private static func headingLevel(_ line: String) -> (level: Int, text: String)? {
        guard line.hasPrefix("#") else { return nil }
        let hashes = line.prefix { $0 == "#" }
        guard hashes.count <= 6, line.dropFirst(hashes.count).first == " " else { return nil }
        return (hashes.count, String(line.dropFirst(hashes.count + 1)).trimmingCharacters(in: .whitespaces))
    }

    private static func listItem(_ line: String) -> (level: Int, marker: String, text: String)? {
        guard let m = line.range(of: #"^(\s*)([-*+]|\d+[.)])\s+"#, options: .regularExpression) else { return nil }
        let prefix = String(line[m])
        let indent = prefix.prefix { $0 == " " || $0 == "\t" }.count
        let marker = prefix.trimmingCharacters(in: .whitespaces)
        let isBullet = ["-", "*", "+"].contains(marker)
        return (min(indent / 2, 4), isBullet ? "•" : marker, String(line[m.upperBound...]))
    }

    // MARK: - Inline

    /// Inline markdown (bold, italic, strike, code, links). Pixel fonts have no
    /// bold/italic faces, so emphasis is synthesised with stroke / obliqueness.
    static func inline(
        _ source: String,
        font: NSFont,
        color: NSColor,
        codeLink: ((String) -> URL)? = nil
    ) -> NSMutableAttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        options.failurePolicy = .returnPartiallyParsedIfPossible

        let result = NSMutableAttributedString()
        guard let parsed = try? AttributedString(markdown: source, options: options) else {
            result.append(NSAttributedString(string: source, attributes: [.font: font, .foregroundColor: color]))
            autolink(result)
            return result
        }

        for run in parsed.runs {
            let piece = String(parsed[run.range].characters)
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.stronglyEmphasized) {
                attrs[.strokeWidth] = -4
                attrs[.strokeColor] = color
            }
            if intent.contains(.emphasized) { attrs[.obliqueness] = 0.2 }
            if intent.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if intent.contains(.code) {
                attrs[.font] = T.body(font.pointSize * 0.92)
                attrs[.foregroundColor] = T.inlineCode
                attrs[.backgroundColor] = T.codeBg
                let candidate = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                if let url = URL(string: candidate), LinkPolicy.isOpenable(url) {
                    // A URL in backticks remains an openable link, not a copy-code target.
                    attrs[.link] = url
                } else if let codeLink {
                    attrs[.link] = codeLink(piece)
                }
            }
            if let url = run.link, LinkPolicy.isOpenable(url) { attrs[.link] = url }
            result.append(NSAttributedString(string: piece, attributes: attrs))
        }
        autolink(result)
        return result
    }

    /// Highlights bare URLs (anything NSDataDetector recognises) that aren't already links or code.
    private static func autolink(_ s: NSMutableAttributedString) {
        guard let detector = linkDetector else { return }
        let whole = NSRange(location: 0, length: s.length)
        for match in detector.matches(in: s.string, options: [], range: whole) {
            guard let url = match.url, LinkPolicy.isOpenable(url) else { continue }
            if s.attribute(.link, at: match.range.location, effectiveRange: nil) != nil { continue }
            if s.attribute(.backgroundColor, at: match.range.location, effectiveRange: nil) != nil { continue }
            s.addAttribute(.link, value: url, range: match.range)
        }
    }
}
