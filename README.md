# JiraBar

A tiny macOS menu-bar app for creating Jira tasks in seconds and moving them across the board with the arrow keys. Built for Jira Server / Data Center (works.digikala.com) with a Personal Access Token.

## Install

```bash
Scripts/build_app.sh --install     # builds, copies to ~/Applications, launches
```

The build is ad-hoc signed, so macOS may ask once to allow Keychain access after each rebuild: choose **Always Allow**.

## Using it

| | |
|---|---|
| **⌥⌘J** (changeable in Settings), the menu-bar icon, the Dock icon, or opening JiraBar from Spotlight | open the panel |
| type a title → **Tab** → points `1 2 3 5 8` (`1` then `3` = 13) → **Tab** → priority `1`–`5` → **↩** | create a task |
| **⌥↑** / **⌥↓** | raise / lower the priority (also on a selected task in the Board tab) |
| **⌘D** / **⌘V** / drag & drop | add a description, paste screenshots |
| **⌘1** / **⌘2** | Create / Board tabs |

**Board tab:** click a task (or use **↑↓**). Two buttons appear under it that name the column they lead to, plus a **Move to…** menu for any column. Keyboard: **←→** previous/next column, **⇧←→** first/last, **↩** open in Jira, **C** copy link. Right-click a task for Move to / Priority / Open / Copy link. Tasks are sorted by priority inside each column (toggle "Priority first").

- **Titles can be Persian or English.** Text is right-aligned automatically when it starts with a Persian letter, and Persian digits work for story points. The AI answers in the language of your title (or always English: Settings → AI).
- **New tasks go to the backlog.** On Scrum boards that means "not in a sprint"; on Kanban boards, the first column. On a Scrum board, moving a backlog task right pulls it into the active sprint.
- **The link is shown (and copied) as soon as the task exists.** AI runs afterwards in the background: it rewrites the title and writes a description (Context / Expected / Acceptance criteria, with Persian headings for Persian tickets), then updates the Jira task. **Undo** restores your original text. Your own notes are kept under "Original notes".
- AI uses free models on [OpenRouter](https://openrouter.ai/keys). Default is `openrouter/free` (OpenRouter picks an available free model); if one is rate limited the app tries two others. Free models must be enabled at <https://openrouter.ai/settings/privacy>. Task text and screenshots are sent to OpenRouter.
- **Can't see the menu-bar icon?** With many menu-bar apps macOS hides the extra ones (especially around the notch). Use the shortcut, the Dock icon (on by default, switch it off in Settings once you don't need it), or open JiraBar from Spotlight.
- Tokens are stored in the macOS Keychain.

## Develop

```bash
Scripts/test.sh                     # unit tests (Jira client logic, board moves, priorities, Persian text, AI parsing)
Scripts/build_app.sh                # release build -> build/JiraBar.app
Scripts/make_icon.swift             # regenerates Resources/AppIcon.icns (run with `swift`)
```

Layout: `Sources/JiraBarCore` (no UI: Jira client, board logic, AI, wiki markup) and `Sources/JiraBar` (AppKit panel + SwiftUI views).

`Scripts/env.sh` picks the toolchain: a full Xcode in `/Applications` is used through `DEVELOPER_DIR` (the system-wide `xcode-select` setting is left alone). With only the Command Line Tools the default SDK needs Xcode's SwiftUI macro plugin, so the macOS 26 SDK is used instead.

Debug builds can render every screen to PNG with fake data: `JIRABAR_SNAPSHOT_DIR=/tmp/shots .build/debug/JiraBar`.
