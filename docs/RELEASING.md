# Releasing Hangar

Releases are cut by `.github/workflows/release.yml` once a day from what was merged into `main`, not on every merge
(decision HD-145). CI (`.github/workflows/ci.yml`) runs `swift build` and `swift test` on every PR; the
`Build & test` check is required by the `main` ruleset. The `Commit authorship` check (`scripts/check-commits.sh`)
fails on commits by anyone but the owner or with `Co-Authored-By` trailers. CI also runs on every push to `main`, only
to refresh the caches PRs read (GhosttyKit, SwiftPM `.build`).

## When a release is cut

- **Daily at 06:00 UTC**, if `main` has PRs merged since the last `v*` tag that are not labelled `no-release`. One
  release covers all of them.
- **Urgent:** label the PR `release-now` before merging; the merge releases `main` immediately (that PR and everything
  merged before it).
- **Manual:** Actions → Release → Run workflow (`workflow_dispatch`), see «Manual releases».
- A merge without `release-now` cuts nothing by itself.

## Branches and PRs

- `main` changes only through PRs. No direct pushes and no force pushes to `main` (the ruleset blocks both).
- Branch prefixes: `feat/`, `fix/`, `docs/`, `ci/`, `chore/`.

## Version

Each PR's title is a conventional commit and sets that PR's bump; a release takes the highest bump among the PRs
since the last `v*` tag (major > minor > patch), ignoring `no-release` PRs (`scripts/release-bump.sh`):

| PR title | Bump |
| --- | --- |
| `type!: …` or `type(scope)!: …` | major |
| `feat: …` or `feat(scope): …` | minor |
| anything else | patch |

Overrides, highest priority first:

1. Raise `CFBundleShortVersionString` in `Resources/Info.plist` above the last tag: that exact version is released.
2. Label `major`, `minor` or `patch` on the PR (sets that PR's bump).

PRs that only touch docs, CI or chores get the `no-release` label: they never cause a release and are left out of the
bump and the release notes.

## Before merge

- [ ] CI is green.
- [ ] Full `swift test` run locally.
- [ ] Independent review done.
- [ ] UI changes: screenshots from an isolated DEBUG build (`swift run HangarApp` with `HANGAR_STATE_DIR` and
      `HANGAR_CONFIG` pointing at throwaway paths) are in the PR body, and the owner has looked at them.
- [ ] A decision in `docs/decisions/` or the spec is updated if behaviour changed.
- [ ] PR title, PR body and release notes are in English.
- [ ] Every commit is authored by the owner from `git config` (no `--author` / `GIT_AUTHOR_*` overrides) and has no
      `Co-Authored-By` or other attribution trailers. CI checks this (`Commit authorship`).
- [ ] No secrets, real hostnames, usernames or home paths in the diff or screenshots.
- [ ] Bump label or `no-release` set if the title alone is not right; `release-now` only if it must ship today.

## Merge

- Merge commit (no squash, no rebase). Commit title: `Merge #N: <summary>`, body: the PR title.
- PRs without `release-now` can be merged back to back: nothing is released until the daily run.
- `release-now` PRs: one at a time. Wait for the previous Release run to finish before merging the next one: release
  runs share one concurrency group, a second waiting run replaces the first, and every run builds the current `main`.

## After a release: verification

The Release run verifies what it published, without a human: its last step («Verify the published release») downloads
`Hangar-X.Y.Z.dmg` and its `.sha256` from the release and fails the run unless the checksum matches,
`CFBundleShortVersionString` is the tag's version, `codesign --verify --deep --strict` passes and the signature's
authority is `Hangar Self-Signed`. So:

1. The Release run is green (a red run after «Publish GitHub Release» means a published release failed verification:
   see «Broken release»).
2. The owner launches the new version by hand.

The same check by hand, if ever needed:

   ```sh
   V=X.Y.Z; dir=$(mktemp -d); cd "$dir"
   gh release download "v$V" -R kirillonishuk/hangar -p "Hangar-$V.dmg*"
   shasum -a 256 -c "Hangar-$V.dmg.sha256"
   mnt=$(hdiutil attach -nobrowse -readonly "Hangar-$V.dmg" | awk -F'\t' '/\/Volumes\//{print $NF}')
   /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$mnt/Hangar.app/Contents/Info.plist"  # must be $V
   codesign --verify --deep --strict "$mnt/Hangar.app"
   codesign -dvv "$mnt/Hangar.app" 2>&1 | grep Authority   # must be Authority=Hangar Self-Signed
   hdiutil detach "$mnt"
   ```

Do not launch the app from automation: a release build ignores `HANGAR_STATE_DIR` and rewrites the real
`state.json`.

## Signing

Releases are signed with the self-signed "Hangar Self-Signed" certificate (SHA-1
`2BC32E9E59D0A3BB47BA27D3E2410F0A86F16768`, valid to 2046) so macOS keeps users' permissions across updates
(decision HD-129, `docs/decisions/HD-129-*.md`). The Release workflow imports it from the secrets `HANGAR_SIGN_P12` (base64 of the .p12)
and `HANGAR_SIGN_P12_PASSWORD` into a temporary keychain and fails without them. Never replace the certificate: a new
one resets every user's permissions. CI on PRs signs ad-hoc.

## Release notes

English. The workflow writes the Install steps and a «Changes» list: one line per PR in the release (title and
number, `no-release` PRs left out) and a full-changelog link. Edit the release if the list needs a short human summary
of the changes.

## Broken release

- Never delete or move tags.
- Mark the release as pre-release (`gh release edit vX.Y.Z --prerelease`) or edit its notes to describe the problem.
- Ship the fix as a `fix:` PR; it becomes the next patch release.

## Manual releases

- **Actions → Release → Run workflow** (`workflow_dispatch`): releases `main` now. Bump `auto` (default) is the
  highest among the PRs since the last tag (patch if all are `no-release`); `patch`, `minor`, `major` force it. A raised
  `Info.plist` version still wins. Nothing new on `main` since the last tag → nothing is released.
- Pushing a `v*` tag releases that tag as is: the version is the tag name and no new tag is created. The push must
  come from a person (a tag pushed with `GITHUB_TOKEN` triggers nothing), and the tag must not have a release yet.
