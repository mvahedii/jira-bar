import SwiftUI
import JiraBarCore

struct BoardSection: Identifiable {
    let id: Int
    let column: BoardColumnVM
    var issues: [BoardIssue]
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let isError: Bool
}

/// What a ← / → press would do for an issue right now (drives the labels on the move buttons).
enum MoveTarget: Equatable {
    case unknown          // transitions not loaded yet
    case none             // nowhere to go in that direction
    case to(String)       // column name
}

private enum MoveRequest {
    case step(direction: Int, jump: Bool)
    case column(Int)
}

/// State behind the Board tab: loads issues, keeps a selection, moves issues with one key.
@MainActor
final class BoardFlow: ObservableObject {
    @Published private(set) var issues: [BoardIssue] = []
    @Published private(set) var loading = false
    @Published private(set) var loadedOnce = false
    @Published private(set) var sprint: SprintRef?
    @Published var error: String?
    @Published private(set) var toast: Toast?
    @Published private(set) var transitionCache: [String: (statusId: String, list: [JiraTransition])] = [:]
    @Published var scope: BoardScope = .mine {
        didSet { if oldValue != scope { refresh() } }
    }
    @Published var selection: String? {
        didSet { if selection != oldValue { prefetchTransitions() } }
    }
    /// Highest priority first inside every column (Jira's own order breaks ties).
    @Published var sortByPriority: Bool {
        didSet { UserDefaults.standard.set(sortByPriority, forKey: "sortByPriority") }
    }

    private let settings: Settings
    private var loadedBoardID: Int?
    private var lastRefresh = Date.distantPast
    private var refreshGeneration = 0
    private var moveChain: [String: Task<Void, Never>] = [:]
    private var inFlight: Set<String> = []
    #if DEBUG
    var offlineDemo = false
    #endif

    init(settings: Settings) {
        self.settings = settings
        sortByPriority = UserDefaults.standard.object(forKey: "sortByPriority") as? Bool ?? true
    }

    var board: BoardProfile? { settings.activeBoard }
    var columns: [BoardColumnVM] { board.map { BoardLogic.columns(for: $0) } ?? [] }
    var priorities: [PriorityRef] { board?.priorities ?? [] }
    var recentTitles: [String] { issues.prefix(10).map(\.summary) }

    var sections: [BoardSection] {
        guard let board else { return [] }
        let cols = BoardLogic.columns(for: board)
        var buckets: [Int: [BoardIssue]] = [:]
        var other: [BoardIssue] = []
        for issue in issues {
            if let c = BoardLogic.columnIndex(of: issue, in: cols, type: board.type) {
                buckets[c, default: []].append(issue)
            } else {
                other.append(issue)
            }
        }
        func ordered(_ list: [BoardIssue]) -> [BoardIssue] {
            sortByPriority ? BoardLogic.sortedByPriority(list, priorities: board.priorities) : list
        }
        var out = cols.map { BoardSection(id: $0.index, column: $0, issues: ordered(buckets[$0.index] ?? [])) }
        if !other.isEmpty {
            out.append(BoardSection(
                id: -1,
                column: BoardColumnVM(index: -1, name: "Other", statusIds: [], isBacklog: false),
                issues: ordered(other)
            ))
        }
        return out
    }

    // MARK: - Loading

    /// Shows the cache instantly and refreshes in the background when it's older than `maxAge`.
    func refreshIfStale(maxAge: TimeInterval = 20) {
        if loadedBoardID != board?.id || Date().timeIntervalSince(lastRefresh) > maxAge { refresh() }
    }

    func refresh() {
        #if DEBUG
        if offlineDemo { return }
        #endif
        guard let board, let client = settings.makeClient() else { return }
        if loadedBoardID != board.id {
            issues = []
            selection = nil
            loadedOnce = false
        }
        loading = true
        error = nil
        refreshGeneration += 1
        let generation = refreshGeneration
        let scope = scope

        Task {
            do {
                let fetched = try await client.boardIssues(profile: board, scope: scope)
                let sprint = board.type == .scrum ? try? await client.activeSprint(boardId: board.id) : nil
                guard generation == refreshGeneration else { return }

                // Keep optimistic state for issues that are mid-change.
                var merged = fetched
                for i in merged.indices where inFlight.contains(merged[i].key) {
                    if let local = issues.first(where: { $0.key == merged[i].key }) { merged[i] = local }
                }
                issues = merged
                self.sprint = sprint
                loadedBoardID = board.id
                loadedOnce = true
                lastRefresh = Date()
                if selection == nil || !issues.contains(where: { $0.key == selection }) {
                    selection = sections.first(where: { !$0.issues.isEmpty })?.issues.first?.key
                }
            } catch {
                guard generation == refreshGeneration else { return }
                self.error = error.localizedDescription
            }
            if generation == refreshGeneration { loading = false }
        }
    }

    // MARK: - Selection

    var orderedKeys: [String] { sections.flatMap { $0.issues.map(\.key) } }

