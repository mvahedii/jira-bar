import Foundation

/// Jira Server's REST API v2 takes descriptions in wiki markup (not Markdown).
public enum WikiMarkup {
    /// Builds the structured description produced by the AI step.
    public static func description(_ t: AITicket, images: [String] = [], originalNotes: String = "",
                                   language: TextLanguage? = nil) -> String {
        let lang = language ?? TextDirection.detect(t.title + " " + t.context)
        let h = headings(lang)
        var parts: [String] = []
        if !t.context.isEmpty {
            parts.append("h3. \(h.context)\n\(inline(t.context))")
        }
        if !t.expected.isEmpty {
            parts.append("h3. \(h.expected)\n\(inline(t.expected))")
        }
        if !t.acceptance.isEmpty {
            parts.append("h3. \(h.acceptance)\n" + t.acceptance.map { "* \(inline($0))" }.joined(separator: "\n"))
        }
        // Never silently drop what the person typed: keep their own notes below the AI text.
        let notes = originalNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            parts.append("h3. \(h.original)\n{quote}\n\(inline(notes))\n{quote}")
        }
        if !images.isEmpty {
            parts.append(imageEmbeds(images))
        }
        return parts.joined(separator: "\n\n")
    }

    static func headings(_ lang: TextLanguage) -> (context: String, expected: String, acceptance: String, original: String) {
        switch lang {
        case .english:
            return ("Context", "Expected behavior", "Acceptance criteria", "Original notes")
        case .persian:
            return ("زمینه", "رفتار مورد انتظار", "معیارهای پذیرش", "یادداشت‌های اصلی")
        }
    }

    /// Plain notes (no AI) plus any uploaded screenshots.
    public static func plain(notes: String, images: [String]) -> String {
        var parts: [String] = []
        let n = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty { parts.append(n) }
        if !images.isEmpty { parts.append(imageEmbeds(images)) }
        return parts.joined(separator: "\n\n")
    }

    static func imageEmbeds(_ names: [String]) -> String {
        names.map { "!\($0)|thumbnail!" }.joined(separator: "\n")
    }

    /// Escapes macro braces and converts the few Markdown habits models can't shake.
    static func inline(_ s: String) -> String {
        var out = s.trimmingCharacters(in: .whitespacesAndNewlines)
        out = out.replacingOccurrences(of: "{", with: "\\{").replacingOccurrences(of: "}", with: "\\}")
        out = replace(#"\*\*(.+?)\*\*"#, in: out, with: "*$1*")
        out = replace(#"`([^`\n]+)`"#, in: out, with: "{{$1}}")
        return out
    }

    private static func replace(_ pattern: String, in s: String, with template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }
}
