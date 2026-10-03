import Foundation

public struct AITicket: Equatable, Sendable {
    public var title: String
    public var context: String
    public var expected: String
    public var acceptance: [String]

    public init(title: String, context: String, expected: String, acceptance: [String]) {
        self.title = title
        self.context = context
        self.expected = expected
        self.acceptance = acceptance
    }
}

public struct OpenRouterModel: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let vision: Bool
    public let contextLength: Int
}

/// Which language the AI writes the ticket in.
public enum AIOutputLanguage: String, CaseIterable, Sendable {
    /// Persian title → Persian ticket, English title → English ticket.
    case sameAsInput
    case english
}

public enum AIError: LocalizedError, Sendable {
    case unauthorized
    case http(Int, String)
    case badOutput(String)
    case allFailed([String])

    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "OpenRouter rejected the API key. Check it in Settings."
        case .http(let code, let m):
            return m.isEmpty ? "OpenRouter error \(code)" : m
        case .badOutput(let m):
            return m
        case .allFailed(let errs):
            return errs.last ?? "No free model answered. Try again in a minute."
        }
    }
}

/// Rewrites a rough Jira title (+ optional notes/screenshots) into a clear ticket,
/// using free models on OpenRouter (OpenAI-compatible chat completions).
public final class AIService: @unchecked Sendable {
    public static let defaultModel = "openrouter/free"
    static let endpoint = URL(string: "https://openrouter.ai/api/v1")!

    private let apiKey: String
    private let model: String
    private let session: URLSession

    public init(apiKey: String, model: String) {
        self.apiKey = apiKey
        self.model = model.isEmpty ? Self.defaultModel : model
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 45
        self.session = URLSession(configuration: cfg)
    }

    // MARK: - Public API

    /// Tries the chosen model first, then up to two other free models if it is rate limited or down.
    public func improve(title: String, notes: String, images: [Data],
                        titleHints: [String],
                        language: AIOutputLanguage = .sameAsInput) async throws -> (ticket: AITicket, model: String) {
        let messages = Self.messages(title: title, notes: notes, images: images,
                                     titleHints: titleHints, language: language)
        var candidates = [model]
        var errors: [String] = []
        var loadedFallbacks = false
        var i = 0
        while i < candidates.count && i < 3 {
            let m = candidates[i]
            do {
                let content = try await chat(model: m, messages: messages)
                return (try Self.parseTicket(content), m)
            } catch AIError.unauthorized {
                throw AIError.unauthorized
            } catch {
                errors.append("\(m): \(error.localizedDescription)")
            }
            i += 1
            if i == candidates.count && !loadedFallbacks {
                loadedFallbacks = true
                let free = (try? await Self.freeModels()) ?? []
                let extra = Self.rank(free, needVision: !images.isEmpty).map(\.id).filter { !candidates.contains($0) }
                candidates += extra.prefix(2)
            }
        }
        throw AIError.allFailed(errors)
    }

