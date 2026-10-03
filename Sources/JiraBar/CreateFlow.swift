import SwiftUI
import JiraBarCore

struct CreatedInfo: Equatable {
    let key: String
    let url: URL
    let createdAt: Date
    var title: String
}

enum AIState: Equatable {
    case off(String)
    case working
    case done(title: String, summary: String)
    case failed(String)
    case undone
}

enum CreateField { case title, points, priority, notes }

/// Draft + the "create fast, polish in the background" pipeline.
@MainActor
final class CreateFlow: ObservableObject {
    enum Phase: Equatable { case compose, creating, created }

    @Published var title: String { didSet { UserDefaults.standard.set(title, forKey: "draftTitle") } }
    @Published var notes: String { didSet { UserDefaults.standard.set(notes, forKey: "draftNotes") } }
    @Published var storyPoints: Double?
    @Published var issueType: String = ""
    /// nil = leave it to Jira's default (Medium).
    @Published var priorityId: String?
    @Published var attachments: [DraftAttachment] = []
    @Published var detailsOpen = false
    @Published private(set) var phase: Phase = .compose
    @Published var error: String?
    @Published private(set) var created: CreatedInfo?
    @Published private(set) var ai: AIState = .off("")
    @Published private(set) var attachmentNote: String?
    @Published private(set) var copied = false
    /// The view mirrors its focus here; the key monitor asks for focus changes through `focusRequest`.
    @Published var focusRequest: CreateField?
    var currentField: CreateField?

    private let settings: Settings
    private let board: BoardFlow

    /// What an AI run needs, kept so it can be retried or undone.
    private struct Job {
        let client: JiraClient
        let profile: BoardProfile
        let key: String
        let rawTitle: String
        let notes: String
        let attachments: [DraftAttachment]
        var uploadedNames: [String] = []
        var rawDescription: String = ""
    }
    private var job: Job?

    init(settings: Settings, board: BoardFlow) {
        self.settings = settings
        self.board = board
        title = UserDefaults.standard.string(forKey: "draftTitle") ?? ""
        notes = UserDefaults.standard.string(forKey: "draftNotes") ?? ""
        storyPoints = settings.lastStoryPoints
        detailsOpen = !notes.isEmpty
    }

    var effectiveIssueType: String {
        guard let b = settings.activeBoard else { return "Task" }
        return b.issueTypes.contains(where: { $0.name == issueType }) ? issueType : b.defaultIssueType
    }

    var priorities: [PriorityRef] { settings.activeBoard?.priorities ?? [] }

    /// ⌥↑ / ⌥↓ (and ↑ ↓ ← → on the priority control). Starts from Medium when nothing is chosen yet.
    func bumpPriority(raise: Bool) {
        let list = priorities
        guard !list.isEmpty else { return }
        let current = priorityId.flatMap { id in list.firstIndex(where: { $0.id == id }) }
            ?? list.firstIndex(where: { $0.name == "Medium" })
            ?? list.count / 2
        priorityId = list[min(max(current + (raise ? -1 : 1), 0), list.count - 1)].id
    }

    var canSubmit: Bool { !title.trimmed.isEmpty && phase == .compose }

    /// Tab / Shift-Tab through title → points → description. macOS only tabs between text fields
    /// unless "Full Keyboard Access" is on, so this is handled explicitly.
    func cycleFocus(forward: Bool) {
        var order: [CreateField] = [.title, .points]
        if !priorities.isEmpty { order.append(.priority) }
        if detailsOpen { order.append(.notes) }
        let i = order.firstIndex(of: currentField ?? .title) ?? 0
        focusRequest = order[(i + (forward ? 1 : order.count - 1)) % order.count]
    }

    // MARK: - Attachments

    func add(_ items: [DraftAttachment]) {
        guard !items.isEmpty else { return }
        attachments.append(contentsOf: items)
        detailsOpen = true
    }

    func remove(_ id: UUID) {
        attachments.removeAll { $0.id == id }
    }

    // MARK: - Create

    func submit() {
        guard phase == .compose else { return }
        let rawTitle = title.trimmed
        guard !rawTitle.isEmpty else { error = "Write a title first."; return }
        guard let profile = settings.activeBoard, let client = settings.makeClient() else {
            error = "Finish the setup in Settings first."
            return
        }
        error = nil
        phase = .creating

        let rawNotes = notes.trimmed
        let atts = attachments
        let sp = storyPoints
        let type = effectiveIssueType
        let assignee = settings.assignToMe ? settings.me?.name : nil
        let priority = priorityId

        Task {
            do {
                let issue = try await client.createIssue(
                    profile: profile, issueType: type, summary: rawTitle,
                    description: atts.isEmpty && !rawNotes.isEmpty ? rawNotes : nil,
                    storyPoints: sp, assigneeName: assignee, priorityId: priority
                )
                let url = client.browseURL(issue.key)
                if settings.copyLinkOnCreate { copyToPasteboard(url.absoluteString) }
                if let sp { settings.lastStoryPoints = sp }

                created = CreatedInfo(key: issue.key, url: url, createdAt: Date(), title: rawTitle)
                ai = .off("")
                attachmentNote = nil
                copied = settings.copyLinkOnCreate
                phase = .created
                title = ""
                notes = ""
                priorityId = nil
                attachments = []
                detailsOpen = false

                job = Job(client: client, profile: profile, key: issue.key,
                          rawTitle: rawTitle, notes: rawNotes, attachments: atts)
                await postProcess()
            } catch {
                self.error = error.localizedDescription
                phase = .compose
            }
        }
    }

