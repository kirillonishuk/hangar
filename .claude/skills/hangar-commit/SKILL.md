---
name: hangar-commit
description: Branching, commit messages and authorship rules for Hangar. Use before creating a branch, committing, amending or pushing in this repo.
---

# Committing in Hangar

Policy lives in `AGENTS.md` («Не ходить по кругу», «Готово, когда») and `docs/RELEASING.md` («Branches and PRs»). This is the operational part.

## Branch
- Never commit on `main`. Branch from fresh `origin/main`: `git fetch origin && git switch -c <type>/<short-kebab> origin/main`.
- `<type>` is one of `feat/`, `fix/`, `docs/`, `ci/`, `chore/`. Parallel work goes in a separate `git worktree` under `/tmp`, one branch each.

## Message
- Conventional commit, English, imperative, lower-case summary, no trailing period: `feat(editor): …`, `fix(git): …`, `docs: …`, `ci: …`, `chore: …`. Scope is optional and names the area (`ui`, `editor`, `git`, `remote`, `cli`, …).
- `!` after the type (`feat!:`) only for a deliberate breaking change: on a PR title it cuts a major release.
- Body only when the "why" isn't obvious; one short paragraph.

## Authorship (CI enforces it)
- Commit as the configured git user. Never pass `--author`, never set `GIT_AUTHOR_*` / `GIT_COMMITTER_*`, never `-c user.*`.
- No `Co-Authored-By`, no "Generated with …", no AI attribution of any kind in messages, PR titles or bodies.
- Test fixtures that need a fake author set it inside the temp repo only (see `scripts/readme-media/setup.sh`), never on this repo.

## Content
- Small, focused commits: one logical change each; no drive-by refactors.
- Behaviour or scope changed → update `docs/superpowers/specs/2026-10-18-hangar-design.md` or add an entry to `docs/decisions.md` **in the same commit**.
- Before committing: `git diff --cached` contains no secrets, real hostnames, usernames or home paths (`/Users/...`); fixtures use neutral names.
- `swift build` passes for code commits; tests per the `hangar-test` skill.

## Before push
```sh
scripts/check-commits.sh origin/main..HEAD   # authorship + no co-author trailers
```
If it fails: fix with `git commit --amend --reset-author` / reword, then `git push --force-with-lease` **on your own feature branch only**. Never force-push `main` or a branch someone else pushed to without the owner's OK.
