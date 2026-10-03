import Foundation

public enum BoardType: String, Codable, Sendable {
    case scrum
    case kanban
    case simple
}

public struct JiraUser: Codable, Equatable, Sendable {
    public let name: String
    public let displayName: String
    public init(name: String, displayName: String) {
        self.name = name
        self.displayName = displayName
    }
}

public struct BoardSummary: Codable, Identifiable, Hashable, Sendable {
    public let id: Int
    public let name: String
    public let type: String
    public init(id: Int, name: String, type: String) {
        self.id = id
        self.name = name
        self.type = type
    }
}

public struct PriorityRef: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct BoardColumn: Codable, Hashable, Sendable {
    public var name: String
    public var statusIds: [String]
    public init(name: String, statusIds: [String]) {
        self.name = name
        self.statusIds = statusIds
    }
}

public struct IssueTypeRef: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Everything the app needs to know about one board, discovered once during setup.
public struct BoardProfile: Codable, Identifiable, Hashable, Sendable {
    public let id: Int
    public var name: String
    public var type: BoardType
    public var projectKey: String
    public var columns: [BoardColumn]
    public var issueTypes: [IssueTypeRef]
    public var storyPointsField: String?
    public var sprintField: String?
    /// Priorities allowed on this project's create screen, highest first. `nil` for boards saved
    /// before priorities were supported; empty when the project has no priority field.
    public var priorities: [PriorityRef]?

    public init(id: Int, name: String, type: BoardType, projectKey: String,
                columns: [BoardColumn], issueTypes: [IssueTypeRef],
                storyPointsField: String?, sprintField: String?,
                priorities: [PriorityRef]? = nil) {
        self.priorities = priorities
        self.id = id
        self.name = name
        self.type = type
        self.projectKey = projectKey
        self.columns = columns
        self.issueTypes = issueTypes
        self.storyPointsField = storyPointsField
        self.sprintField = sprintField
    }

    public var defaultIssueType: String {
        issueTypes.first(where: { $0.name == "Task" })?.name ?? issueTypes.first?.name ?? "Task"
    }
}

public struct BoardIssue: Identifiable, Hashable, Sendable {
    public var id: String { key }
    public let key: String
    public var summary: String
    public var statusId: String
    public var statusName: String
    public var issueType: String
    public var storyPoints: Double?
    public var activeSprintId: Int?
    public var assignee: String?
    public var priorityId: String?
    public var priorityName: String?

    public init(key: String, summary: String, statusId: String, statusName: String,
                issueType: String, storyPoints: Double? = nil,
                activeSprintId: Int? = nil, assignee: String? = nil,
                priorityId: String? = nil, priorityName: String? = nil) {
        self.priorityId = priorityId
        self.priorityName = priorityName
        self.key = key
        self.summary = summary
        self.statusId = statusId
        self.statusName = statusName
        self.issueType = issueType
        self.storyPoints = storyPoints
        self.activeSprintId = activeSprintId
        self.assignee = assignee
    }
}

public struct JiraTransition: Hashable, Sendable {
    public let id: String
    public let name: String
    public let toStatusId: String
    public let toStatusName: String
    public let hasScreen: Bool
    public init(id: String, name: String, toStatusId: String, toStatusName: String, hasScreen: Bool = false) {
        self.id = id
        self.name = name
        self.toStatusId = toStatusId
        self.toStatusName = toStatusName
        self.hasScreen = hasScreen
    }
}

public struct SprintRef: Hashable, Sendable {
    public let id: Int
    public let name: String
    public let state: String
    public init(id: Int, name: String, state: String) {
        self.id = id
        self.name = name
        self.state = state
    }
    public var isActive: Bool { state.uppercased() == "ACTIVE" }
}

public struct CreatedIssue: Sendable {
    public let key: String
    public let id: String
}

public struct AttachmentUpload: Sendable {
    public let filename: String
    public let mime: String
    public let data: Data
    public init(filename: String, mime: String, data: Data) {
        self.filename = filename
        self.mime = mime
        self.data = data
    }
}

public enum JiraError: LocalizedError, Sendable {
    case unauthorized
    case network(String)
    case http(Int, String, [String])   // status, message, field keys that failed
    case badResponse(String)
    case missing(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Jira rejected the token (401). Create a new Personal Access Token and paste it in Settings."
        case .network(let m): return m
        case .http(let code, let m, _): return m.isEmpty ? "Jira error \(code)" : m
        case .badResponse(let m): return m
        case .missing(let m): return m
        }
    }
}