    public func validateKey() async throws {
        var req = URLRequest(url: Self.endpoint.appendingPathComponent("key"))
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw AIError.unauthorized }
        if !(200..<300).contains(code) { throw AIError.http(code, Self.errorMessage(data)) }
    }

    /// Live list of models that cost nothing (prompt and completion price 0) and answer in text.
    public static func freeModels() async throws -> [OpenRouterModel] {
        let (data, _) = try await URLSession.shared.data(from: endpoint.appendingPathComponent("models"))
        let json = try JSONValue.parse(data)
        let models: [OpenRouterModel] = (json["data"]?.array ?? []).compactMap { m in
            guard let id = m["id"]?.string,
                  m["pricing"]?["prompt"]?.string == "0",
                  m["pricing"]?["completion"]?.string == "0" else { return nil }
            let inputs = (m["architecture"]?["input_modalities"]?.array ?? []).compactMap { $0.string }
            let outputs = (m["architecture"]?["output_modalities"]?.array ?? []).compactMap { $0.string }
            guard inputs.contains("text"), outputs.contains("text"),
                  !outputs.contains(where: { ["audio", "image", "video"].contains($0) }) else { return nil }
            let lower = id.lowercased()
            if lower.contains("safety") || lower.contains("guard") { return nil }
            return OpenRouterModel(
                id: id,
                name: m["name"]?.string ?? id,
                vision: inputs.contains("image"),
                contextLength: m["context_length"]?.int ?? 0
            )
        }
        return models.sorted { a, b in
            if a.id == defaultModel { return true }
            if b.id == defaultModel { return false }
            return a.contextLength > b.contextLength
        }
    }

    // MARK: - Request building

    static func systemPrompt(language: AIOutputLanguage) -> String {
        let languageRule: String
        switch language {
        case .sameAsInput:
            languageRule = """
            - Write in the same language as the raw title. If it is Persian (Farsi), write title, context, expected \
            and acceptance in natural, concise Persian, but keep English technical terms, product and component names \
            and code identifiers in English exactly as written. If the title mixes both, follow its main language.
            """
        case .english:
            languageRule = "- Write in English (translate if the input is in another language), keeping code identifiers as written."
        }
        return """
        You turn rough task notes into a clear Jira ticket for a frontend engineering team.

        Rules:
        \(languageRule)
        - "title": imperative and specific, max 90 characters, no trailing period, no ticket key, no emoji.
        - "context": 1-3 sentences on the problem or goal, using only what the input says.
        - "expected": 1-2 sentences describing the expected outcome.
        - "acceptance": 2-5 short, testable bullet points.
        - Never invent facts: components, URLs, numbers or root causes the input doesn't mention. When something is unknown, stay general.
        - If screenshots are attached, rely only on what is visible in them.
        - Keep identifiers, code names and quoted text exactly as written.
        - Plain text only, no Markdown, no HTML.

        Reply with ONLY a JSON object, no commentary:
        {"title": "...", "context": "...", "expected": "...", "acceptance": ["...", "..."]}
        """
    }

    static func messages(title: String, notes: String, images: [Data], titleHints: [String],
                         language: AIOutputLanguage = .sameAsInput) -> [[String: Any]] {
        var text = "Raw title: \(title)\n"
        let n = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        text += n.isEmpty ? "Notes: (none)\n" : "Notes:\n\(n)\n"
        let hints = titleHints.prefix(8)
        if !hints.isEmpty {
            text += "\nHow this team usually words titles (match the tone, don't copy):\n"
            text += hints.map { "- \($0)" }.joined(separator: "\n") + "\n"
        }
        if !images.isEmpty { text += "\n\(images.count) screenshot(s) attached." }

        let userContent: Any
        if images.isEmpty {
            userContent = text
        } else {
            var parts: [[String: Any]] = [["type": "text", "text": text]]
            for img in images.prefix(3) {
                parts.append([
                    "type": "image_url",
                    "image_url": ["url": "data:image/jpeg;base64,\(img.base64EncodedString())"],
                ])
            }
            userContent = parts
        }
        return [
            ["role": "system", "content": systemPrompt(language: language)],
            ["role": "user", "content": userContent],
        ]
    }

    static func rank(_ models: [OpenRouterModel], needVision: Bool) -> [OpenRouterModel] {
        let preferred = ["gemma-4-31b", "qwen3", "nemotron-3-super", "gemma-4-26b", "gpt-oss", "llama"]
        func score(_ m: OpenRouterModel) -> Int {
            preferred.firstIndex(where: { m.id.lowercased().contains($0) }) ?? preferred.count
        }
        return models
            .filter { $0.id != defaultModel && (!needVision || $0.vision) }
            .sorted { (score($0), -$0.contextLength) < (score($1), -$1.contextLength) }
    }

    // MARK: - Transport

    private func chat(model: String, messages: [[String: Any]]) async throws -> String {
        var req = URLRequest(url: Self.endpoint.appendingPathComponent("chat/completions"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("JiraBar", forHTTPHeaderField: "X-Title")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": messages,
            "temperature": 0.2,
            "max_tokens": 900,
        ] as [String: Any])

        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw AIError.unauthorized }
        guard (200..<300).contains(code) else { throw AIError.http(code, Self.errorMessage(data)) }

        let json = try JSONValue.parse(data)
        if let msg = json["error"]?["message"]?.string { throw AIError.http(code, msg) }
        guard let content = json["choices"]?.array?.first?["message"]?["content"]?.string,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIError.badOutput("The model returned an empty answer")
        }
        return content
    }

    static func errorMessage(_ data: Data) -> String {
        guard let j = try? JSONValue.parse(data) else { return "" }
        return j["error"]?["message"]?.string ?? j["message"]?.string ?? ""
    }

    // MARK: - Parsing

    public static func parseTicket(_ content: String) throws -> AITicket {
        guard let start = content.firstIndex(of: "{"), let end = content.lastIndex(of: "}"), start < end,
              let data = String(content[start...end]).data(using: .utf8),
              let json = try? JSONValue.parse(data) else {
            throw AIError.badOutput("The model didn't return valid JSON")
        }
        let title = cleanTitle(json["title"]?.string ?? "")
        guard !title.isEmpty else { throw AIError.badOutput("The model returned no title") }

        var acceptance: [String] = []
        if let arr = json["acceptance"]?.array {
            acceptance = arr.compactMap { $0.string }
        } else if let s = json["acceptance"]?.string {
            acceptance = s.components(separatedBy: "\n")
        }
        acceptance = acceptance
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-*• \t")).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return AITicket(
            title: title,
            context: (json["context"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            expected: (json["expected"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            acceptance: Array(acceptance.prefix(6))
        )
    }

    static func cleanTitle(_ raw: String) -> String {
        var t = raw.components(separatedBy: .newlines).first ?? raw
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.lowercased().hasPrefix("title:") { t = String(t.dropFirst(6)) }
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’«»` ").union(.whitespaces))
        while t.hasSuffix(".") { t.removeLast() }
        t = t.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if t.count > 150 { t = String(t.prefix(150)).trimmingCharacters(in: .whitespaces) }
        return t
    }
}
