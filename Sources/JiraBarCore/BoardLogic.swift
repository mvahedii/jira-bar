import Foundation

public enum BoardScope: String, CaseIterable, Sendable {
    case mine
    case all
}

/// A column as shown in the app. Scrum boards get a virtual "Backlog" column in front
/// (an issue is in the backlog when it isn't part of the active sprint).
public struct BoardColumnVM: Hashable, Identifiable, Sendable {
    public let index: Int
    public var id: Int { index }
    public let name: String
    public let statusIds: [String]
    public let isBacklog: Bool

    public init(index: Int, name: String, statusIds: [String], isBacklog: Bool) {
        self.index = index
        self.name = name
        self.statusIds = statusIds
        self.isBacklog = isBacklog
    }
}

public enum MovePlan: Equatable, Sendable {
    case transition(JiraTransition, toColumn: Int)
    case addToSprint(toColumn: Int, then: JiraTransition?)
    case removeFromSprint(toColumn: Int)

    public var targetColumn: Int {
        switch self {
        case .transition(_, let c), .addToSprint(let c, _), .removeFromSprint(let c): return c
        }
    }
}

public enum BoardLogic {
    public static func columns(for profile: BoardProfile) -> [BoardColumnVM] {
        var cols: [BoardColumnVM] = []
        if profile.type == .scrum {
            cols.append(BoardColumnVM(index: 0, name: "Backlog", statusIds: [], isBacklog: true))
        }
        for c in profile.columns {
            cols.append(BoardColumnVM(index: cols.count, name: c.name, statusIds: c.statusIds, isBacklog: false))
        }
        return cols
    }

    public static func columnIndex(of issue: BoardIssue, in columns: [BoardColumnVM], type: BoardType) -> Int? {
        if type == .scrum && issue.activeSprintId == nil { return 0 }
        return columns.first(where: { !$0.isBacklog && $0.statusIds.contains(issue.statusId) })?.index
    }

    /// JQL (ANDed with the board's own filter by Jira) for the issues shown in the Board tab.
    /// "Open" means status category, not resolution: some workflows (e.g. DIS) reach Done without
    /// ever setting a resolution, and those must not show up as live work.
    public static func jql(type: BoardType, scope: BoardScope) -> String {
        let mine = "(assignee = currentUser() OR (reporter = currentUser() AND assignee is EMPTY))"
        switch (type, scope) {
        case (.scrum, .mine):
            return "\(mine) AND (sprint in openSprints() OR statusCategory != Done)"
        case (.scrum, .all):
            return "sprint in openSprints()"
        case (_, .mine):
            return "\(mine) AND (statusCategory != Done OR updated >= -3d)"
        case (_, .all):
            return "(statusCategory != Done OR updated >= -3d)"
        }
    }

    /// Works out what one ← / → press (or ⇧← / ⇧→ with `jump`) should do for an issue.
    /// Columns that can't be reached with the transitions currently available are skipped.
    public static func plan(for issue: BoardIssue, columns: [BoardColumnVM], type: BoardType,
                            transitions: [JiraTransition], direction: Int, jump: Bool,
                            hasActiveSprint: Bool) -> MovePlan? {
        guard direction == 1 || direction == -1,
              let cur = columnIndex(of: issue, in: columns, type: type) else { return nil }

        // One step out of the backlog = join the sprint and stay in the column of the current status
        // (a carried-over "In Progress" task must not be sent back to "To Do").
        if !jump, direction == 1, columns[cur].isBacklog, hasActiveSprint,
           let own = columns.first(where: { !$0.isBacklog && $0.statusIds.contains(issue.statusId) }) {
            return .addToSprint(toColumn: own.index, then: nil)
        }

        var found: MovePlan?
        var i = cur + direction
        while columns.indices.contains(i) {
            let col = columns[i]
            var candidate: MovePlan?

            if col.isBacklog {
                if issue.activeSprintId != nil { candidate = .removeFromSprint(toColumn: i) }
            } else if columns[cur].isBacklog {
                if hasActiveSprint {
                    if col.statusIds.contains(issue.statusId) {
                        candidate = .addToSprint(toColumn: i, then: nil)
                    } else if let t = transition(for: col, issue: issue, in: transitions) {
                        candidate = .addToSprint(toColumn: i, then: t)
                    }
                }
            } else if let t = transition(for: col, issue: issue, in: transitions) {
                candidate = .transition(t, toColumn: i)
            }

            if let c = candidate {
                found = c
                if !jump { break }
            }
            i += direction
        }
        return found
    }