    func moveSelection(by delta: Int) {
        let keys = orderedKeys
        guard !keys.isEmpty else { return }
        guard let cur = selection, let i = keys.firstIndex(of: cur) else { selection = keys.first; return }
        selection = keys[min(max(i + delta, 0), keys.count - 1)]
    }

    var selectedIssue: BoardIssue? { issues.first(where: { $0.key == selection }) }

    func open(_ key: String) {
        guard let url = settings.makeClient()?.browseURL(key) else { return }
        NSWorkspace.shared.open(url)
    }

    func openSelected() {
        if let key = selection { open(key) }
    }

    func copyLink(_ key: String) {
        guard let url = settings.makeClient()?.browseURL(key) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        show("Copied \(key) link")
    }

    func copySelectedLink() {
        if let key = selection { copyLink(key) }
    }

    // MARK: - Moving issues

    private func prefetchTransitions() {
        guard let issue = selectedIssue, let client = settings.makeClient() else { return }
        if let cached = transitionCache[issue.key], cached.statusId == issue.statusId { return }
        Task { _ = try? await transitions(for: issue, client: client) }
    }

    private func transitions(for issue: BoardIssue, client: JiraClient) async throws -> [JiraTransition] {
        if let cached = transitionCache[issue.key], cached.statusId == issue.statusId { return cached.list }
        let list = try await client.transitions(key: issue.key)
        transitionCache[issue.key] = (issue.statusId, list)
        return list
    }

    /// Where ← / → would take this issue, using the transitions already loaded.
    func target(for issue: BoardIssue, direction: Int) -> MoveTarget {
        guard let board else { return .none }
        let cols = BoardLogic.columns(for: board)
        guard let cached = transitionCache[issue.key], cached.statusId == issue.statusId else { return .unknown }
        guard let plan = BoardLogic.plan(
            for: issue, columns: cols, type: board.type, transitions: cached.list,
            direction: direction, jump: false, hasActiveSprint: sprint != nil
        ) else { return .none }
        return .to(cols[plan.targetColumn].name)
    }

    /// False only when we know (transitions loaded) that the issue can't go to that column.
    func canMove(_ issue: BoardIssue, toColumn index: Int) -> Bool {
        guard let board else { return false }
        let cols = BoardLogic.columns(for: board)
        guard let cur = BoardLogic.columnIndex(of: issue, in: cols, type: board.type), cur != index else { return false }
        guard let cached = transitionCache[issue.key], cached.statusId == issue.statusId else { return true }
        return BoardLogic.plan(for: issue, columns: cols, type: board.type, transitions: cached.list,
                               toColumn: index, hasActiveSprint: sprint != nil) != nil
    }

    func moveSelected(direction: Int, jump: Bool = false) {
        guard let key = selection else { return }
        enqueue(key, .step(direction: direction, jump: jump))
    }

    func move(key: String, direction: Int) {
        selection = key
        enqueue(key, .step(direction: direction, jump: false))
    }

    func move(key: String, toColumn index: Int) {
        selection = key
        enqueue(key, .column(index))
    }

    /// Requests for the same issue are queued so fast repeated presses chain correctly.
    private func enqueue(_ key: String, _ request: MoveRequest) {
        let previous = moveChain[key]
        moveChain[key] = Task { [weak self] in
            await previous?.value
            await self?.performMove(key: key, request: request)
        }
    }

    private func performMove(key: String, request: MoveRequest) async {
        guard let board, let client = settings.makeClient(),
              let idx = issues.firstIndex(where: { $0.key == key }) else { return }
        let before = issues[idx]
        let cols = BoardLogic.columns(for: board)

        let transitions: [JiraTransition]
        do { transitions = try await self.transitions(for: before, client: client) }
        catch { show(error.localizedDescription, isError: true); return }

        let plan: MovePlan?
        switch request {
        case .step(let direction, let jump):
            plan = BoardLogic.plan(for: before, columns: cols, type: board.type, transitions: transitions,
                                   direction: direction, jump: jump, hasActiveSprint: sprint != nil)
        case .column(let index):
            plan = BoardLogic.plan(for: before, columns: cols, type: board.type, transitions: transitions,
                                   toColumn: index, hasActiveSprint: sprint != nil)
        }
        guard let plan else {
            switch request {
            case .column(let index) where cols.indices.contains(index):
                show("\(key) can't go to “\(cols[index].name)” from its current status", isError: true)
            default:
                show(BoardLogic.columnIndex(of: before, in: cols, type: board.type) == nil
                     ? "\(key) has a status that isn't a column on this board"
                     : "Nowhere further to move \(key) in that direction")
            }
            return
        }

        // Optimistic update first, network second.
        inFlight.insert(key)
        defer { inFlight.remove(key) }
        apply(plan, to: key)

        do {
            switch plan {
            case .transition(let t, _):
                try await client.doTransition(key: key, transitionId: t.id)
            case .addToSprint(_, let then):
                if let sprint { try await client.addToSprint(sprintId: sprint.id, key: key) }
                if let t = then { try await client.doTransition(key: key, transitionId: t.id) }
            case .removeFromSprint:
                try await client.moveToBacklog(key: key)
            }
            transitionCache[key] = nil
            prefetchTransitions()
            show("\(key) → \(cols[plan.targetColumn].name)")
        } catch {
            if let i = issues.firstIndex(where: { $0.key == key }) { issues[i] = before }
            transitionCache[key] = nil
            show("Couldn't move \(key): \(error.localizedDescription)", isError: true)
        }
    }

