import SwiftUI
import ServiceManagement
import Carbon.HIToolbox
import JiraBarCore

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Persisted preferences + secrets (tokens live in the Keychain, everything else in UserDefaults).
@MainActor
final class Settings: ObservableObject {
    private let d = UserDefaults.standard
    private enum Account {
        static let jira = "jira-token"
        static let openRouter = "openrouter-key"
    }

    @Published var baseURLString: String { didSet { d.set(baseURLString, forKey: "baseURL") } }
    @Published private(set) var boards: [BoardProfile] = []
    @Published var activeBoardID: Int? { didSet { d.set(activeBoardID, forKey: "activeBoardID") } }
    @Published var assignToMe: Bool { didSet { d.set(assignToMe, forKey: "assignToMe") } }
    @Published var autoImprove: Bool { didSet { d.set(autoImprove, forKey: "autoImprove") } }
    @Published var copyLinkOnCreate: Bool { didSet { d.set(copyLinkOnCreate, forKey: "copyLink") } }
    @Published var model: String { didSet { d.set(model, forKey: "aiModel") } }
    @Published var aiLanguage: AIOutputLanguage { didSet { d.set(aiLanguage.rawValue, forKey: "aiLanguage") } }
    @Published var showDockIcon: Bool { didSet { d.set(showDockIcon, forKey: "showDock"); onVisibilityChange?() } }
    @Published var showMenuBarIcon: Bool { didSet { d.set(showMenuBarIcon, forKey: "showMenuBar"); onVisibilityChange?() } }
    @Published var hotKeyRegistered = true
    @Published var lastStoryPoints: Double? { didSet { d.set(lastStoryPoints ?? 0, forKey: "lastSP") } }
    @Published private(set) var token: String
    @Published private(set) var aiKey: String
    @Published var me: JiraUser?
    @Published private(set) var freeModels: [OpenRouterModel] = []
    @Published private(set) var launchAtLogin: Bool

    @Published private(set) var hotKeyCode: UInt32
    @Published private(set) var hotKeyMods: UInt32
    @Published private(set) var hotKeyDisplay: String
    var onHotKeyChange: (() -> Void)?
    var onVisibilityChange: (() -> Void)?

    init() {
        let d = UserDefaults.standard
        baseURLString = d.string(forKey: "baseURL") ?? "https://works.digikala.com"
        assignToMe = d.object(forKey: "assignToMe") as? Bool ?? true
        autoImprove = d.object(forKey: "autoImprove") as? Bool ?? true
        copyLinkOnCreate = d.object(forKey: "copyLink") as? Bool ?? true
        model = d.string(forKey: "aiModel") ?? AIService.defaultModel
        aiLanguage = AIOutputLanguage(rawValue: d.string(forKey: "aiLanguage") ?? "") ?? .sameAsInput
        // With many menu bar apps macOS hides the extras, so the Dock icon is on by default as a way back in.
        showDockIcon = d.object(forKey: "showDock") as? Bool ?? true
        showMenuBarIcon = d.object(forKey: "showMenuBar") as? Bool ?? true
        let sp = d.double(forKey: "lastSP")
        lastStoryPoints = sp > 0 ? sp : nil
        token = Keychain.get(Account.jira) ?? ""
        aiKey = Keychain.get(Account.openRouter) ?? ""
        launchAtLogin = SMAppService.mainApp.status == .enabled
        hotKeyCode = d.object(forKey: "hkCode") as? UInt32 ?? UInt32(kVK_ANSI_J)
        hotKeyMods = d.object(forKey: "hkMods") as? UInt32 ?? UInt32(optionKey | cmdKey)
        hotKeyDisplay = d.string(forKey: "hkDisplay") ?? "⌥⌘J"

        if let data = d.data(forKey: "boards"),
           let saved = try? JSONDecoder().decode([BoardProfile].self, from: data) {
            boards = saved
        }
        let savedActive = d.object(forKey: "activeBoardID") as? Int
        activeBoardID = boards.contains(where: { $0.id == savedActive }) ? savedActive : boards.first?.id
        if let name = d.string(forKey: "meName") {
            me = JiraUser(name: name, displayName: d.string(forKey: "meDisplay") ?? name)
        }
    }

    // MARK: - Derived

    var hasToken: Bool { !token.isEmpty }
    var hasAIKey: Bool { !aiKey.isEmpty }
    var activeBoard: BoardProfile? { boards.first(where: { $0.id == activeBoardID }) ?? boards.first }
    var isConfigured: Bool { hasToken && activeBoard != nil }

    var baseURL: URL? { Self.normalizedURL(baseURLString) }

    func makeClient() -> JiraClient? {
        guard hasToken, let url = baseURL else { return nil }
        return JiraClient(baseURL: url, token: token)
    }

    func makeAI() -> AIService? {
        hasAIKey ? AIService(apiKey: aiKey, model: model) : nil
    }

    static func normalizedURL(_ raw: String) -> URL? {
        var s = raw.trimmed
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let u = URL(string: s), u.host != nil else { return nil }
        return u
    }

    var tokenHelpURL: URL? {
        baseURL.flatMap {
            URL(string: $0.absoluteString + "/secure/ViewProfile.jspa?selectedTab=com.atlassian.pats.pats-plugin:jira-user-personal-access-tokens")
        }
    }

    // MARK: - Jira connection

