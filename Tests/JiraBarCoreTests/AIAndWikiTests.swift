import Testing
import Foundation
@testable import JiraBarCore

@Suite struct AIParsingTests {
    @Test func parsesCleanJSON() throws {
        let t = try AIService.parseTicket("""
        {"title": "Fix cart badge not updating after add", "context": "The badge stays at 0.", "expected": "Badge reflects the cart.", "acceptance": ["Badge updates instantly", "Works after reload"]}
        """)
        #expect(t.title == "Fix cart badge not updating after add")
        #expect(t.acceptance.count == 2)
    }

    @Test func toleratesCodeFencesAndChatter() throws {
        let t = try AIService.parseTicket("""
        Sure! Here you go:
        ```json
        {"title": "Add skeleton to PDP.", "context": "c", "expected": "e", "acceptance": ["- one", "* two", "• three"]}
        ```
        Hope that helps.
        """)
        #expect(t.title == "Add skeleton to PDP")        // trailing period removed
        #expect(t.acceptance == ["one", "two", "three"])  // bullet glyphs stripped
    }

    @Test func acceptanceAsMultilineString() throws {
        let t = try AIService.parseTicket(#"{"title":"T","context":"","expected":"","acceptance":"- a\n- b"}"#)
        #expect(t.acceptance == ["a", "b"])
    }

    @Test func rejectsMissingTitleAndGarbage() {
        #expect(throws: AIError.self) { try AIService.parseTicket(#"{"context":"x"}"#) }
        #expect(throws: AIError.self) { try AIService.parseTicket("no json here") }
    }

    @Test func titleIsCleanedAndCapped() {
        #expect(AIService.cleanTitle("  \"Fix   the   thing\"  ") == "Fix the thing")
        #expect(AIService.cleanTitle("Title: Do it\nsecond line") == "Do it")
        #expect(AIService.cleanTitle(String(repeating: "a", count: 400)).count <= 150)
    }

    @Test func messagesIncludeImagesOnlyWhenPresent() {
        let plain = AIService.messages(title: "t", notes: "", images: [], titleHints: [])
        #expect(plain[1]["content"] is String)
        let withImg = AIService.messages(title: "t", notes: "", images: [Data([1, 2, 3])], titleHints: ["Fix A"])
        let parts = withImg[1]["content"] as? [[String: Any]]
        #expect(parts?.count == 2)
        #expect((parts?[0]["text"] as? String)?.contains("Fix A") == true)
    }

    @Test func fallbackRankingPrefersVisionWhenNeeded() {
        let models = [
            OpenRouterModel(id: "a/text-only:free", name: "a", vision: false, contextLength: 900_000),
            OpenRouterModel(id: "google/gemma-4-31b-it:free", name: "g", vision: true, contextLength: 262_144),
            OpenRouterModel(id: "openrouter/free", name: "auto", vision: true, contextLength: 200_000),
        ]
        let ranked = AIService.rank(models, needVision: true).map(\.id)
        #expect(ranked == ["google/gemma-4-31b-it:free"])
        #expect(AIService.rank(models, needVision: false).first?.id == "google/gemma-4-31b-it:free")
    }
}

@Suite struct WikiMarkupTests {
    @Test func rendersStructuredDescription() {
        let t = AITicket(title: "T", context: "Badge stays at 0.", expected: "It updates.", acceptance: ["A", "B"])
        let d = WikiMarkup.description(t, images: ["shot.png"])
        #expect(d.contains("h3. Context\nBadge stays at 0."))
        #expect(d.contains("h3. Expected behavior\nIt updates."))
        #expect(d.contains("h3. Acceptance criteria\n* A\n* B"))
        #expect(d.hasSuffix("!shot.png|thumbnail!"))
    }

    @Test func escapesMacrosAndConvertsMarkdown() {
        #expect(WikiMarkup.inline("Use {code} here") == "Use \\{code\\} here")
        #expect(WikiMarkup.inline("This is **bold** and `x.y`") == "This is *bold* and {{x.y}}")
    }

    @Test func plainDescriptionKeepsNotesAndImages() {
        #expect(WikiMarkup.plain(notes: "  hi ", images: ["a.png", "b.png"]) == "hi\n\n!a.png|thumbnail!\n!b.png|thumbnail!")
        #expect(WikiMarkup.plain(notes: "", images: []) == "")
    }
}

@Suite struct WikiOriginalNotesTests {
    @Test func keepsTheUsersOwnNotesBelowTheAIText() {
        let t = AITicket(title: "T", context: "C", expected: "E", acceptance: ["A"])
        let d = WikiMarkup.description(t, images: [], originalNotes: "badge stays 0 {weird}")
        #expect(d.contains("h3. Original notes\n{quote}\nbadge stays 0 \\{weird\\}\n{quote}"))
        #expect(!WikiMarkup.description(t, images: [], originalNotes: "  ").contains("Original notes"))
    }
}
