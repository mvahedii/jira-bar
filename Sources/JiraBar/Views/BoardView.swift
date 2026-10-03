import SwiftUI
import JiraBarCore

struct BoardView: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var board: BoardFlow
    @EnvironmentObject var host: PanelHost
    @FocusState private var focused: Bool
    @AppStorage("boardTipDismissed") private var tipDismissed = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().opacity(0.4)
            content
                .frame(height: 380)
            Divider().opacity(0.4)
            bottomBar
        }
        .onAppear {
            board.refreshIfStale()
            DispatchQueue.main.async { focused = true }
        }
        .onChange(of: host.showCount) { _, _ in
            board.refreshIfStale()
            DispatchQueue.main.async { focused = true }
        }
    }

    // MARK: - Pieces

    private var topBar: some View {
        HStack(spacing: 10) {
            Picker("", selection: $board.scope) {
                Text("Mine").tag(BoardScope.mine)
                Text("Everyone").tag(BoardScope.all)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)

            if !board.priorities.isEmpty {
                Button {
                    board.sortByPriority.toggle()
                } label: {
                    Label("Priority first", systemImage: "arrow.up.arrow.down")
                        .font(.system(size: 11.5))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(board.sortByPriority ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.07), in: Capsule())
                        .foregroundStyle(board.sortByPriority ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .help("Show the highest priority tasks first inside each column")
            }

            if let sprint = board.sprint {
                Label(sprint.name, systemImage: "bolt.horizontal.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if board.loading { ProgressView().controlSize(.small) }
            Button {
                board.refresh()
            } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("r", modifiers: .command)
            .help("Refresh (⌘R)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder private var content: some View {
        if let e = board.error, board.issues.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "wifi.exclamationmark").font(.system(size: 26)).foregroundStyle(.secondary)
                Text(e).font(.system(size: 13)).multilineTextAlignment(.center).foregroundStyle(.secondary)
                Button("Try again") { board.refresh() }
            }
            .padding(30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if board.issues.isEmpty && !board.loadedOnce {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if board.issues.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "tray").font(.system(size: 26)).foregroundStyle(.secondary)
                Text(board.scope == .mine ? "Nothing assigned to you here." : "No issues found.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            list
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !tipDismissed { tip }
                    ForEach(board.sections) { section in
                        SectionHeader(section: section)
                        ForEach(section.issues) { issue in
                            IssueRow(issue: issue, selected: issue.key == board.selection)
                                .id(issue.key)
                                .onTapGesture { board.selection = issue.key; focused = true }
                                .contextMenu { rowMenu(issue) }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: board.selection) { _, key in
                if let key { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(key) } }
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, .return], phases: [.down, .repeat]) { press in
            let shift = press.modifiers.contains(.shift)
            let option = press.modifiers.contains(.option)
            switch press.key {
            case .upArrow:
                if option { board.changeSelectedPriority(raise: true) } else { board.moveSelection(by: -1) }
            case .downArrow:
                if option { board.changeSelectedPriority(raise: false) } else { board.moveSelection(by: 1) }
            case .leftArrow: board.moveSelected(direction: -1, jump: shift)
            case .rightArrow: board.moveSelected(direction: 1, jump: shift)
            case .return: board.openSelected()
            default: return .ignored
            }
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "cCoOkKjJ"), phases: .down) { press in
            guard !press.modifiers.contains(.command) else { return .ignored }
            switch press.characters.lowercased() {
            case "c": board.copySelectedLink()
            case "o": board.openSelected()
            case "k": board.moveSelection(by: -1)
            case "j": board.moveSelection(by: 1)
            default: return .ignored
            }
            return .handled
        }
    }

    private var tip: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lightbulb.fill").foregroundStyle(.yellow).font(.system(size: 12))
            Text("To move a task: click it, then press ← or → (or use the buttons that appear under it). Right-click for “Move to…” and Priority.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button { tipDismissed = true } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(Color.yellow.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }

    @ViewBuilder private func rowMenu(_ issue: BoardIssue) -> some View {
        Menu("Move to") {
            ForEach(board.columns) { c in
                Button(c.name) { board.move(key: issue.key, toColumn: c.index) }
                    .disabled(!board.canMove(issue, toColumn: c.index))
            }
        }
        if !board.priorities.isEmpty {
            Menu("Priority") {
                ForEach(board.priorities, id: \.id) { p in
                    Button((issue.priorityId == p.id ? "✓ " : "") + p.name) { board.setPriority(key: issue.key, to: p) }
                }
            }
        }
        Divider()
        Button("Open in Jira") { board.open(issue.key) }
        Button("Copy link") { board.copyLink(issue.key) }
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            if let t = board.toast {
                Label(t.text, systemImage: t.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(t.isError ? Color.orange : Color.green)
                    .lineLimit(2)
                    .transition(.opacity)
            } else {
                Text("↑↓ select   ←→ move   ⇧←→ first/last   ⌥↑↓ priority   ↩ open   C copy link")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            // Hidden: ⌘C copies the selected link too.
            Button("") { board.copySelectedLink() }
                .keyboardShortcut("c", modifiers: .command)
                .frame(width: 0, height: 0).opacity(0).allowsHitTesting(false)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .animation(.easeOut(duration: 0.15), value: board.toast)
    }
}

struct SectionHeader: View {
    let section: BoardSection

    var body: some View {
        HStack(spacing: 6) {
            Text(section.column.name.uppercased())
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(section.issues.isEmpty ? .tertiary : .secondary)
                .tracking(0.4)
            if section.column.isBacklog {
                Text("not in sprint").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Text("\(section.issues.count)")
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 5)
                .background(Color.primary.opacity(0.08), in: Capsule())
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 3)
    }
}

struct IssueRow: View {
    @EnvironmentObject var board: BoardFlow
    let issue: BoardIssue
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: IssueIcon.symbol(for: issue.issueType))
                    .font(.system(size: 11))
                    .foregroundStyle(IssueIcon.color(for: issue.issueType))
                Text(issue.key)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(issue.summary)
                    .font(.system(size: 13))
                    .lineLimit(selected ? 2 : 1)
                Spacer(minLength: 6)
                priorityIcon
                if let sp = issue.storyPoints {
                    Text(sp == sp.rounded() ? String(Int(sp)) : String(sp))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.09), in: Capsule())
                        .foregroundStyle(.secondary)
                }
            }
            if selected { moveBar }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(selected ? Color.accentColor.opacity(0.16) : .clear)
        .overlay(alignment: .leading) {
            Rectangle().fill(selected ? Color.accentColor : .clear).frame(width: 2.5)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private var priorityIcon: some View {
        let list = board.priorities
        if let id = issue.priorityId, let i = list.firstIndex(where: { $0.id == id }) {
            Image(systemName: PriorityStyle.symbol(index: i, count: list.count))
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(PriorityStyle.color(index: i, count: list.count))
                .help(issue.priorityName ?? "")
        }
    }

    /// The obvious way to move a task: two buttons that name the column they lead to.
    private var moveBar: some View {
        HStack(spacing: 8) {
            moveButton(direction: -1)
            moveButton(direction: 1)
            Spacer(minLength: 4)
            Menu {
                ForEach(board.columns) { c in
                    Button(c.name) { board.move(key: issue.key, toColumn: c.index) }
                        .disabled(!board.canMove(issue, toColumn: c.index))
                }
            } label: {
                Label("Move to…", systemImage: "arrow.left.arrow.right").font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private func moveButton(direction: Int) -> some View {
        let target = board.target(for: issue, direction: direction)
        let name: String = {
            if case .to(let n) = target { return n }
            return direction < 0 ? "Previous" : "Next"
        }()
        return Button {
            board.move(key: issue.key, direction: direction)
        } label: {
            HStack(spacing: 5) {
                if direction < 0 { Image(systemName: "chevron.left").font(.system(size: 9, weight: .bold)) }
                Text(name).font(.system(size: 12)).lineLimit(1)
                if direction > 0 { Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)) }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(target == .none)
        .help(direction < 0 ? "Move to the previous column (←)" : "Move to the next column (→)")
    }
}
