# JiraBar

A tiny macOS menu-bar app for creating Jira tasks in seconds and moving them across the board with the arrow keys. Press a shortcut from anywhere, type a title, hit Enter.

For **Jira Server / Data Center** with a Personal Access Token (Jira Cloud is not supported).

## Features

- **Fast create:** title → story points → priority → Enter. The task link is shown and copied right away. New tasks land in the backlog.
- **Persian or English** titles and descriptions, right-aligned automatically.
- **Description and screenshots:** `⌘D` for notes, `⌘V` or drag & drop for images (uploaded as attachments).
- **AI polish (optional):** after the task is created, a free [OpenRouter](https://openrouter.ai) model rewrites the title and writes a description. One click undoes it.
- **Board tab:** your tasks by column, highest priority first. Move them with `←` `→`, buttons, or a "Move to…" menu. Change priority with `⌥↑` `⌥↓`.
- Works with **Scrum and Kanban** boards. Several boards can be added.

## Install

1. Download `JiraBar-<version>.zip` from the [latest release](https://github.com/mvahedii/jira-bar/releases/latest).
2. Unzip it and drag **JiraBar.app** into **Applications**.
3. The app isn't notarized by Apple, so macOS blocks the first launch. Run this once in Terminal, then open the app:
   ```bash
   xattr -dr com.apple.quarantine /Applications/JiraBar.app
   ```
   (Or: System Settings → Privacy & Security → *Open Anyway*.)

Requires **macOS 14+** on **Apple Silicon** (M1 or newer).

## First-time setup

1. Open JiraBar (`⌥⌘J`, the Dock icon, or Spotlight). Connect to the VPN if your Jira needs it.
2. **Jira token:** in Jira click your avatar (top right) → **Profile** → **Personal Access Tokens** → **Create token**. Copy it, paste it into JiraBar, press **Connect**. The token is stored in your Mac's Keychain.
3. **Board:** search for your team's board and add it.
4. **AI (optional):** get a free key at [openrouter.ai/keys](https://openrouter.ai/keys) and paste it in Settings. Also enable free endpoints at [openrouter.ai/settings/privacy](https://openrouter.ai/settings/privacy), otherwise free models won't answer. Without a key everything else still works.

## Using it

| | |
|---|---|
| `⌥⌘J` (changeable), the menu-bar icon, the Dock icon, or Spotlight | open the panel |
| title → `Tab` → points `1 2 3 5 8` (`1` then `3` = 13) → `Tab` → priority `1`–`5` → `↩` | create a task |
| `⌥↑` / `⌥↓` | raise / lower priority (also on the selected task in the Board tab) |
| `⌘D` / `⌘V` / drag & drop | description, screenshots |
| `⌘1` / `⌘2` | Create / Board tabs |

**Board tab:** click a task or use `↑↓`. Buttons under it name the column they lead to, and **Move to…** jumps to any column. Keyboard: `←` `→` previous/next column, `⇧←` `⇧→` first/last, `↩` open in Jira, `C` copy link. Right-click for Move to, Priority, Open, Copy link. On a Scrum board, moving a backlog task right pulls it into the active sprint.

### AI

After the task exists, the AI step runs in the background and updates it in Jira: a clearer title plus a description with *Context*, *Expected behavior* and *Acceptance criteria* (Persian headings for Persian tickets). It answers in the language of your title, or always in English (Settings → AI). Your own notes are kept under "Original notes", and **Undo** restores your original text. The default model is `openrouter/free` (OpenRouter picks an available free model); if one is rate limited, two others are tried.

> **Privacy:** with AI on, the task text and screenshots are sent to OpenRouter. Turn the "AI polish" switch off for sensitive tasks. Nothing else leaves your Mac except requests to your own Jira. There is no telemetry.

### Troubleshooting

- **No menu-bar icon:** with many menu-bar apps macOS hides the extra ones, especially around the notch. Use the shortcut, the Dock icon (Settings can turn it off later), or Spotlight.
- **Shortcut doesn't open the panel:** another app may own it. Settings shows whether it is active; pick a different one.
- **Keychain prompt after an update:** choose **Always Allow**.
- **"Can't reach …":** connect to the VPN.
- **AI says it failed:** check the key, and that free endpoints are enabled in your OpenRouter privacy settings. The task is already saved as you wrote it.

<div dir="rtl">

## راهنمای سریع (فارسی)

**نصب:** فایل zip رو از [Releases](https://github.com/mvahedii/jira-bar/releases/latest) دانلود کن، باز کن و `JiraBar.app` رو بنداز توی Applications. بار اول این دستور رو توی Terminal بزن و بعد اپ رو باز کن:

```bash
xattr -dr com.apple.quarantine /Applications/JiraBar.app
```

**توکن جیرا:** جیرا ← آواتار بالا سمت راست ← Profile ← Personal Access Tokens ← Create token. توکن رو کپی کن و توی اپ بچسبون. اگه جیرا VPN می‌خواد، وصل باشه.

**استفاده:** `⌥⌘J` ← تایتل (فارسی یا انگلیسی) ← `Tab` ← استوری پوینت ← `Tab` ← اولویت ← `Enter`. با `⌘D` توضیحات و با `⌘V` اسکرین‌شات اضافه می‌شه. تب Board رو با `⌘2` باز کن و تسک رو با `←` `→` بین ستون‌ها جابجا کن.

**AI (اختیاری):** یه کلید رایگان از [openrouter.ai/keys](https://openrouter.ai/keys) بگیر و توی Settings بذار. «free endpoints» رو هم توی [openrouter.ai/settings/privacy](https://openrouter.ai/settings/privacy) روشن کن. متن تسک برای OpenRouter فرستاده می‌شه، پس تسک‌های حساس رو بدون AI بساز.

</div>

## Build from source

```bash
git clone https://github.com/mvahedii/jira-bar.git && cd jira-bar
Scripts/build_app.sh --install      # build, copy to ~/Applications, launch
```

```bash
Scripts/test.sh                     # unit tests (Jira client logic, board moves, priorities, Persian text, AI parsing)
VERSION=1.0.0 Scripts/package.sh    # build/JiraBar-1.0.0.zip for a GitHub release
swift Scripts/make_icon.swift       # regenerate Resources/AppIcon.icns
```

Needs the Swift toolchain (Xcode or the Command Line Tools) and macOS 14+. `Scripts/env.sh` uses a full Xcode from `/Applications` through `DEVELOPER_DIR` when present, without touching the system-wide `xcode-select` setting. With only the Command Line Tools, the default SDK needs Xcode's SwiftUI macro plugin, so the macOS 26 SDK is used instead.

```
Sources/JiraBarCore   no UI: Jira client, board logic, AI, wiki markup, Keychain
Sources/JiraBar       AppKit floating panel + SwiftUI views
Tests/                unit tests for the core
```

Debug builds can render every screen to PNG with fake data: `JIRABAR_SNAPSHOT_DIR=/tmp/shots .build/debug/JiraBar`.

## Status

Early version. The read paths were checked against a Jira 10.3 Data Center instance; creating, moving and editing tasks follow the documented REST API but have had less real-world testing, so please report anything odd as an issue. The app is ad-hoc signed, not notarized.
