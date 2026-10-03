import SwiftUI
import JiraBarCore

struct RootView: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var host: PanelHost
    @EnvironmentObject var board: BoardFlow

    var body: some View {
        VStack(spacing: 0) {
            HeaderView()
            Divider().opacity(0.5)
            Group {
                if host.showSettings || !settings.isConfigured {
                    SettingsView()
                } else if host.tab == .create {
                    CreateView()
                } else {
                    BoardView()
                }
            }
        }
        .frame(width: 600)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: host.tab) { _, tab in
            if tab == .board { board.refreshIfStale() }
        }
    }
}

struct HeaderView: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var host: PanelHost

    var body: some View {
        HStack(spacing: 6) {
            if settings.isConfigured {
                TabPill(title: "Create", icon: "plus", shortcut: "⌘1", selected: host.tab == .create && !host.showSettings) {
                    host.showSettings = false
                    host.tab = .create
                }
                TabPill(title: "Board", icon: "rectangle.split.3x1", shortcut: "⌘2", selected: host.tab == .board && !host.showSettings) {
                    host.showSettings = false
                    host.tab = .board
                }
            } else {
                Label("JiraBar", systemImage: "text.badge.plus")
                    .font(.system(size: 13, weight: .semibold))
            }
            Spacer()
            if settings.isConfigured { boardMenu }
            if settings.isConfigured {
                Button {
                    host.showSettings.toggle()
                } label: {
                    Image(systemName: host.showSettings ? "xmark.circle.fill" : "gearshape")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Settings (⌘,)")
            }

            // Invisible buttons that carry the keyboard shortcuts.
            Group {
                Button("") { host.showSettings = false; host.tab = .create }.keyboardShortcut("1", modifiers: .command)
                Button("") { host.showSettings = false; host.tab = .board }.keyboardShortcut("2", modifiers: .command)
                Button("") { host.showSettings.toggle() }.keyboardShortcut(",", modifiers: .command)
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .allowsHitTesting(false)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    @ViewBuilder private var boardMenu: some View {
        if let active = settings.activeBoard {
            if settings.boards.count > 1 {
                Menu {
                    ForEach(settings.boards) { b in
                        Button {
                            settings.activeBoardID = b.id
                        } label: {
                            Text(b.id == active.id ? "✓ \(b.name)" : b.name)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(active.name).lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold))
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            } else {
                Text(active.name)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

struct TabPill: View {
    let title: String
    let icon: String
    let shortcut: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10, weight: .bold))
                Text(title).font(.system(size: 12.5, weight: .medium))
                Text(shortcut).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(selected ? Color.primary.opacity(0.1) : .clear, in: Capsule())
            .foregroundStyle(selected ? .primary : .secondary)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
