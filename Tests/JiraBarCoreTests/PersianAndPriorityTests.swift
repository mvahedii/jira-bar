import Testing
import Foundation
@testable import JiraBarCore

@Suite struct PersianTextTests {
    @Test func detectsDirectionByFirstLetter() {
        #expect(TextDirection.isRTL("رفع باگ سبد خرید"))
        #expect(TextDirection.isRTL("  «سلام» world"))
        #expect(!TextDirection.isRTL("Fix cart badge"))
        #expect(TextDirection.isRTL("123 رفع"))            // digits aren't letters: the first letter is Persian
        #expect(!TextDirection.isRTL(""))
    }

    @Test func mixedTitleFollowsItsFirstLetter() {
        #expect(!TextDirection.isRTL("PDP کارت محصول"))
        #expect(TextDirection.isRTL("کارت محصول در PDP"))
    }

    @Test func detectsLanguageByMajority() {
        #expect(TextDirection.detect("رفع باگ نمایش تعداد سبد خرید در هدر") == .persian)
        #expect(TextDirection.detect("Fix cart badge") == .english)
        #expect(TextDirection.detect("Fix cart badge در سبد") == .english)
        #expect(TextDirection.detect("") == .english)
    }

    @Test func persianTicketGetsPersianHeadings() throws {
        let t = try AIService.parseTicket("""
        {"title": "رفع باگ نمایش تعداد سبد خرید در هدر.", "context": "بعد از افزودن کالا از PDP عدد سبد به‌روز نمی‌شود.", "expected": "عدد سبد بلافاصله به‌روز شود.", "acceptance": ["عدد بدون رفرش به‌روز شود", "روی موبایل هم کار کند"]}
        """)
        #expect(t.title == "رفع باگ نمایش تعداد سبد خرید در هدر")
        let d = WikiMarkup.description(t, images: [], originalNotes: "سبد بعد از افزودن آپدیت نمیشه")
        #expect(d.contains("h3. زمینه\n"))
        #expect(d.contains("h3. رفتار مورد انتظار\n"))
        #expect(d.contains("h3. معیارهای پذیرش\n* عدد بدون رفرش"))
        #expect(d.contains("h3. یادداشت‌های اصلی\n{quote}\nسبد بعد از افزودن آپدیت نمیشه\n{quote}"))
        #expect(!d.contains("Context"))
    }

    @Test func englishTicketKeepsEnglishHeadings() {
        let t = AITicket(title: "Fix cart badge", context: "c", expected: "e", acceptance: ["a"])
        #expect(WikiMarkup.description(t).contains("h3. Context"))
        // an explicit language wins over detection
        #expect(WikiMarkup.description(t, language: .persian).contains("h3. زمینه"))
    }

    @Test func quotesAroundTitleAreStripped() {
        #expect(AIService.cleanTitle("«رفع باگ»") == "رفع باگ")
    }

    @Test func promptFollowsTheLanguageSetting() {
        let same = AIService.systemPrompt(language: .sameAsInput)
        #expect(same.contains("same language as the raw title"))
        #expect(same.contains("Persian"))
        let en = AIService.systemPrompt(language: .english)
        #expect(en.contains("Write in English"))
        #expect(!en.contains("same language as the raw title"))
    }

    @Test func persianSurvivesTheRequestBody() throws {
        let msgs = AIService.messages(title: "رفع باگ سبد", notes: "", images: [], titleHints: [])
        let data = try JSONSerialization.data(withJSONObject: msgs)
        let back = String(decoding: data, as: UTF8.self)
        #expect(back.contains("رفع باگ سبد") || back.contains("\\u"))   // either raw UTF-8 or escaped, never mangled
        let decoded = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        #expect((decoded?[1]["content"] as? String)?.contains("رفع باگ سبد") == true)
    }
}

@Suite struct PriorityAndMoveTests {
    let prios = [
        PriorityRef(id: "1", name: "Highest"), PriorityRef(id: "2", name: "High"),
        PriorityRef(id: "3", name: "Medium"), PriorityRef(id: "4", name: "Low"), PriorityRef(id: "5", name: "Lowest"),
    ]