    func connect(token raw: String) async throws {
        let t = raw.trimmed
        guard !t.isEmpty else { throw JiraError.missing("Paste your Personal Access Token first.") }
        guard let base = Self.normalizedURL(baseURLString) else { throw JiraError.missing("The Jira address looks wrong.") }
        let user = try await JiraClient(baseURL: base, token: t).myself()
        Keychain.set(t, for: Account.jira)
        token = t
        baseURLString = base.absoluteString
        setMe(user)
    }

    func disconnect() {
        Keychain.delete(Account.jira)
        token = ""
        me = nil
        d.removeObject(forKey: "meName")
    }

    func refreshIdentity() async {
        guard me == nil, let client = makeClient() else { return }
        if let u = try? await client.myself() { setMe(u) }
    }

    private func setMe(_ u: JiraUser) {
        me = u
        d.set(u.name, forKey: "meName")
        d.set(u.displayName, forKey: "meDisplay")
    }

    // MARK: - Boards

    func addBoard(_ profile: BoardProfile) {
        if let i = boards.firstIndex(where: { $0.id == profile.id }) { boards[i] = profile } else { boards.append(profile) }
        if activeBoardID == nil || boards.count == 1 { activeBoardID = profile.id }
        saveBoards()
    }

    func removeBoard(_ id: Int) {
        boards.removeAll { $0.id == id }
        if activeBoardID == id { activeBoardID = boards.first?.id }
        saveBoards()
    }

    /// Boards saved by an older version lack the priority list; fetch it once in the background.
    func upgradeBoardsIfNeeded() async {
        guard let client = makeClient() else { return }
        for b in boards where b.priorities == nil {
            let summary = BoardSummary(id: b.id, name: b.name, type: b.type.rawValue)
            if let fresh = try? await client.loadProfile(for: summary) { addBoard(fresh) }
        }
    }

    private func saveBoards() {
        if let data = try? JSONEncoder().encode(boards) { d.set(data, forKey: "boards") }
    }

    // MARK: - AI

    func saveAIKey(_ raw: String) {
        let k = raw.trimmed
        if k.isEmpty { Keychain.delete(Account.openRouter) } else { Keychain.set(k, for: Account.openRouter) }
        aiKey = k
    }

    func refreshModels() async {
        if let m = try? await AIService.freeModels(), !m.isEmpty { freeModels = m }
    }

    // MARK: - Shortcut & login item

    func setHotKey(keyCode: UInt16, flags: NSEvent.ModifierFlags, key: String?) {
        var mods: UInt32 = 0
        var label = ""
        if flags.contains(.control) { mods |= UInt32(controlKey); label += "⌃" }
        if flags.contains(.option) { mods |= UInt32(optionKey); label += "⌥" }
        if flags.contains(.shift) { mods |= UInt32(shiftKey); label += "⇧" }
        if flags.contains(.command) { mods |= UInt32(cmdKey); label += "⌘" }
        label += (key ?? "?").uppercased()
        hotKeyCode = UInt32(keyCode)
        hotKeyMods = mods
        hotKeyDisplay = label
        d.set(hotKeyCode, forKey: "hkCode")
        d.set(hotKeyMods, forKey: "hkMods")
        d.set(hotKeyDisplay, forKey: "hkDisplay")
        onHotKeyChange?()
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("JiraBar: launch at login failed: \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

#if DEBUG
extension Settings {
    static let demoPriorities = [
        PriorityRef(id: "1", name: "Highest"), PriorityRef(id: "2", name: "High"),
        PriorityRef(id: "3", name: "Medium"), PriorityRef(id: "4", name: "Low"), PriorityRef(id: "5", name: "Lowest"),
    ]

    /// Fake connected state, used only by the debug snapshot tool.
    func loadDemoData() {
        token = "demo"
        me = JiraUser(name: "me", displayName: "Mohamad Vahedi")
        let dds = BoardProfile(
            id: 95, name: "DDS Kanban Board", type: .kanban, projectKey: "DDS",
            columns: [
                BoardColumn(name: "Backlog", statusIds: ["10108"]),
                BoardColumn(name: "To Do", statusIds: ["10004"]),
                BoardColumn(name: "🟠 Working on it", statusIds: ["3"]),
                BoardColumn(name: "🟣 QC Ready", statusIds: ["10013"]),
                BoardColumn(name: "🔵 Testing", statusIds: ["10406"]),
                BoardColumn(name: "🔴 Rejected", statusIds: ["10107"]),
                BoardColumn(name: "🟢 Done", statusIds: ["10003"]),
            ],
            issueTypes: [IssueTypeRef(id: "10200", name: "Task"), IssueTypeRef(id: "10001", name: "Story"), IssueTypeRef(id: "10106", name: "Bug")],
            storyPointsField: "customfield_10106", sprintField: "customfield_10100",
            priorities: Self.demoPriorities
        )
        let dis = BoardProfile(
            id: 66, name: "DIS Board", type: .scrum, projectKey: "DIS",
            columns: [
                BoardColumn(name: "To Do", statusIds: ["10004"]),
                BoardColumn(name: "In Progress", statusIds: ["3"]),
                BoardColumn(name: "In Review", statusIds: ["10005"]),
                BoardColumn(name: "Blocked", statusIds: ["10102"]),
                BoardColumn(name: "Done", statusIds: ["10003"]),
            ],
            issueTypes: [IssueTypeRef(id: "10200", name: "Task")],
            storyPointsField: "customfield_10106", sprintField: "customfield_10100",
            priorities: Self.demoPriorities
        )
        boards = [dds, dis]
        activeBoardID = 95
    }
}
#endif
