import SwiftUI
import JiraBarCore

/// Doubles as the first-run onboarding: connect Jira → pick boards → (optional) AI key.
struct SettingsView: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var host: PanelHost
    @EnvironmentObject var board: BoardFlow

    @FocusState private var tokenFocused: Bool
    @State private var tokenInput = ""
    @State private var changingToken = false
    @State private var connecting = false
    @State private var connectError: String?

    @State private var query = ""
    @State private var results: [BoardSummary] = []
    @State private var searching = false
    @State private var addingID: Int?
    @State private var boardError: String?

    @State private var aiKeyInput = ""
    @State private var aiStatus: String?
    @State private var aiChecking = false

    private var onboarding: Bool { !settings.isConfigured }
    private var connected: Bool { settings.hasToken && settings.me != nil && !changingToken }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if onboarding { welcome }
                jiraCard
                if settings.hasToken {
                    boardsCard
                    aiCard
                    generalCard
                }
                footer
            }
            .padding(18)
        }
        .frame(maxHeight: 540)
        .onAppear {
            if settings.hasToken, settings.freeModels.isEmpty { Task { await settings.refreshModels() } }
            if !connected { DispatchQueue.main.async { tokenFocused = true } }
        }
    }

    // MARK: - Sections

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Create Jira tasks in seconds").font(.system(size: 18, weight: .semibold))
            Text("Connect your Jira, pick your board, and press \(settings.hotKeyDisplay) from anywhere.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
        }
    }

    private var jiraCard: some View {
        Card(title: "1 · Jira") {
            VStack(alignment: .leading, spacing: 8) {
                LabeledField(label: "Address") {
                    TextField("https://works.digikala.com", text: $settings.baseURLString)
                        .textFieldStyle(.roundedBorder)
                        .disabled(connected)
                }
                if connected, let me = settings.me {
                    HStack {
                        Label("Connected as \(me.displayName)", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green).font(.system(size: 13))
                        Spacer()
                        Button("Change token") { changingToken = true; tokenInput = "" }.controlSize(.small)
                    }
                } else {
                    LabeledField(label: "Token") {
                        SecureField("Personal Access Token", text: $tokenInput)
                            .textFieldStyle(.roundedBorder)
                            .focused($tokenFocused)
                            .onSubmit(connect)
                    }
                    HStack(spacing: 10) {
                        Button(action: connect) {
                            HStack(spacing: 6) {
                                if connecting { ProgressView().controlSize(.small) }
                                Text("Connect")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(connecting || tokenInput.trimmed.isEmpty)
                        if let url = settings.tokenHelpURL {
                            Button("Create a token in Jira ↗") { NSWorkspace.shared.open(url) }
                                .buttonStyle(.link).font(.system(size: 12))
                        }
                        if changingToken { Button("Cancel") { changingToken = false }.controlSize(.small) }
                    }
                    Text("The token is stored in your Mac's Keychain and only sent to the address above.")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                if let e = connectError {
                    Label(e, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var boardsCard: some View {
        Card(title: "2 · Boards") {
            VStack(alignment: .leading, spacing: 10) {
                if settings.boards.isEmpty {
                    Text("Search for your team's board and add it. You can add several and switch from the header.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ForEach(settings.boards) { b in
                    HStack(spacing: 8) {
                        Button {
                            settings.activeBoardID = b.id
                        } label: {
                            Image(systemName: settings.activeBoard?.id == b.id ? "largecircle.fill.circle" : "circle")
                        }
                        .buttonStyle(.plain)
                        .help("Use as default")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(b.name).font(.system(size: 13, weight: .medium))
                            Text("\(b.projectKey) · \(b.type.rawValue) · new tasks land in \(b.type == .scrum ? "the backlog" : "“\(b.columns.first?.name ?? "")”")")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            settings.removeBoard(b.id)
                        } label: {
                            Image(systemName: "trash").font(.system(size: 11))
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }

                HStack {
                    TextField("Search boards (e.g. DDS, DIS)", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(search)
                    Button(action: search) {
                        if searching { ProgressView().controlSize(.small) } else { Text("Search") }
                    }
                    .disabled(searching)
                }
                ForEach(results.filter { r in !settings.boards.contains(where: { $0.id == r.id }) }.prefix(8)) { r in
                    HStack {
                        Text(r.name).font(.system(size: 13))
                        Text(r.type).font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            add(r)
                        } label: {
                            if addingID == r.id { ProgressView().controlSize(.small) } else { Text("Add") }
                        }
                        .controlSize(.small)
                        .disabled(addingID != nil)
                    }
                }
                if let e = boardError {
                    Label(e, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var aiCard: some View {
        Card(title: "3 · AI polish (optional)") {
            VStack(alignment: .leading, spacing: 8) {
                Text("After a task is created, a free OpenRouter model rewrites the title and writes a description.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                HStack {
                    SecureField(settings.hasAIKey ? "Key saved — paste a new one to replace" : "OpenRouter API key (sk-or-…)", text: $aiKeyInput)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(saveAIKey)
                    Button(action: saveAIKey) {
                        if aiChecking { ProgressView().controlSize(.small) } else { Text("Save") }
                    }
                    .disabled(aiKeyInput.trimmed.isEmpty || aiChecking)
                    Button("Get a free key ↗") { NSWorkspace.shared.open(URL(string: "https://openrouter.ai/keys")!) }
                        .buttonStyle(.link).font(.system(size: 12))
                }
                if let s = aiStatus {
                    Text(s).font(.system(size: 12)).foregroundStyle(s.hasPrefix("✓") ? Color.green : Color.orange)
                }
                if settings.hasAIKey {
                    HStack {
                        Text("Write in").font(.system(size: 12)).foregroundStyle(.secondary)
                        Picker("", selection: $settings.aiLanguage) {
                            Text("Same language as my title (فارسی / English)").tag(AIOutputLanguage.sameAsInput)
                            Text("Always English").tag(AIOutputLanguage.english)
                        }
                        .labelsHidden()
                    }
                    HStack {
                        Text("Model").font(.system(size: 12)).foregroundStyle(.secondary)
                        Picker("", selection: $settings.model) {
                            Text("Auto — OpenRouter picks a free model").tag(AIService.defaultModel)
                            ForEach(settings.freeModels.filter { $0.id != AIService.defaultModel }) { m in
                                Text(m.name + (m.vision ? "  · sees images" : "")).tag(m.id)
                            }
                            if !settings.freeModels.contains(where: { $0.id == settings.model }) && settings.model != AIService.defaultModel {
                                Text(settings.model).tag(settings.model)
                            }
                        }
                        .labelsHidden()
                        Button {
                            Task { await settings.refreshModels() }
                        } label: { Image(systemName: "arrow.clockwise") }
                        .controlSize(.small)
                        .help("Reload the list of free models")
                    }
                    Toggle("Polish every new task automatically", isOn: $settings.autoImprove)
                        .toggleStyle(.switch).controlSize(.small)
                }
                Text("Free models must be enabled in openrouter.ai/settings/privacy (“free endpoints”). Task text and screenshots are sent to OpenRouter.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var generalCard: some View {
        Card(title: "General") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Shortcut").font(.system(size: 13))
                    Spacer()
                    Text(settings.hotKeyRegistered ? "active" : "in use by another app, pick a different one")
                        .font(.system(size: 11))
                        .foregroundStyle(settings.hotKeyRegistered ? Color.green : Color.orange)
                    ShortcutRecorder()
                }
                Toggle("Show icon in the Dock", isOn: $settings.showDockIcon)
                Toggle("Show icon in the menu bar", isOn: $settings.showMenuBarIcon)
                Text("Can't see the menu bar icon? With many menu bar apps macOS hides the extra ones (especially around the notch). The shortcut, the Dock icon, or opening JiraBar from Spotlight always bring this window back.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Assign new tasks to me", isOn: $settings.assignToMe)
                Toggle("Copy the link when a task is created", isOn: $settings.copyLinkOnCreate)
                Toggle("Open at login", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.setLaunchAtLogin($0) }
                ))
            }
            .toggleStyle(.switch).controlSize(.small)
            .font(.system(size: 13))
        }
    }

    private var footer: some View {
        HStack {
            Button("Quit JiraBar") { NSApp.terminate(nil) }.controlSize(.small)
            Spacer()
            if settings.isConfigured {
                Button("Done") { host.showSettings = false }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Text(settings.hasToken ? "Add a board to finish." : "Connect Jira to start.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Actions

    private func connect() {
        guard !connecting, !tokenInput.trimmed.isEmpty else { return }
        connecting = true
        connectError = nil
        Task {
            do {
                try await settings.connect(token: tokenInput)
                tokenInput = ""
                changingToken = false
                search()   // show boards right away
            } catch {
                connectError = error.localizedDescription
            }
            connecting = false
        }
    }

    private func search() {
        guard let client = settings.makeClient() else { return }
        searching = true
        boardError = nil
        Task {
            do { results = try await client.searchBoards(query) }
            catch { boardError = error.localizedDescription }
            searching = false
        }
    }

    private func add(_ summary: BoardSummary) {
        guard let client = settings.makeClient() else { return }
        addingID = summary.id
        boardError = nil
        Task {
            do {
                settings.addBoard(try await client.loadProfile(for: summary))
                board.refresh()
            } catch {
                boardError = "Couldn't load “\(summary.name)”: \(error.localizedDescription)"
            }
            addingID = nil
        }
    }

    private func saveAIKey() {
        let key = aiKeyInput.trimmed
        guard !key.isEmpty else { return }
        aiChecking = true
        aiStatus = nil
        Task {
            do {
                try await AIService(apiKey: key, model: settings.model).validateKey()
                settings.saveAIKey(key)
                aiKeyInput = ""
                aiStatus = "✓ Key saved"
                await settings.refreshModels()
            } catch {
                aiStatus = error.localizedDescription
            }
            aiChecking = false
        }
    }
}

// MARK: - Small building blocks

struct Card<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(.secondary)
                .tracking(0.4)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 11))
    }
}

struct LabeledField<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
            content
        }
    }
}

struct ShortcutRecorder: View {
    @EnvironmentObject var settings: Settings
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(recording ? "Press the new shortcut…" : settings.hotKeyDisplay) {
            recording ? stop() : start()
        }
        .controlSize(.small)
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop(); return nil }               // Esc cancels
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !mods.isEmpty else { return nil }                      // need at least one modifier
            settings.setHotKey(keyCode: event.keyCode, flags: mods, key: event.charactersIgnoringModifiers)
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }
}