    func issue(_ key: String, _ p: String?) -> BoardIssue {
        BoardIssue(key: key, summary: key, statusId: "10004", statusName: "To Do", issueType: "Task", priorityId: p)
    }

    @Test func sortsHighestPriorityFirstAndKeepsRankOrderAmongEquals() {
        let list = [issue("A", "3"), issue("B", "1"), issue("C", "3"), issue("D", "2"), issue("E", nil), issue("F", "1")]
        let sorted = BoardLogic.sortedByPriority(list, priorities: prios).map(\.key)
        #expect(sorted == ["B", "F", "D", "A", "C", "E"])
    }

    @Test func noPriorityListLeavesOrderUntouched() {
        let list = [issue("A", "3"), issue("B", "1")]
        #expect(BoardLogic.sortedByPriority(list, priorities: nil).map(\.key) == ["A", "B"])
        #expect(BoardLogic.sortedByPriority(list, priorities: []).map(\.key) == ["A", "B"])
    }

    @Test func parsesPriorityFromIssueJSON() throws {
        let json = #"{"key":"DDS-1","fields":{"summary":"x","status":{"id":"3","name":"In Progress"},"issuetype":{"name":"Task"},"priority":{"id":"1","name":"Highest"}}}"#
        let issue = try #require(JiraClient.parseIssue(try JSONValue.parse(Data(json.utf8)), profile: ddsProfile))
        #expect(issue.priorityId == "1")
        #expect(issue.priorityName == "Highest")
    }

    @Test func oldSavedBoardsWithoutPrioritiesStillDecode() throws {
        let old = """
        {"id":95,"name":"DDS","type":"kanban","projectKey":"DDS","columns":[{"name":"Backlog","statusIds":["10108"]}],
         "issueTypes":[{"id":"10200","name":"Task"}],"storyPointsField":"customfield_10106"}
        """
        let p = try JSONDecoder().decode(BoardProfile.self, from: Data(old.utf8))
        #expect(p.priorities == nil)
        #expect(p.id == 95)
    }

    // MARK: direct "Move to…" targets

    @Test func moveToAnyReachableKanbanColumn() {
        let cols = BoardLogic.columns(for: ddsProfile)
        let plan = BoardLogic.plan(for: ddsIssue(status: "10108"), columns: cols, type: .kanban,
                                   transitions: ddsFromBacklog, toColumn: 3, hasActiveSprint: false)
        #expect(plan == .transition(ddsFromBacklog[3], toColumn: 3))
        // Done has no transition from Backlog → unreachable
        #expect(BoardLogic.plan(for: ddsIssue(status: "10108"), columns: cols, type: .kanban,
                                transitions: ddsFromBacklog, toColumn: 6, hasActiveSprint: false) == nil)
        // already there
        #expect(BoardLogic.plan(for: ddsIssue(status: "10108"), columns: cols, type: .kanban,
                                transitions: ddsFromBacklog, toColumn: 0, hasActiveSprint: false) == nil)
    }

    @Test func moveToColumnOnScrumBoard() {
        let cols = BoardLogic.columns(for: disProfile)
        let backlogIssue = disIssue(status: "10004", sprint: nil)
        #expect(BoardLogic.plan(for: backlogIssue, columns: cols, type: .scrum, transitions: disFromToDo,
                                toColumn: 1, hasActiveSprint: true) == .addToSprint(toColumn: 1, then: nil))
        #expect(BoardLogic.plan(for: backlogIssue, columns: cols, type: .scrum, transitions: disFromToDo,
                                toColumn: 2, hasActiveSprint: true) == .addToSprint(toColumn: 2, then: disFromToDo[1]))
        #expect(BoardLogic.plan(for: backlogIssue, columns: cols, type: .scrum, transitions: disFromToDo,
                                toColumn: 2, hasActiveSprint: false) == nil)
        let inSprint = disIssue(status: "10004", sprint: 266)
        #expect(BoardLogic.plan(for: inSprint, columns: cols, type: .scrum, transitions: disFromToDo,
                                toColumn: 0, hasActiveSprint: true) == .removeFromSprint(toColumn: 0))
    }
}