    // MARK: - Background work after the task exists

    private func postProcess() async {
        guard var job else { return }
        let key = job.key

        // Kanban: new tasks belong in the first column (Backlog).
        if job.profile.type == .kanban { await moveToFirstColumn(job) }

        if !job.attachments.isEmpty {
            do {
                job.uploadedNames = try await job.client.uploadAttachments(
                    key: key,
                    files: job.attachments.map { AttachmentUpload(filename: $0.filename, mime: $0.mime, data: $0.data) }
                )
            } catch {
                attachmentNote = "Screenshots weren't uploaded: \(error.localizedDescription)"
            }
        }
        job.rawDescription = WikiMarkup.plain(notes: job.notes, images: job.uploadedNames)
        self.job = job

        // If there were attachments, the description wasn't sent at creation — add it now.
        if !job.attachments.isEmpty, !job.rawDescription.isEmpty {
            try? await job.client.updateIssue(key: key, description: job.rawDescription)
        }
        await runAI()
    }

    private func moveToFirstColumn(_ job: Job) async {
        guard let first = job.profile.columns.first,
              let status = try? await job.client.currentStatus(key: job.key),
              !first.statusIds.contains(status.id),
              let transitions = try? await job.client.transitions(key: job.key),
              let t = transitions.first(where: { first.statusIds.contains($0.toStatusId) }) else { return }
        try? await job.client.doTransition(key: job.key, transitionId: t.id)
    }

    private func runAI() async {
        guard let job else { return }
        guard settings.autoImprove else { ai = .off("AI polish is turned off."); return }
        guard let service = settings.makeAI() else {
            ai = .off("Add an OpenRouter key in Settings to polish tasks with AI.")
            return
        }
        ai = .working
        do {
            let images = job.attachments.compactMap { ImageTools.jpegForAI($0.data) }
            let (ticket, _) = try await service.improve(
                title: job.rawTitle, notes: job.notes, images: images, titleHints: board.recentTitles,
                language: settings.aiLanguage
            )
            let description = WikiMarkup.description(ticket, images: job.uploadedNames, originalNotes: job.notes)
            try await job.client.updateIssue(key: job.key, summary: ticket.title, description: description)
            created?.title = ticket.title
            ai = .done(title: ticket.title, summary: ticket.context)
        } catch {
            ai = .failed(error.localizedDescription)
        }
    }

    func retryAI() {
        guard case .failed = ai else { return }
        Task { await runAI() }
    }

    func undoAI() {
        guard let job, case .done = ai else { return }
        Task {
            do {
                try await job.client.updateIssue(key: job.key, summary: job.rawTitle, description: job.rawDescription)
                created?.title = job.rawTitle
                ai = .undone
            } catch {
                ai = .failed("Couldn't restore the original text: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Result actions

    func copyLink() {
        guard let created else { return }
        copyToPasteboard(created.url.absoluteString)
        copied = true
    }

    func openCreated() {
        guard let created else { return }
        NSWorkspace.shared.open(created.url)
    }

    func reset() {
        phase = .compose
        created = nil
        ai = .off("")
        attachmentNote = nil
        copied = false
        job = nil
        error = nil
    }

    private func copyToPasteboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

#if DEBUG
extension CreateFlow {
    func loadDemoDraft(persian: Bool = false) {
        title = persian ? "رفع باگ نمایش تعداد سبد خرید در هدر" : "fix cart badge not updating"
        notes = persian ? "بعد از افزودن کالا از صفحه‌ی محصول (PDP) عدد سبد آپدیت نمیشه و تا رفرش همون عدد قبلی می‌مونه."
                        : "Happens after adding an item from the PDP. Badge stays at the old count until reload."
        storyPoints = 3
        priorityId = "2"
        detailsOpen = true
    }

    func loadDemoCreated() {
        created = CreatedInfo(
            key: "DDS-662",
            url: URL(string: "https://jira.example.com/browse/DDS-662")!,
            createdAt: Date(),
            title: "Fix cart badge count not updating after adding an item"
        )
        ai = .done(title: "Fix cart badge count not updating after adding an item",
                   summary: "The cart badge in the header keeps showing the previous item count after a product is added from the PDP.")
        copied = true
        phase = .created
    }
}
#endif

#if DEBUG
extension CreateFlow {
    func loadDemoCreatedPersian() {
        created = CreatedInfo(
            key: "DDS-663",
            url: URL(string: "https://jira.example.com/browse/DDS-663")!,
            createdAt: Date(),
            title: "رفع باگ نمایش تعداد سبد خرید در هدر"
        )
        ai = .done(title: "رفع باگ نمایش تعداد سبد خرید در هدر",
                   summary: "بعد از افزودن کالا از صفحه‌ی محصول، عدد سبد خرید در هدر به‌روز نمی‌شود و تا رفرش همان عدد قبلی نمایش داده می‌شود.")
        copied = true
        phase = .created
    }
}
#endif