    /// Direct move to a specific column (the "Move to…" menu). Nil when it isn't reachable.
    public static func plan(for issue: BoardIssue, columns: [BoardColumnVM], type: BoardType,
                            transitions: [JiraTransition], toColumn target: Int,
                            hasActiveSprint: Bool) -> MovePlan? {
        guard columns.indices.contains(target),
              let cur = columnIndex(of: issue, in: columns, type: type), cur != target else { return nil }
        let col = columns[target]

        if col.isBacklog {
            return issue.activeSprintId != nil ? .removeFromSprint(toColumn: target) : nil
        }
        if columns[cur].isBacklog {
            guard hasActiveSprint else { return nil }
            if col.statusIds.contains(issue.statusId) { return .addToSprint(toColumn: target, then: nil) }
            if let t = transition(for: col, issue: issue, in: transitions) { return .addToSprint(toColumn: target, then: t) }
            return nil
        }
        return transition(for: col, issue: issue, in: transitions).map { .transition($0, toColumn: target) }
    }

    /// Position of the issue's priority in the project's list (0 = highest); unknown sorts last.
    public static func priorityRank(_ issue: BoardIssue, priorities: [PriorityRef]?) -> Int {
        guard let id = issue.priorityId, let list = priorities,
              let i = list.firstIndex(where: { $0.id == id }) else { return Int.max }
        return i
    }

    /// Highest priority first; Jira's own (rank) order is kept among equal priorities.
    public static func sortedByPriority(_ issues: [BoardIssue], priorities: [PriorityRef]?) -> [BoardIssue] {
        guard let priorities, !priorities.isEmpty else { return issues }
        return issues.enumerated().sorted { a, b in
            let ra = priorityRank(a.element, priorities: priorities)
            let rb = priorityRank(b.element, priorities: priorities)
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }

    static func transition(for column: BoardColumnVM, issue: BoardIssue,
                           in transitions: [JiraTransition]) -> JiraTransition? {
        let candidates = transitions.filter {
            column.statusIds.contains($0.toStatusId) && $0.toStatusId != issue.statusId
        }
        guard !candidates.isEmpty else { return nil }
        let key = normalize(column.name)
        if let exact = candidates.first(where: { normalize($0.toStatusName) == key || normalize($0.name) == key }) {
            return exact
        }
        if let partial = candidates.first(where: { !normalize($0.toStatusName).isEmpty && key.contains(normalize($0.toStatusName)) }) {
            return partial
        }
        return candidates[0]
    }

    static func normalize(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}

public enum SprintParser {
    /// Jira Server returns the Sprint custom field as legacy strings like
    /// `com.atlassian.greenhopper.service.sprint.Sprint@1a2b[id=266,name=S02,state=ACTIVE,...]`
    /// (newer versions return objects). Handles both.
    public static func parse(_ value: JSONValue?) -> [SprintRef] {
        guard let items = value?.array else { return [] }
        return items.compactMap { item in
            if let s = item.string { return parseLegacy(s) }
            if let id = item["id"]?.int {
                return SprintRef(id: id, name: item["name"]?.string ?? "", state: item["state"]?.string ?? "")
            }
            return nil
        }
    }

    static func parseLegacy(_ s: String) -> SprintRef? {
        func capture(_ pattern: String) -> String? {
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
                  m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: s) else { return nil }
            return String(s[r])
        }
        guard let idStr = capture(#"[\[,]id=(\d+)"#), let id = Int(idStr) else { return nil }
        let name = capture(#"name=(.*?),(?:rapidViewId|sequence|startDate|endDate|goal|completeDate|activatedDate|synced)="#) ?? ""
        let state = capture(#"state=([A-Za-z]+)"#) ?? ""
        return SprintRef(id: id, name: name, state: state)
    }
}
