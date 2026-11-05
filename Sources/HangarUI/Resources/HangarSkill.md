---
name: hangar
description: Parallel work in Hangar (HANGAR_LEAF_ID is set). Use when a task splits into independent parts worth running at once, or the user asks for sub-chats / parallel agents - sessions_spawn, sessions_wait, sessions_note, tabs_wait.
---
<!-- hangar-skill v1 -->

# Hangar: parallel work

You run in a Hangar chat. Hangar's MCP tools (server `hangar`; same commands in the `hangar` CLI) start sub-chats: full chats with their own terminal and agent, shown under yours in the sidebar.

## When to split
- Only independent parts that each take minutes: research, a separate module, a review, a long build or release. Trivial or tightly coupled work: do it yourself.
- 2-4 sub-chats at a time is usually enough.

## Start: `sessions_spawn {name, prompt}`
- Default: it works in your folder (same checkout). Fine for reading, or edits to files nobody else touches.
- `worktree: true`: its own git worktree, for parallel edits that may collide. Its branch is merged by you or the user.
- `agent: "claude" | "codex"` (optional).
- The prompt is all it knows: goal, paths, constraints, how to verify, and exactly what to return. Ask it to end with a concise result (Hangar asks too).

## Collect: `sessions_wait {}`
Blocks until your sub-chats are done, need input or failed; returns each one's short final message and `note`. `still-running` = timeout passed: call again. Do your own part before waiting.
- `needs-input`: the user answers in that chat; tell them.
- `tabs_read {tab, lines}` only when the short result is not enough: the screen costs tokens.

## Progress: `sessions_note {note}`
A short stage line on your own chat, shown in Hangar, e.g. `"Task 3/7 · review round 2"`. Update at milestones; `""` clears it.

## Another tab: `tabs_wait {tab, for}`
Waits until that tab's agent ends its turn (`idle`), asks for input (`waiting`) or either (`any`); returns its status and last message. `still-running`: call again. Right after `tabs_send`, pass `next: true` so the old state does not count.

## Rules
- Never type into your own or your parent's terminal; sub-chats never write to you either: pull results with `sessions_wait`.
- No sub-chats for trivial work or to avoid thinking.
- Archive a sub-chat only when the user asks.
