---
name: hangar-release
description: PR → merge → release checklist for Hangar (version from PR title, labels, one merge at a time, DMG verification). Use when opening a PR, preparing or performing a merge to main, or checking a release.
---

# Hangar PR and release flow

Source of truth: `docs/RELEASING.md`. Read it; this is the checklist form plus the guard rails.

**Needs the owner's explicit OK each time:** merging any PR, force-pushing, editing/deleting releases or tags, changing repo rulesets or workflow permissions. Prepare everything, then ask.

## 1. Open the PR
- [ ] Branch pushed; `scripts/check-commits.sh origin/main..HEAD` passes (`hangar-commit` skill).
- [ ] Title is a conventional commit in English — it sets the bump: `type!:` major, `feat:` minor, anything else patch.
- [ ] Body: short English summary, what was verified (commands + results), screenshots for UI changes (isolated DEBUG build, see `hangar-test`).
- [ ] Label: docs/CI/chore-only → `no-release`; title bump wrong → `major` / `minor` / `patch`.
  `gh pr create --title "<title>" --body-file <file> --label no-release`

## 2. Before merge (all of `docs/RELEASING.md` «Before merge»)
- [ ] `gh pr checks <N>` green (`Build & test` is required).
- [ ] Full local `swift test` run shown, not assumed.
- [ ] Independent review done (`reviewer` agent), findings resolved.
- [ ] UI changes: owner has looked at the screenshots.
- [ ] Spec / `docs/decisions.md` updated if behaviour changed.
- [ ] No secrets, hostnames, usernames, home paths in diff or screenshots.

## 3. Merge (owner's OK first)
- Merge commit only: `gh pr merge <N> --merge --subject "Merge #<N>: <summary>" --body "<PR title>"`.
- **One at a time.** Before the next merge: `gh run list -w Release -L 3` and wait until the previous run is `completed` (`gh run watch <id>`). Runs share one concurrency group; a queued run replaces the waiting one.

## 4. Verify the release (skip for `no-release`)
```sh
gh release view vX.Y.Z -R kirillonishuk/hangar      # assets: Hangar-X.Y.Z.dmg and .dmg.sha256
```
Then run the block in `docs/RELEASING.md` «After merge» in a `mktemp -d` dir: download, `shasum -a 256 -c`, `hdiutil attach -nobrowse -readonly`, `PlistBuddy` version == tag, `codesign --verify --deep`, `hdiutil detach`. Report each result.

**Never launch the released Hangar.app** (or `open` the DMG's app): a release build ignores `HANGAR_STATE_DIR` and rewrites the owner's real `state.json`. The owner launches it by hand.

## Broken release
Never delete or move tags. `gh release edit vX.Y.Z --prerelease` (owner's OK) and ship a `fix:` PR.
