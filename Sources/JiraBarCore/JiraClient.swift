import Foundation

/// Thin async client for Jira Server / Data Center (REST API v2 + Agile 1.0),
/// authenticated with a Personal Access Token (Bearer).
public final class JiraClient: @unchecked Sendable {
    public let baseURL: URL
    private let token: String
    private let session: URLSession

    public init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 25
        cfg.httpShouldSetCookies = false
        cfg.httpCookieStorage = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: cfg)
    }

    public func browseURL(_ key: String) -> URL {
        baseURL.appendingPathComponent("browse").appendingPathComponent(key)
    }

    // MARK: - Transport

    static let queryAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    func url(_ path: String, query: [String: String]) -> URL {
        var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        var base = comps.path
        if base.hasSuffix("/") { base.removeLast() }
        comps.path = base + path
        if !query.isEmpty {
            comps.percentEncodedQuery = query.sorted { $0.key < $1.key }
                .map { k, v in
                    let ev = v.addingPercentEncoding(withAllowedCharacters: Self.queryAllowed) ?? v
                    return "\(k)=\(ev)"
                }
                .joined(separator: "&")
        }
        return comps.url!
    }

    @discardableResult
    func send(_ method: String, _ path: String, query: [String: String] = [:], json: Any? = nil) async throws -> Data {
        var req = URLRequest(url: url(path, query: query))
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("no-check", forHTTPHeaderField: "X-Atlassian-Token")
        if let json {
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return try await perform(req)
    }

    func perform(_ req: URLRequest) async throws -> Data {
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw JiraError.badResponse("No HTTP response from Jira") }
            if (200..<300).contains(http.statusCode) { return data }
            if http.statusCode == 401 { throw JiraError.unauthorized }
            throw Self.httpError(status: http.statusCode, data: data)
        } catch let e as JiraError {
            throw e
        } catch let e as URLError {
            throw JiraError.network(Self.describe(e, host: baseURL.host ?? "Jira"))
        }
    }

    static func describe(_ e: URLError, host: String) -> String {
        switch e.code {
        case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .timedOut,
             .networkConnectionLost, .dnsLookupFailed, .secureConnectionFailed, .internationalRoamingOff:
            return "Can't reach \(host). Is the VPN connected?"
        default:
            return e.localizedDescription
        }
    }

    static func httpError(status: Int, data: Data) -> JiraError {
        var messages: [String] = []
        var fieldKeys: [String] = []
        if let json = try? JSONValue.parse(data) {
            if let arr = json["errorMessages"]?.array { messages += arr.compactMap { $0.string } }
            if case .object(let errs)? = json["errors"] {
                for (k, v) in errs.sorted(by: { $0.key < $1.key }) {
                    fieldKeys.append(k)
                    messages.append("\(k): \(v.string ?? "")")
                }
            }
            if messages.isEmpty, let m = json["message"]?.string { messages.append(m) }
        }
        return .http(status, messages.joined(separator: " · "), fieldKeys)
    }

    func json(_ data: Data) throws -> JSONValue {
        do { return try JSONValue.parse(data) }
        catch {
            throw JiraError.badResponse("Unexpected (non-JSON) response from \(baseURL.host ?? "Jira"). Is the VPN connected?")
        }
    }

    // MARK: - Account & boards

    public func myself() async throws -> JiraUser {
        let j = try json(try await send("GET", "/rest/api/2/myself"))
        guard let name = j["name"]?.string ?? j["key"]?.string else {
            throw JiraError.badResponse("Couldn't read the current user from Jira")
        }
        return JiraUser(name: name, displayName: j["displayName"]?.string ?? name)
    }

    public func searchBoards(_ query: String) async throws -> [BoardSummary] {
        var q = ["maxResults": "50"]
        if !query.trimmingCharacters(in: .whitespaces).isEmpty { q["name"] = query }
        let j = try json(try await send("GET", "/rest/agile/1.0/board", query: q))
        return (j["values"]?.array ?? []).compactMap { v in
            guard let id = v["id"]?.int, let name = v["name"]?.string else { return nil }
            return BoardSummary(id: id, name: name, type: v["type"]?.string ?? "")
        }
    }

    /// Discovers columns, project, issue types, and custom field ids for a board.
    public func loadProfile(for board: BoardSummary) async throws -> BoardProfile {
        async let cfgData = send("GET", "/rest/agile/1.0/board/\(board.id)/configuration")
        async let projData = send("GET", "/rest/agile/1.0/board/\(board.id)/project")
        async let fieldData = send("GET", "/rest/api/2/field")

        let cfg = try json(try await cfgData)
        let proj = try json(try await projData)
        let fields = try json(try await fieldData)

        guard let projectKey = proj["values"]?.array?.first?["key"]?.string else {
            throw JiraError.missing("Couldn't determine which project this board belongs to.")
        }

        let columns: [BoardColumn] = (cfg["columnConfig"]?["columns"]?.array ?? []).map { c in
            BoardColumn(
                name: c["name"]?.string ?? "?",
                statusIds: (c["statuses"]?.array ?? []).compactMap { $0["id"]?.string }
            )
        }
        guard !columns.isEmpty else { throw JiraError.missing("This board has no columns configured.") }

        let type = BoardType(rawValue: cfg["type"]?.string ?? board.type) ?? .kanban

        var spField: String?
        var sprintField: String?
        for f in fields.array ?? [] {
            let name = (f["name"]?.string ?? "").lowercased()
            let custom = f["schema"]?["custom"]?.string ?? ""
            if name == "story points", spField == nil { spField = f["id"]?.string }
            if custom.contains("gh-sprint"), sprintField == nil { sprintField = f["id"]?.string }
        }
        if spField == nil { spField = cfg["estimation"]?["field"]?["fieldId"]?.string }

        let types = try await issueTypes(projectKey: projectKey)
        let defaultType = types.first(where: { $0.name == "Task" }) ?? types[0]
        let prios = await priorities(projectKey: projectKey, issueTypeId: defaultType.id)

        return BoardProfile(
            id: board.id, name: board.name, type: type, projectKey: projectKey,
            columns: columns, issueTypes: types,
            storyPointsField: spField, sprintField: sprintField,
            priorities: prios
        )
    }

    /// Priorities allowed on the create screen (project-specific, highest first). Empty when the
    /// project has no priority field there.
    func priorities(projectKey: String, issueTypeId: String) async -> [PriorityRef] {
        guard !issueTypeId.isEmpty,
              let data = try? await send("GET", "/rest/api/2/issue/createmeta/\(projectKey)/issuetypes/\(issueTypeId)",
                                         query: ["maxResults": "100"]),
              let j = try? json(data) else { return [] }
        let field = (j["values"]?.array ?? []).first { $0["fieldId"]?.string == "priority" }
        return (field?["allowedValues"]?.array ?? []).compactMap { v in
            guard let id = v["id"]?.string, let name = v["name"]?.string else { return nil }
            return PriorityRef(id: id, name: name)
        }
    }

    func issueTypes(projectKey: String) async throws -> [IssueTypeRef] {
        let j = try json(try await send("GET", "/rest/api/2/issue/createmeta/\(projectKey)/issuetypes"))
        let arr = j["values"]?.array ?? j["issueTypes"]?.array ?? []
        let types: [IssueTypeRef] = arr.compactMap { v in
            guard let id = v["id"]?.string, let name = v["name"]?.string else { return nil }
            if case .bool(true)? = v["subtask"] { return nil }
            if name.lowercased() == "epic" { return nil }
            return IssueTypeRef(id: id, name: name)
        }
        return types.isEmpty ? [IssueTypeRef(id: "", name: "Task")] : types
    }

    public func activeSprint(boardId: Int) async throws -> SprintRef? {
        do {
            let j = try json(try await send("GET", "/rest/agile/1.0/board/\(boardId)/sprint", query: ["state": "active"]))
            guard let v = j["values"]?.array?.first, let id = v["id"]?.int else { return nil }
            return SprintRef(id: id, name: v["name"]?.string ?? "Sprint", state: "ACTIVE")
        } catch JiraError.http(let code, _, _) where code == 400 || code == 404 {
            return nil   // Kanban boards have no sprints
        }
    }

    // MARK: - Creating & editing

    /// Creates the issue. Optional fields that aren't on the project's create screen
    /// are dropped and applied with a follow-up edit instead of failing the whole request.
    public func createIssue(profile: BoardProfile, issueType: String, summary: String,
                            description: String?, storyPoints: Double?,
                            assigneeName: String?, priorityId: String? = nil) async throws -> CreatedIssue {
        var required: [String: Any] = [
            "project": ["key": profile.projectKey],
            "issuetype": ["name": issueType],
            "summary": summary,
        ]
        var optional: [String: Any] = [:]
        if let d = description, !d.isEmpty { optional["description"] = d }
        if let sp = storyPoints, let f = profile.storyPointsField { optional[f] = sp }
        if let a = assigneeName { optional["assignee"] = ["name": a] }
        if let p = priorityId { optional["priority"] = ["id": p] }

        var fields = required.merging(optional) { $1 }
        var deferred: [String: Any] = [:]

        func post(_ fields: [String: Any]) async throws -> JSONValue {
            try json(try await send("POST", "/rest/api/2/issue", json: ["fields": fields]))
        }

        let created: JSONValue
        do {
            created = try await post(fields)
        } catch JiraError.http(let code, _, let keys) where code == 400 && keys.contains(where: { optional[$0] != nil }) {
            for k in keys where optional[k] != nil {
                deferred[k] = optional[k]
                fields.removeValue(forKey: k)
            }
            created = try await post(fields)
        }
        required.removeAll()

        guard let key = created["key"]?.string, let id = created["id"]?.string else {
            throw JiraError.badResponse("Jira created the issue but returned no key")
        }

        for (k, v) in deferred {
            if k == "assignee", let a = assigneeName {
                _ = try? await send("PUT", "/rest/api/2/issue/\(key)/assignee", json: ["name": a])
            } else {
                _ = try? await send("PUT", "/rest/api/2/issue/\(key)", json: ["fields": [k: v]])
            }
        }
        return CreatedIssue(key: key, id: id)
    }

    public func updateIssue(key: String, summary: String? = nil, description: String? = nil) async throws {
        var fields: [String: Any] = [:]
        if let summary { fields["summary"] = summary }
        if let description { fields["description"] = description }
        guard !fields.isEmpty else { return }
        try await send("PUT", "/rest/api/2/issue/\(key)", json: ["fields": fields])
    }

    public func setPriority(key: String, priorityId: String) async throws {
        try await send("PUT", "/rest/api/2/issue/\(key)", json: ["fields": ["priority": ["id": priorityId]]])
    }

    public func currentStatus(key: String) async throws -> (id: String, name: String) {
        let j = try json(try await send("GET", "/rest/api/2/issue/\(key)", query: ["fields": "status"]))
        guard let id = j["fields"]?["status"]?["id"]?.string else { throw JiraError.badResponse("No status on \(key)") }
        return (id, j["fields"]?["status"]?["name"]?.string ?? "")
    }

    /// Uploads files and returns the filenames Jira stored them under.
    public func uploadAttachments(key: String, files: [AttachmentUpload]) async throws -> [String] {
        guard !files.isEmpty else { return [] }
        let boundary = "JiraBar-\(UUID().uuidString)"
        var body = Data()
        for f in files {
            let safeName = f.filename.replacingOccurrences(of: "\"", with: "_")
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: \(f.mime)\r\n\r\n".data(using: .utf8)!)
            body.append(f.data)
            body.append("\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: url("/rest/api/2/issue/\(key)/attachments", query: [:]))
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("no-check", forHTTPHeaderField: "X-Atlassian-Token")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let j = try json(try await perform(req))
        return (j.array ?? []).compactMap { $0["filename"]?.string }
    }

    // MARK: - Board

    public func boardIssues(profile: BoardProfile, scope: BoardScope) async throws -> [BoardIssue] {
        var fields = ["summary", "status", "issuetype", "assignee", "priority"]
        if let sp = profile.storyPointsField { fields.append(sp) }
        if let sf = profile.sprintField { fields.append(sf) }
        let data = try await send(
            "GET", "/rest/agile/1.0/board/\(profile.id)/issue",
            query: [
                "jql": BoardLogic.jql(type: profile.type, scope: scope),
                "fields": fields.joined(separator: ","),
                "maxResults": "100",
            ]
        )
        let j = try json(data)
        return (j["issues"]?.array ?? []).compactMap { Self.parseIssue($0, profile: profile) }
    }

    static func parseIssue(_ v: JSONValue, profile: BoardProfile) -> BoardIssue? {
        guard let key = v["key"]?.string, let f = v["fields"] else { return nil }
        let sprints = profile.sprintField.map { SprintParser.parse(f[$0]) } ?? []
        return BoardIssue(
            key: key,
            summary: f["summary"]?.string ?? key,
            statusId: f["status"]?["id"]?.string ?? "",
            statusName: f["status"]?["name"]?.string ?? "",
            issueType: f["issuetype"]?["name"]?.string ?? "",
            storyPoints: profile.storyPointsField.flatMap { f[$0]?.double },
            activeSprintId: sprints.first(where: { $0.isActive })?.id,
            assignee: f["assignee"]?["displayName"]?.string,
            priorityId: f["priority"]?["id"]?.string,
            priorityName: f["priority"]?["name"]?.string
        )
    }

    public func transitions(key: String) async throws -> [JiraTransition] {
        let j = try json(try await send("GET", "/rest/api/2/issue/\(key)/transitions"))
        return (j["transitions"]?.array ?? []).compactMap { t in
            guard let id = t["id"]?.string, let toId = t["to"]?["id"]?.string else { return nil }
            var screen = false
            if case .bool(true)? = t["hasScreen"] { screen = true }
            return JiraTransition(
                id: id, name: t["name"]?.string ?? "",
                toStatusId: toId, toStatusName: t["to"]?["name"]?.string ?? "",
                hasScreen: screen
            )
        }
    }

    public func doTransition(key: String, transitionId: String) async throws {
        try await send("POST", "/rest/api/2/issue/\(key)/transitions", json: ["transition": ["id": transitionId]])
    }

    public func addToSprint(sprintId: Int, key: String) async throws {
        try await send("POST", "/rest/agile/1.0/sprint/\(sprintId)/issue", json: ["issues": [key]])
    }

    public func moveToBacklog(key: String) async throws {
        try await send("POST", "/rest/agile/1.0/backlog", json: ["issues": [key]])
    }
}
