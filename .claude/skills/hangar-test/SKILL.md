---
name: hangar-test
description: Building, testing and live UI verification for Hangar — swift build/test, filtered suites, flakiness lessons, isolated DEBUG app runs driven by the debug channel, README media. Use before running tests, writing tests, or launching the app to check UI.
---

# Testing Hangar

## Build and unit tests
- A fresh worktree has no `vendor/GhosttyKit.xcframework` (gitignored). Clone it from the main checkout instead of rebuilding: `cp -cR "$(git rev-parse --path-format=absolute --git-common-dir)/../vendor/GhosttyKit.xcframework" vendor/` (APFS clone, instant). Building it (`scripts/build-ghosttykit.sh`) needs Zig — an install, so ask first.
- `swift build` — debug build (needed for live checks too).
- `swift test` — full suite (Swift Testing: `@Suite`, `@Test`, `#expect`). Before a PR, show a full run.
- While iterating: `swift test --filter <SuiteOrTarget>` (e.g. `--filter TaskArchiveTests`, `--filter GitTests`). Report the filtered command honestly; it is not the full run.
- CI runs `swift test --no-parallel` under `AppleLanguages ru en` (`.github/workflows/ci.yml`). A test that passes only locally in parallel or only in one language is broken.

## Writing tests that don't flake
- Executable scripts (fake `ssh`, fake agents, hooks): create with `writeScript(_:to:)` (`Tests/*/FakeSSH.swift`), never `write` + `chmod`. Each new executable gets an XProtect scan on first exec; fresh per-test scripts queue for minutes in a full run. Never write to a linked script in place.
- Git fixtures: `TempRepo` (`Tests/GitTests`, `Tests/HangarUITests`) — temp dir with a space and Cyrillic in the path; keep that.
- Never block the main actor: `@MainActor` UI suites keep it busy. Blocking waits (`waitUntilExit`, synchronous socket requests, git processes) run on a dedicated thread via `onThread` (`Tests/Support/Waits.swift`, target `TestSupport`), not the cooperative pool or `Task.detached`. Their timeouts are `offMainBound` (60 s), measured inside the off-main work, and a timeout fails with a message (e.g. `RawClient.read`).
- Waiting for a condition: `waitUntil { … }` from `TestSupport`, never a private wall-clock loop. It counts polls (≥ 60 s by default), so a main actor stalled for seconds by other suites can't use up the budget. After a wait use `try #require`, never `!`; cleanup in `defer`. Product timeouts that a stalled test main actor would trip get a test seam (`ControlServer.idleTimeout`, `HANGAR_MIN_TIMEOUT` for the CLI).
- Reproduce a load flake by blocking the main actor (a throwaway `@MainActor` test that `usleep`s 12 s in a loop, run alongside the suite), not by starting more `swift test` runs.
- Tests never touch real user files: temp dirs only, explicit URLs for Claude/Codex settings, fixture ssh config.

## Live UI check (DEBUG build only)
Never run a release build or `/Applications/Hangar.app`; never `swift run` without isolation. Copy the pattern from `scripts/readme-media/common.sh` (`launch`, `cap`, `stop_app`):
- Env: `HANGAR_STATE_DIR` and `HANGAR_CONFIG` under `/tmp/<name>`, `HANGAR_DEBUG_NO_ACTIVATE=1`, `HANGAR_DEBUG_CHANNEL=<name>` (parallel instances don't cross-talk), `HANGAR_DEBUG_PROJECT=<fixture repo>` (enables the debug channel), `HANGAR_CLAUDE_SETTINGS` / `HANGAR_CODEX_CONFIG` under `/tmp`, `HANGAR_SSH` / `HANGAR_SSH_CONFIG` pointing at a fake ssh + fixture config. Fake `claude` / `codex` via `[agents]` in the temp config (see `scripts/readme-media/setup.sh`).
- Window chrome (titlebar, toolbar, corners): the SDK the binary records decides how macOS draws the window. The default `swift build` (swiftbuild backend, `.build/out/Products/Debug`) records SDK 14: old window (corners 12, titlebar 52); native-layout builds (`.build/arm64-apple-macosx/debug`) and the release record the real SDK (26.x). Check `otool -l <bin> | grep -A4 LC_BUILD_VERSION`; if it says 14, build `swift build --build-system native --scratch-path .build-native --product HangarApp` for chrome checks and delete `.build-native` afterwards (#120).
- Start `.build/debug/HangarApp` in the background with `env -i` + those vars, save the pid.
- Drive it with distributed notifications `dev.hangar.debug.<channel>`, object = command (`scripts/readme-media/hgcmd.swift`; commands are the `case`s in `Sources/HangarUI/MainWindow+Debug.swift`, e.g. `task`, `select`, `key`, `settings`, `theme`, `dump <file>`, `snap <file>`). Pause between commands.
- Capture by window id of that pid (`scripts/readme-media/wid.swift`, `comp.swift`, or `screencapture -l <id>`) — never full-screen grabs (they leak the owner's desktop). If terminal layers come out blank, use `snap <file>`. Screenshots go to `/tmp`.
- Don't use the `activate` debug command or `osascript … activate`: it steals the owner's focus.
- Always stop afterwards: `kill -TERM <pid>`, then any fake agents/ssh and the app's `tmux -L hangar` servers whose cwd is under your `/tmp` dir (`stop_app` shows how). Leave nothing running.

## Never
- Real `claude mcp add` / `codex mcp add`, or anything writing `~/.claude`, `~/.codex`, Ghostty config, real Hangar state — without the owner's consent.
- Dialing real ssh hosts from tests or debug runs.

## README media
`scripts/readme-media/{shots,video,social}.sh` (usage in `common.sh`): fixture world under `/tmp/hg-media`, output in `/tmp/hg-media-out`; copy into `docs/assets/` only after the owner has looked. Needs Screen Recording permission for the terminal.
