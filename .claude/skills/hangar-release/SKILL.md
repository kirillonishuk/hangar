---
name: hangar-release
description: PR → merge → release checklist for Hangar (daily batched release, version from PR titles/labels, release-now for urgent fixes, automated DMG verification). Use when opening a PR, preparing or performing a merge to main, or checking a release.
---

# Hangar PR and release flow

Source of truth: `docs/RELEASING.md`. Read it; this is the checklist form plus the guard rails.

**Needs the owner's explicit OK each time:** merging any PR, force-pushing, editing/deleting releases or tags, changing repo rulesets or workflow permissions. Prepare everything, then ask.

## 1. Open the PR
- [ ] Branch pushed; `scripts/check-commits.sh origin/main..HEAD` passes (`hangar-commit` skill).
- [ ] Title is a conventional commit in English — it sets the bump: `type!:` major, `feat:` minor, anything else patch.
- [ ] Body: short English summary, what was verified (commands + results), screenshots for UI changes (isolated DEBUG build, see `hangar-test`).
- [ ] Label: docs/CI/chore-only → `no-release`; title bump wrong → `major` / `minor` / `patch`; must ship today (urgent fix) → `release-now` (owner's call).
  `gh pr create --title "<title>" --body-file <file> --label no-release`

## 2. Before merge (all of `docs/RELEASING.md` «Before merge»)
- [ ] `gh pr checks <N>` green (`Build & test` is required).
- [ ] Full local `swift test` run shown, not assumed.
- [ ] Independent review done (`reviewer` agent), findings resolved.
- [ ] UI changes: owner has looked at the screenshots.
- [ ] Spec / decisions (`docs/decisions/`, `scripts/check-decisions.sh` passes) updated if behaviour changed.
- [ ] No secrets, hostnames, usernames, home paths in diff or screenshots.

## 3. Merge (owner's OK first)
- Merge commit only: `gh pr merge <N> --merge --subject "Merge #<N>: <summary>" --body "<PR title>"`.
- Merging does not release: the Release workflow runs daily at 06:00 UTC and batches every PR merged since the last tag (bump = highest among them, `no-release` ignored). Plain PRs can be merged back to back.
- **`release-now` PRs: one at a time.** The merge releases immediately. Before the next one: `gh run list -w Release -L 3` and wait until the previous run is `completed` (`gh run watch <id>`). Runs share one concurrency group; a queued run replaces the waiting one.
- Release now without a label (owner's OK): `gh workflow run release.yml -f bump=auto` (or `patch` / `minor` / `major`).

## 4. Check the release (after the daily / `release-now` / manual run)
The Release run verifies the published DMG itself (step «Verify the published release»: sha256, `CFBundleShortVersionString` == tag, `codesign --verify --deep --strict`, `Authority=Hangar Self-Signed`) and fails if any check fails.
```sh
gh run list -w Release -L 3                         # the run is green
gh release view vX.Y.Z -R kirillonishuk/hangar      # assets: Hangar-X.Y.Z.dmg and .dmg.sha256; Changes list the PRs
```
Report the run and the version; the owner launches the app by hand. Manual re-check if needed: the block in `docs/RELEASING.md` «After a release».

**Never launch the released Hangar.app** (or `open` the DMG's app): a release build ignores `HANGAR_STATE_DIR` and rewrites the owner's real `state.json`. The owner launches it by hand.

## Broken release
Never delete or move tags. `gh release edit vX.Y.Z --prerelease` (owner's OK) and ship a `fix:` PR.
