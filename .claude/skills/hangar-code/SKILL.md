---
name: hangar-code
description: How to write Swift code in Hangar — simplicity order, module boundaries, Theme/L10n/keyCode rules, energy, dependencies and user-file safety. Use before writing or changing any code under Sources/ or Tests/.
---

# Writing code in Hangar

Rules are in `AGENTS.md` («Простота», «Инженерные правила»); module map in spec §2 (`docs/superpowers/specs/2026-10-18-hangar-design.md`); UI in `docs/design/DESIGN.md` and the mockups. Read the section you need, not everything. Below is how to apply them.

## Before writing
1. Check `docs/decisions.md` (`rg -n '<topic>' docs/decisions.md`) — don't reopen a decided question without new facts.
2. Walk the «Простота» order: needed at all? → already in the project (`rg` for it, copy the surrounding style) → Foundation/AppKit/SwiftUI/system → minimal new code.
3. Unsure about intent → one concrete question to the owner, not an exploration of alternatives.

## Module boundaries (`Package.swift`)
- Only `GhosttyBridge` imports `GhosttyKit` / calls `ghostty_*`.
- `Workspace`, `Git`, `AgentStatus` (and other non-UI modules: `Exec`, `Usage`, `History`, `Integration`, `Power`, `ControlServer`) import no AppKit/SwiftUI and have unit tests.
- UI lives in `HangarUI`; `HangarApp` is the thin launcher; `hangar` is the CLI.
- A new target or dependency → `Package.swift` + entry in `docs/decisions.md`. No third-party UI kits.

## UI
- Colors, sizes, radii, fonts only from `Theme` (`Sources/HangarUI/Theme*.swift`). Colors are per-theme (`ThemePalette`, decision #85): add a token to every palette, never a literal. AppKit layers must react to `hangarThemeDidChange`.
- Every user-visible string through `L10n` (`Sources/HangarUI/L10n.swift`): add the `Key` case and the string in **both** `Resources/ru.lproj` and `Resources/en.lproj/Localizable.strings` (a test checks completeness). ru is the source language.
- Hotkeys match `keyCode` (works in the Russian layout), via the `Shortcut` table; tooltips via `L10n.help`.
- Look: match the mockup; no layout jumps (constant heights, reserved space), hand cursor on clickables.

## Energy
- Idle = zero timers and polling. No `Timer` / `asyncAfter` loops for state; one-shot work items are fine.
- File changes: FSEvents + debounce, only for the visible session. Hidden terminal surfaces stay render-paused.

## Correctness
- Bug → find all callers, fix the root once in shared code.
- Non-trivial logic (branching, parsing, writing data) gets at least one test (`hangar-test`).
- Never weaken validation at trust boundaries (socket, hooks, stdin), data-loss protection, security, accessibility.
- Deliberate shortcut → `// shortcut: <limitation>, <when to change>`. Comments only say "why", one line.

## Safety
- Don't install anything (brew, npm, plugins, toolchains) without the owner's consent.
- `~/.claude`, `~/.codex`, the Ghostty config, `~/.config/hangar`, `~/Library/Application Support/Hangar`: never touched without consent (show the diff, keep the original). Code that writes them must be covered by tests using temp paths.
- Destructive CLI/MCP operations require `--yes` / `yes: true`.

## Done
Builds; tests shown passing; spec/decisions updated if behaviour changed; UI checked against mockups; committed per `hangar-commit`.
