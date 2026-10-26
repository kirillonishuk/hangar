<div align="center">

<img src="docs/assets/icon-256.png" width="128" height="128" alt="Hangar app icon">

# Hangar

**A native macOS workspace for AI coding agents.**<br>
Run Claude Code and Codex side by side in real terminal tabs, one session per task,
with Git, diffs and a TypeScript-aware editor right next to them.

[![Release](https://img.shields.io/github/v/release/kirillonishuk/hangar?sort=semver&color=4c8dff)](https://github.com/kirillonishuk/hangar/releases/latest)
[![CI](https://img.shields.io/github/actions/workflow/status/kirillonishuk/hangar/ci.yml?label=CI)](https://github.com/kirillonishuk/hangar/actions/workflows/ci.yml)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-1f2430?logo=apple)](#install)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](Package.swift)
[![License: MIT](https://img.shields.io/badge/license-MIT-2ea44f)](LICENSE)

[Download](https://github.com/kirillonishuk/hangar/releases/latest) ·
[Features](#features) ·
[Screenshots](#screenshots) ·
[Build from source](#build-from-source) ·
[CLI & MCP](#cli--mcp) ·
[По-русски](#по-русски)

<br>

<a href="https://github.com/kirillonishuk/hangar/releases/latest/download/hangar-demo.mp4">
  <img src="docs/assets/hangar-demo.gif" width="900" alt="Hangar demo: an agent works in a session, then the Git tab, a diff, go to definition and the Sessions view">
</a>

<sub>35-second tour. <a href="docs/assets/hangar-demo.mp4">Watch the MP4</a>.</sub>

</div>

## Features

- **Projects → sessions → tabs.** Every task is a session with its own tabs and splits; a session can live in its own
  git worktree on a new branch, or work in the project folder.
- **Real terminals.** Tabs are [libghostty](https://github.com/ghostty-org/ghostty) surfaces: GPU-rendered, fast, with
  your Ghostty config, fonts and shell integration. A bottom drawer (⌘J) keeps a plain shell at hand.
- **Agents at a glance.** Claude Code and Codex hooks feed live status into the sidebar and the Dock: *working*,
  *waiting for you*, *done*, *error*, with notifications when an agent needs input while you are elsewhere.
- **Subscription limits.** Claude and Codex usage windows in the sidebar, with warnings before you run out.
- **Inspector.** Files, Changes against the base branch or uncommitted only, and a Git tab with branches and history.
- **Editor and diffs.** Monaco in a native tab: side-by-side or inline diffs; TypeScript and JavaScript go to definition,
  references, hover, rename and errors via your project's own `tsserver`. Nothing to install.
- **Sessions view (⌘Y).** Closed sessions and every past Claude/Codex conversation of the project, searchable, one
  click to resume.
- **Quick open (⌘P) and command palette (⇧⌘P)** for sessions, files and commands.
- **Remote projects over SSH.** Open a project on a server: tabs run in `tmux` there and survive disconnects. Hangar
  checks the host and offers a one-click setup for what is missing.
- **Restores everything.** Sessions, tabs, splits and agent conversations come back after a restart.
- **Scriptable.** The `hangar` CLI and an MCP server let agents create sessions, open tabs and read output.
- **Keeps the Mac awake** while agents work (optional). English and Russian UI.

## Screenshots

<table>
  <tr>
    <td width="50%"><img src="docs/assets/screenshots/main.png" alt="Sessions in the sidebar, an agent transcript, the Git tab"><br><sub><b>Sessions and the Git tab.</b> Agent states in the sidebar, history on the right.</sub></td>
    <td width="50%"><img src="docs/assets/screenshots/editor.png" alt="Monaco editor with TypeScript hover after go to definition"><br><sub><b>Go to definition.</b> TypeScript via the project's tsserver, with hover docs.</sub></td>
  </tr>
  <tr>
    <td><img src="docs/assets/screenshots/diff.png" alt="Side-by-side diff"><br><sub><b>Diffs.</b> Side by side or inline, against the base branch or uncommitted.</sub></td>
    <td><img src="docs/assets/screenshots/sessions.png" alt="Sessions view with closed sessions and past conversations"><br><sub><b>Sessions view.</b> Closed sessions and past Claude and Codex conversations.</sub></td>
  </tr>
  <tr>
    <td><img src="docs/assets/screenshots/palette.png" alt="Quick open palette"><br><sub><b>Quick open.</b> ⌘P for sessions and files, ⇧⌘P for commands.</sub></td>
    <td><img src="docs/assets/screenshots/remote.png" alt="A remote project on an SSH host"><br><sub><b>Remote projects.</b> An agent running on an SSH host, in tmux.</sub></td>
  </tr>
  <tr>
    <td><img src="docs/assets/screenshots/remote-sheet.png" alt="Remote project sheet checking the host"><br><sub><b>Host check.</b> What the server has, and a reviewed install plan for the rest.</sub></td>
    <td align="center"><img src="docs/assets/screenshots/settings.png" width="62%" alt="Settings window"><br><sub><b>Settings.</b> Also editable as <code>~/.config/hangar/config.toml</code>.</sub></td>
  </tr>
</table>

## Install

1. Download **Hangar-x.y.z.dmg** from the [latest release](https://github.com/kirillonishuk/hangar/releases/latest),
   open it and drag **Hangar** to **Applications**.
2. The build is ad-hoc signed, not notarized, so macOS blocks the first launch. Either right-click **Hangar** →
   **Open** → **Open**, or run:

   ```sh
   xattr -dr com.apple.quarantine /Applications/Hangar.app
   ```

Requirements: macOS 14 or later on Apple silicon. Install the agents you use separately
([Claude Code](https://docs.anthropic.com/en/docs/claude-code), [Codex CLI](https://github.com/openai/codex)).
For live agent status, open **Settings → Claude Code / Codex** and review the hook changes Hangar proposes; it never
edits `~/.claude` or `~/.codex` without your confirmation.

## Build from source

You need Xcode 26 (Swift 6.3) and Zig 0.15 (only to build GhosttyKit).

```sh
git clone https://github.com/kirillonishuk/hangar.git && cd hangar

# 1. GhosttyKit.xcframework + Ghostty resources from the commit pinned in vendor/GHOSTTY_COMMIT.
#    Uses /opt/homebrew/opt/zig@0.15 (brew install zig@0.15) or ZIG=/path/to/zig-0.15/zig.
scripts/build-ghosttykit.sh

# 2. Build and test.
swift build
swift test

# 3. build/Hangar.app (release, ad-hoc signed) and build/Hangar.dmg.
scripts/bundle.sh
scripts/make-dmg.sh   # styles the DMG window via Finder; allow Automation once when asked
```

For development, `swift run HangarApp` starts a debug build. Debug builds can be pointed at throwaway state with
`HANGAR_STATE_DIR` and `HANGAR_CONFIG`.

## CLI & MCP

The app bundles a `hangar` CLI at `Hangar.app/Contents/Helpers/hangar`. It talks to the running app over a local socket.

```sh
hangar projects list
hangar sessions create --project acme-web --name discount-codes --worktree --prompt "Add a discount code field"
hangar tabs open --session discount-codes --kind codex
hangar tabs read --tab <id> --lines 40
hangar sessions archive --session discount-codes --yes
hangar doctor
```

`hangar mcp` is an MCP server over stdio (`--read-only` for the safe subset). Add it to your agents:

```sh
claude mcp add --scope user hangar -- /Applications/Hangar.app/Contents/Helpers/hangar mcp
codex mcp add hangar -- /Applications/Hangar.app/Contents/Helpers/hangar mcp
```

Tools: `projects_list`, `projects_add`, `sessions_list`, `sessions_create`, `sessions_archive`, `sessions_restore`,
`tabs_open`, `tabs_send`, `tabs_read`, `ssh_open`, `links_create`, `doctor`. Destructive calls require `yes: true`.

## Architecture

Hangar is a Swift package: AppKit for windows and terminals, SwiftUI for most views, no third-party Swift dependencies.

| Module | Role |
|---|---|
| `HangarApp` | App entry point. |
| `HangarUI` | Windows, sidebar, inspector, Sessions view, palette; Monaco editor in `WKWebView`; `tsserver` client. |
| `GhosttyBridge` | The only module that touches libghostty's C API (surfaces, input, config). |
| `Workspace` | Model, persisted state (`state.json`), `config.toml`. |
| `Exec` | Launch specs for tabs, SSH masters, remote tmux sessions, host checks. |
| `Git` | `git` CLI wrapper: status, diffs, branches, history, worktrees. |
| `AgentStatus` | Turns agent hook events and terminal signals into session states. |
| `ControlServer` | Local socket protocol shared by the app, the `hangar` CLI and the MCP server. |
| `Integration` | Reviewed install/uninstall of Claude Code and Codex hooks. |
| `History` | Reads past Claude/Codex conversations for the Sessions view. |
| `Usage` | Subscription limit windows. |
| `Power` | Keeps the Mac awake while agents work. |
| `hangar` | The CLI / MCP executable. |

Design notes live in [`docs/`](docs): the spec, the decision log and the design system.

## Releases

Every pull request merged into `main` builds and publishes a release: the version is bumped from the PR label
(`major`, `minor`, `patch`) or the PR title's conventional-commit type (`feat!:` → major, `feat:` → minor, anything else
→ patch), written to `Resources/Info.plist`, tagged `vX.Y.Z`, and the DMG is attached to a GitHub Release with generated
notes. Pushing a `v*` tag or running the **Release** workflow manually works too. See
[`.github/workflows`](.github/workflows).

## Acknowledgements

- [Ghostty](https://github.com/ghostty-org/ghostty) by Mitchell Hashimoto and contributors: libghostty powers every
  terminal tab (MIT).
- [Monaco Editor](https://github.com/microsoft/monaco-editor) by Microsoft: the editor and diff view (MIT, see
  `Sources/HangarUI/Monaco/ThirdPartyNotices.txt`).
- File icons from [**Icons – Maintained**](https://github.com/yusifaliyevpro/vscode-icons) by Yusif Aliyev, a fork of the
  “Icons” theme by Mhammed Talhaouy (MIT, see
  `Sources/HangarUI/FileIcons/LICENSE.txt`).
- [TypeScript](https://github.com/microsoft/TypeScript)'s `tsserver`, run from your project, for language features.
- [Claude Code](https://github.com/anthropics/claude-code) and [Codex](https://github.com/openai/codex), the agents
  Hangar is built around.
- The simplicity rules in `AGENTS.md` are adapted from ponytail (MIT, DietrichGebert).

## License

[MIT](LICENSE) © Kirill Onishuk

## По-русски

**Hangar** — нативное приложение для macOS, рабочее место для AI-агентов. Claude Code и Codex работают во вкладках
настоящего терминала (libghostty), каждая задача — отдельная сессия (по желанию в своём git worktree), рядом — дерево
файлов, изменения, Git, diff и редактор Monaco с переходом к определению для TypeScript. Статусы агентов, лимиты
подписок, история разговоров (⌘Y), быстрый переход (⌘P), удалённые проекты по SSH, CLI `hangar` и MCP-сервер.
Интерфейс на русском и английском.

Установка: скачайте DMG из [Releases](https://github.com/kirillonishuk/hangar/releases/latest) и перетащите Hangar в
«Программы». Сборка не нотаризована: при первом запуске — правый клик → «Открыть» или
`xattr -dr com.apple.quarantine /Applications/Hangar.app`. Сборка из исходников — в разделе
[Build from source](#build-from-source).