    private func apply(_ plan: MovePlan, to key: String) {
        guard let i = issues.firstIndex(where: { $0.key == key }) else { return }
        switch plan {
        case .transition(let t, _):
            issues[i].statusId = t.toStatusId
            issues[i].statusName = t.toStatusName
        case .addToSprint(_, let then):
            issues[i].activeSprintId = sprint?.id
            if let t = then {
                issues[i].statusId = t.toStatusId
                issues[i].statusName = t.toStatusName
            }
        case .removeFromSprint:
            issues[i].activeSprintId = nil
        }
    }

    // MARK: - Priority

    func setPriority(key: String, to priority: PriorityRef) {
        guard let client = settings.makeClient(), let i = issues.firstIndex(where: { $0.key == key }),
              issues[i].priorityId != priority.id else { return }
        let before = issues[i]
        issues[i].priorityId = priority.id
        issues[i].priorityName = priority.name
        inFlight.insert(key)
        Task {
            defer { inFlight.remove(key) }
            do {
                try await client.setPriority(key: key, priorityId: priority.id)
                show("\(key) priority → \(priority.name)")
            } catch {
                if let j = issues.firstIndex(where: { $0.key == key }) { issues[j] = before }
                show("Couldn't change priority of \(key): \(error.localizedDescription)", isError: true)
            }
        }
    }

    /// ⌥↑ raises, ⌥↓ lowers the selected issue's priority by one step.
    func changeSelectedPriority(raise: Bool) {
        let list = priorities
        guard let issue = selectedIssue, !list.isEmpty else { return }
        let current = issue.priorityId.flatMap { id in list.firstIndex(where: { $0.id == id }) }
            ?? list.firstIndex(where: { $0.name == "Medium" })
            ?? list.count / 2
        let next = min(max(current + (raise ? -1 : 1), 0), list.count - 1)
        if next == current, issue.priorityId != nil {
            show("\(issue.key) is already at the \(raise ? "highest" : "lowest") priority")
            return
        }
        setPriority(key: issue.key, to: list[next])
    }

    // MARK: - Toasts

    func show(_ text: String, isError: Bool = false) {
        let t = Toast(text: text, isError: isError)
        toast = t
        Task {
            try? await Task.sleep(nanoseconds: isError ? 5_000_000_000 : 2_200_000_000)
            if toast == t { toast = nil }
        }
    }
}

#if DEBUG
extension BoardFlow {
    func loadDemoData() {
        offlineDemo = true
        func i(_ key: String, _ s: String, _ type: String, _ status: String, _ name: String, _ sp: Double?, _ prio: String) -> BoardIssue {
            let prioName = Settings.demoPriorities.first(where: { $0.id == prio })?.name
            return BoardIssue(key: key, summary: s, statusId: status, statusName: name, issueType: type,
                              storyPoints: sp, priorityId: prio, priorityName: prioName)
        }
        issues = [
            i("DDS-656", "Add skeleton loading state to product card", "Task", "10108", "Backlog", 3, "3"),
            i("DDS-661", "Support RTL layout in floating nav bar", "Story", "10108", "Backlog", 5, "1"),
            i("DDS-660", "Fix floating nav bar safe-area inset on small iPhones", "Bug", "10004", "To Do", 2, "2"),
            i("DDS-664", "رفع باگ نمایش تعداد سبد خرید در هدر", "Bug", "10004", "To Do", 3, "1"),
            i("DDS-648", "Toast service: stack multiple toasts and swipe to dismiss", "Story", "3", "In Progress", 5, "3"),
            i("DDS-641", "Bottom sheet drag handle needs accessibility labels", "Task", "10013", "Test", 1, "4"),
            i("DDS-633", "Document spacing tokens in Storybook", "Task", "10003", "Done", 2, "3"),
        ]
        transitionCache["DDS-648"] = ("3", [
            JiraTransition(id: "11", name: "To Do", toStatusId: "10004", toStatusName: "To Do"),
            JiraTransition(id: "41", name: "Test", toStatusId: "10013", toStatusName: "Test"),
            JiraTransition(id: "51", name: "To Backlog", toStatusId: "10108", toStatusName: "Backlog"),
            JiraTransition(id: "31", name: "Done", toStatusId: "10003", toStatusName: "Done"),
        ])
        selection = "DDS-648"
        loadedOnce = true
        show("DDS-648 → 🟠 Working on it")
    }
}
#endif
