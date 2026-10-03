import SwiftUI
import UniformTypeIdentifiers
import JiraBarCore

struct CreateView: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var flow: CreateFlow
    @EnvironmentObject var host: PanelHost

    @FocusState private var focus: CreateField?
    @State private var dropTargeted = false
    @State private var digitBuffer = ""
    @State private var lastDigitAt = Date.distantPast

    static let pointOptions: [Double] = [1, 2, 3, 5, 8, 13]

    var body: some View {
        Group {
            if flow.phase == .created {
                CreatedView()
            } else {
                compose
            }
        }
        .onAppear { focusTitle() }
        .onChange(of: host.showCount) { _, _ in focusTitle() }
        .onChange(of: flow.phase) { _, p in if p == .compose { focusTitle() } }
        .onChange(of: focus) { _, f in flow.currentField = f }
        .onChange(of: flow.focusRequest) { _, r in
            guard let r else { return }
            focus = r
            flow.focusRequest = nil
        }
    }

    private func focusTitle() {
        guard flow.phase == .compose else { return }
        DispatchQueue.main.async { focus = .title }
    }

    // MARK: - Compose

    private var compose: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("What needs to be done?", text: $flow.title)
                .textFieldStyle(.plain)
                .font(.system(size: 21, weight: .medium))
                .multilineTextAlignment(TextAlign.multiline(flow.title))
                .focused($focus, equals: .title)
                .onSubmit { flow.submit() }
                .disabled(flow.phase == .creating)

            HStack(spacing: 12) {
                pointsRow
                priorityRow
                Spacer(minLength: 0)
            }

            if flow.detailsOpen {
                details
            } else {
                Button {
                    flow.detailsOpen = true
                    DispatchQueue.main.async { focus = .notes }
                } label: {
                    HStack(spacing: 6) {
                        Label("Description or screenshots", systemImage: "plus")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text("⌘D").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }

            if let e = flow.error {
                Label(e, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            footer

            // Hidden shortcut carriers.
            Button("") {
                flow.detailsOpen.toggle()
                if flow.detailsOpen { DispatchQueue.main.async { focus = .notes } }
            }
            .keyboardShortcut("d", modifiers: .command)
            .frame(width: 0, height: 0).opacity(0).allowsHitTesting(false)

            Group {
                Button("") { flow.bumpPriority(raise: true) }.keyboardShortcut(.upArrow, modifiers: .option)
                Button("") { flow.bumpPriority(raise: false) }.keyboardShortcut(.downArrow, modifiers: .option)
            }
            .frame(width: 0, height: 0).opacity(0).allowsHitTesting(false)
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted, perform: handleDrop)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .background(Color.accentColor.opacity(0.06))
                    .overlay(Label("Drop to attach", systemImage: "photo.badge.plus").foregroundStyle(Color.accentColor))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Story points

    private var pointsRow: some View {
        HStack(spacing: 5) {
            Text("Points")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.trailing, 2)
            ForEach(Self.pointOptions, id: \.self) { p in
                Button {
                    flow.storyPoints = flow.storyPoints == p ? nil : p
                } label: {
                    Text(Self.label(p))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .frame(minWidth: 22)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            flow.storyPoints == p ? Color.accentColor : Color.primary.opacity(0.08),
                            in: Capsule()
                        )
                        .foregroundStyle(flow.storyPoints == p ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(focus == .points ? Color.accentColor.opacity(0.8) : .clear, lineWidth: 1.5)
        )
        .focusable()
        .focused($focus, equals: .points)
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in handlePointsKey(press) }
        .help("Tab here, then type 1 2 3 5 8 (or 13) — Return creates")
    }

    private static func label(_ p: Double) -> String {
        p == p.rounded() ? String(Int(p)) : String(p)
    }

    private func handlePointsKey(_ press: KeyPress) -> KeyPress.Result {
        if press.modifiers.contains(.command) || press.modifiers.contains(.control) { return .ignored }
        switch press.key {
        case .return:
            flow.submit()
            return .handled
        case .delete, .deleteForward:
            flow.storyPoints = nil
            return .handled
        case .leftArrow, .rightArrow:
            let opts = Self.pointOptions
            let step = press.key == .rightArrow ? 1 : -1
            if let cur = flow.storyPoints, let i = opts.firstIndex(of: cur) {
                flow.storyPoints = opts[min(max(i + step, 0), opts.count - 1)]
            } else {
                flow.storyPoints = step > 0 ? opts.first : opts.last
            }
            return .handled
        default:
            break
        }
        // wholeNumberValue also understands Persian digits (۱ ۲ ۳), so it works on the Persian keyboard.
        guard let ch = press.characters.first, let digit = ch.wholeNumberValue else { return .ignored }
        if digit == 0 { flow.storyPoints = nil; return .handled }
        let d = String(digit)

        // "1" then "3" within a moment makes 13.
        let now = Date()
        digitBuffer = now.timeIntervalSince(lastDigitAt) < 0.8 ? digitBuffer + d : d
        lastDigitAt = now
        if let v = Double(digitBuffer), Self.pointOptions.contains(v) {
            flow.storyPoints = v
        } else if let v = Double(d), Self.pointOptions.contains(v) {
            digitBuffer = d
            flow.storyPoints = v
        }
        return .handled
    }

    // MARK: - Priority

    @ViewBuilder private var priorityRow: some View {
        let list = flow.priorities
        if !list.isEmpty {
            HStack(spacing: 4) {
                ForEach(Array(list.enumerated()), id: \.element.id) { i, p in
                    let selected = flow.priorityId == p.id
                    let color = PriorityStyle.color(index: i, count: list.count)
                    Button {
                        flow.priorityId = selected ? nil : p.id
                    } label: {
                        Image(systemName: PriorityStyle.symbol(index: i, count: list.count))
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 24, height: 22)
                            .background(selected ? color.opacity(0.22) : Color.primary.opacity(0.08), in: Capsule())
                            .foregroundStyle(selected ? color : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(p.name)
                }
                Text(list.first(where: { $0.id == flow.priorityId })?.name ?? "Priority")
                    .font(.system(size: 11))
                    .foregroundStyle(flow.priorityId == nil ? .tertiary : .secondary)
                    .frame(minWidth: 52, alignment: .leading)
            }
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(focus == .priority ? Color.accentColor.opacity(0.8) : .clear, lineWidth: 1.5)
            )
            .focusable()
            .focused($focus, equals: .priority)
            .focusEffectDisabled()
            .onKeyPress(phases: .down) { press in handlePriorityKey(press, list: list) }
            .help("Tab here, then 1–\(list.count) (1 = \(list[0].name)) or the arrow keys. Return creates. Empty = Jira's default. ⌥↑ ⌥↓ works anywhere.")
        }
    }

    private func handlePriorityKey(_ press: KeyPress, list: [PriorityRef]) -> KeyPress.Result {
        if press.modifiers.contains(.command) || press.modifiers.contains(.control) { return .ignored }
        switch press.key {
        case .return:
            flow.submit()
            return .handled
        case .delete, .deleteForward:
            flow.priorityId = nil
            return .handled
        case .leftArrow, .upArrow:
            flow.bumpPriority(raise: true)
            return .handled
        case .rightArrow, .downArrow:
            flow.bumpPriority(raise: false)
            return .handled
        default:
            break
        }
        if let n = press.characters.first?.wholeNumberValue, (1...list.count).contains(n) {
            flow.priorityId = list[n - 1].id
            return .handled
        }
        return .ignored
    }

    // MARK: - Issue type

    @ViewBuilder private var typeMenu: some View {
        if let board = settings.activeBoard, board.issueTypes.count > 1 {
            Menu {
                ForEach(board.issueTypes, id: \.id) { t in
                    Button(t.name) { flow.issueType = t.name }
                }
            } label: {
                Label(flow.effectiveIssueType, systemImage: IssueIcon.symbol(for: flow.effectiveIssueType))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        } else {
            Label(flow.effectiveIssueType, systemImage: IssueIcon.symbol(for: flow.effectiveIssueType))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Details

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $flow.notes)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .multilineTextAlignment(TextAlign.multiline(flow.notes))
                    .focused($focus, equals: .notes)
                    .frame(minHeight: 76, maxHeight: 140)
                if flow.notes.isEmpty {
                    Text("Details, steps, links…  ⌘V pastes a screenshot, or drop files here")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            .padding(6)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))

            HStack(spacing: 8) {
                ForEach(flow.attachments) { a in
                    ZStack(alignment: .topTrailing) {
                        Image(nsImage: a.thumbnail)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 52, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.12)))
                        Button {
                            flow.remove(a.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.black.opacity(0.65))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 5, y: -5)
                    }
                }
                Button(action: pickFiles) {
                    Label("Add image", systemImage: "photo.badge.plus").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func pickFiles() {
        host.suspendAutoHide = true
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.begin { response in
            host.suspendAutoHide = false
            if response == .OK {
                flow.add(panel.urls.compactMap { ImageTools.attachment(fromFile: $0) })
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    var url: URL?
                    if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                    else if let u = item as? URL { url = u }
                    guard let url, let a = ImageTools.attachment(fromFile: url) else { return }
                    DispatchQueue.main.async { flow.add([a]) }
                }
            } else if p.canLoadObject(ofClass: NSImage.self) {
                accepted = true
                _ = p.loadObject(ofClass: NSImage.self) { obj, _ in
                    guard let img = obj as? NSImage, let a = ImageTools.attachment(from: img) else { return }
                    DispatchQueue.main.async { flow.add([a]) }
                }
            }
        }
        return accepted
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            aiChip
            typeMenu
            Spacer()
            Text("↩ create   ⇥ points · priority")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Button {
                flow.submit()
            } label: {
                HStack(spacing: 6) {
                    if flow.phase == .creating { ProgressView().controlSize(.small) }
                    Text("Create").fontWeight(.semibold)
                    Text("⌘↩").font(.system(size: 11)).opacity(0.7)
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!flow.canSubmit)
        }
    }

    private var aiChip: some View {
        Button {
            if settings.hasAIKey { settings.autoImprove.toggle() } else { host.showSettings = true }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "sparkles").font(.system(size: 11))
                Text(chipText).font(.system(size: 12))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background((settings.hasAIKey && settings.autoImprove) ? Color.purple.opacity(0.18) : Color.primary.opacity(0.07), in: Capsule())
            .foregroundStyle((settings.hasAIKey && settings.autoImprove) ? Color.purple : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(settings.hasAIKey ? "AI rewrites the title and writes a description right after the task is created" : "Add a free OpenRouter key in Settings")
    }

    private var chipText: String {
        if !settings.hasAIKey { return "AI polish · add key" }
        return settings.autoImprove ? "AI polish on" : "AI polish off"
    }
}

enum IssueIcon {
    static func symbol(for type: String) -> String {
        switch type.lowercased() {
        case "bug": return "ladybug.fill"
        case "story": return "bookmark.fill"
        case "task": return "checkmark.square.fill"
        default: return "square.fill"
        }
    }

    static func color(for type: String) -> Color {
        switch type.lowercased() {
        case "bug": return .red
        case "story": return .green
        case "task": return .blue
        default: return .gray
        }
    }
}

// MARK: - After creating

struct CreatedView: View {
    @EnvironmentObject var flow: CreateFlow

    var body: some View {
        if let c = flow.created {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 18))
                    Text("\(c.key) created").font(.system(size: 17, weight: .semibold))
                    Spacer()
                }

                HStack(spacing: 8) {
                    Text(c.url.absoluteString)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    Button(flow.copied ? "Copied ✓" : "Copy link") { flow.copyLink() }
                        .keyboardShortcut("c", modifiers: .command)
                    Button("Open") { flow.openCreated() }
                        .keyboardShortcut("o", modifiers: .command)
                }

                Text(c.title)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(TextAlign.multiline(c.title))
                    .frame(maxWidth: .infinity, alignment: TextAlign.frame(c.title))

                aiStatus

                if let note = flow.attachmentNote {
                    Label(note, systemImage: "paperclip")
                        .font(.system(size: 12)).foregroundStyle(.orange)
                }

                HStack {
                    Spacer()
                    Button {
                        flow.reset()
                    } label: {
                        HStack(spacing: 6) {
                            Text("New task").fontWeight(.semibold)
                            Text("↩").font(.system(size: 11)).opacity(0.7)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(18)
        }
    }

    @ViewBuilder private var aiStatus: some View {
        switch flow.ai {
        case .off(let msg):
            if !msg.isEmpty {
                Label(msg, systemImage: "sparkles").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        case .working:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("AI is polishing the title and writing a description…")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        case .done(_, let summary):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Improved by AI — title and description updated in Jira", systemImage: "sparkles")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.purple)
                    Spacer()
                    Button("Undo") { flow.undoAI() }.controlSize(.small)
                }
                if !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .lineLimit(3)
                        .multilineTextAlignment(TextAlign.multiline(summary))
                        .frame(maxWidth: .infinity, alignment: TextAlign.frame(summary))
                }
            }
        case .failed(let msg):
            HStack(alignment: .top) {
                Label("AI couldn't polish this one (\(msg)). The task is saved as you wrote it.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Retry") { flow.retryAI() }.controlSize(.small)
            }
        case .undone:
            Label("Restored your original text.", systemImage: "arrow.uturn.backward")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}
