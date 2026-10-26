# Releasing Hangar

Releases are cut by `.github/workflows/release.yml` when a PR is merged into `main`. CI (`.github/workflows/ci.yml`)
runs `swift build` and `swift test` on every PR; the `Build & test` check is required by the `main` ruleset.

## Branches and PRs

- `main` changes only through PRs. No direct pushes and no force pushes to `main` (the ruleset blocks both).
- Branch prefixes: `feat/`, `fix/`, `docs/`, `ci/`, `chore/`.

## Version

The PR title is a conventional commit and sets the version bump against the last `v*` tag:

| PR title | Bump |
| --- | --- |
| `type!: …` or `type(scope)!: …` | major |
| `feat: …` or `feat(scope): …` | minor |
| anything else | patch |

Overrides, highest priority first:

1. Raise `CFBundleShortVersionString` in `Resources/Info.plist` above the last tag: that exact version is released.
2. Label `major`, `minor` or `patch` on the PR.

PRs that only touch docs, CI or chores get the `no-release` label: merging them cuts no release.

## Before merge

- [ ] CI is green.
- [ ] Full `swift test` run locally.
- [ ] Independent review done.
- [ ] UI changes: screenshots from an isolated DEBUG build (`swift run HangarApp` with `HANGAR_STATE_DIR` and
      `HANGAR_CONFIG` pointing at throwaway paths) are in the PR body, and the owner has looked at them.
- [ ] `docs/decisions.md` or the spec is updated if behaviour changed.
- [ ] PR title, PR body and release notes are in English.
- [ ] No secrets, real hostnames, usernames or home paths in the diff or screenshots.
- [ ] Bump label or `no-release` set if the title alone is not right.

## Merge

- Merge commit (no squash, no rebase). Commit title: `Merge #N: <summary>`, body: the PR title.
- One PR at a time. Wait for the previous Release run to finish before merging the next one: release runs share one
  concurrency group, a second waiting run replaces the first, and every run builds the current `main`.

## After merge: verify the release

1. The Release run is green.
2. The release `vX.Y.Z` has `Hangar-X.Y.Z.dmg` and `Hangar-X.Y.Z.dmg.sha256`.
3. Check the DMG:

   ```sh
   V=X.Y.Z; dir=$(mktemp -d); cd "$dir"
   gh release download "v$V" -R kirillonishuk/hangar -p "Hangar-$V.dmg*"
   shasum -a 256 -c "Hangar-$V.dmg.sha256"
   mnt=$(hdiutil attach -nobrowse -readonly "Hangar-$V.dmg" | awk -F'\t' '/\/Volumes\//{print $NF}')
   /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$mnt/Hangar.app/Contents/Info.plist"  # must be $V
   codesign --verify --deep "$mnt/Hangar.app"
   hdiutil detach "$mnt"
   ```

4. Do not launch the app from automation: a release build ignores `HANGAR_STATE_DIR` and rewrites the real
   `state.json`. The owner launches it by hand.

## Release notes

English. The workflow writes the Install steps and appends GitHub's generated change list. Edit the release if the
list needs a short human summary of the changes.

## Broken release

- Never delete or move tags.
- Mark the release as pre-release (`gh release edit vX.Y.Z --prerelease`) or edit its notes to describe the problem.
- Ship the fix as a `fix:` PR; it becomes the next patch release.

## Manual releases

- **Actions → Release → Run workflow** (`workflow_dispatch`): releases `main` with the chosen bump (`patch`, `minor`,
  `major`). A raised `Info.plist` version still wins over the bump.
- Pushing a `v*` tag releases that tag as is: the version is the tag name and no new tag is created. The push must
  come from a person (a tag pushed with `GITHUB_TOKEN` triggers nothing), and the tag must not have a release yet.
