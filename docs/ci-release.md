# CI release automation

Push a version tag and GitHub Actions cuts the whole release: it runs the
release gate (SwiftLint strict + full test suite), signs and notarizes the app,
builds and notarizes the DMG, runs the launch smoke test, publishes a GitHub
release with the CHANGELOG section as notes, updates the Sparkle appcast, and
bumps the Homebrew tap cask.

The workflow is `.github/workflows/release.yml`. It does **not** fork a second
pipeline — it runs the same `Distribution/scripts/release.sh` the maintainer
runs locally (see [`releasing.md`](./releasing.md)), only supplying credentials
from encrypted repository secrets instead of the login Keychain.

> Backlog item 29 stays open until the first real tagged release runs green
> through this workflow and Sparkle auto-update is verified end to end against
> the published appcast. This branch builds the workflow; it has never run
> against real secrets or a real tag.

---

## How it triggers

| Trigger | What runs |
| --- | --- |
| Push a tag matching `v*` (must be `vX.Y.Z`, e.g. `v0.1.2`) | Full signed release **and** publish (GitHub release + tap bump). |
| `workflow_dispatch` with **dry_run = true** (default) | Whole plumbing **unsigned** — archive, DMG layout, and launch smoke test — with no signing, notarization, or publishing. Testable with no secrets and no tag. |
| `workflow_dispatch` with **dry_run = false** | Signs and notarizes, but because there is no tag it does **not** publish or bump the tap (a real release must come from a tag). |

The version comes from the tag (`v0.1.2` → `0.1.2`); for a dispatch run it is read
from `MARKETING_VERSION` in `Sentwise/Config/Version.xcconfig`, the one file that
defines the version (see Versioning below). Both paths must resolve to
`X.Y.Z`, and malformed tags such as `v0.2` fail before the release pipeline
publishes anything.

Release workflow runs are grouped per ref. Cross-tag safety comes from publish
and tap guards: stale tag reruns are published with `--latest=false`, and the
tap step refuses to overwrite a cask that already contains a newer semantic
version.

For tagged releases, CI also compares `CURRENT_PROJECT_VERSION` against the
previous stable release's Sparkle appcast build number and fails before the
release gate if the new build is not greater.

---

## Required repository secrets

Set these under **Settings → Secrets and variables → Actions** on
`github.com/michaeltookes/sentwise`. Values never live in the repo. Each row
lists the exact local command that produces the value.

### `MACOS_CERTIFICATE_P12`
Base64 of a **Developer ID Application** certificate **plus its private key**,
exported as a `.p12`.

1. In **Keychain Access**, find `Developer ID Application: Your Name (TEAMID)`,
   expand it to include its private key, right-click → **Export 2 items…**,
   save as `DeveloperID.p12`, and set an export password (that password is the
   next secret).
2. Base64 it and copy to the clipboard:
   ```bash
   base64 -i DeveloperID.p12 | pbcopy
   ```
3. Paste as the secret value, then delete the file: `rm -P DeveloperID.p12`.

### `MACOS_CERTIFICATE_PASSWORD`
The export password you set on the `.p12` in the step above. No command — it is
the string you typed.

### `APPLE_ID`
The Apple ID email of the Developer account used for notarization (the account
at [appleid.apple.com](https://appleid.apple.com)). No command.

### `APPLE_TEAM_ID`
Your 10-character Apple Developer Team ID. Read it off the signing identity:
```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
# -> "... "Developer ID Application: Your Name (TEAMID)" ..." — TEAMID is the value
```
Used both as the signing team and as notarytool's `--team-id`.

### `NOTARY_APP_SPECIFIC_PASSWORD`
An app-specific password for notarytool (**not** your Apple ID password).
Generate one at [appleid.apple.com](https://appleid.apple.com) →
**Sign-In and Security → App-Specific Passwords → +**. Copy the generated
`abcd-efgh-ijkl-mnop` string. On CI, notarytool is called with
`--apple-id / --team-id / --password` (no Keychain profile).

### `SPARKLE_ED_PRIVATE_KEY`
The EdDSA **private** key whose public half is already committed in
`Sentwise/Info.plist` as `SUPublicEDKey` (established for v0.1.0). Export the
existing key from your login Keychain with Sparkle's `generate_keys` and copy
the file's full contents:
```bash
# From Sparkle's tools (the same 2.9.5 bin/ the workflow downloads):
./bin/generate_keys -x sparkle_private_key.txt   # exports the EXISTING key
pbcopy < sparkle_private_key.txt                  # copy full file contents -> secret
rm -P sparkle_private_key.txt                     # securely delete
```
On CI the secret is written back to a temp file and passed to
`generate_appcast --ed-key-file` (there is no login Keychain on the runner).
**Do not** run `generate_keys` without `-x`: that would create a *new* keypair
and break auto-update for every installed client. See prerequisite 3 in
[`releasing.md`](./releasing.md).

### `TAP_PUSH_TOKEN`
A GitHub token with push access to `michaeltookes/homebrew-tap`, used to commit
the cask bump. Create a **fine-grained personal access token**
([github.com/settings/tokens](https://github.com/settings/tokens)) scoped to the
`homebrew-tap` repository with **Contents: Read and write**, and paste it.

---

## Sparkle tools on CI

The workflow downloads the **pinned** Sparkle `2.9.5` release tarball
(`Sparkle-2.9.5.tar.xz`) and points `SPARKLE_BIN` at its `bin/` directory. Keep
that pin in lockstep with the Sparkle SPM dependency version in
`Sentwise.xcodeproj` (currently `2.9.5`) — bump both together.

---

## How CI maps to `release.sh`

`release.sh` reads all credentials from the environment, so the workflow just
sets them:

| `release.sh` env var | CI source |
| --- | --- |
| `SIGNING_IDENTITY` | derived from the imported cert via `security find-identity` |
| `DEVELOPMENT_TEAM` | `APPLE_TEAM_ID` secret |
| `NOTARY_APPLE_ID` / `NOTARY_TEAM_ID` / `NOTARY_PASSWORD` | `APPLE_ID` / `APPLE_TEAM_ID` / `NOTARY_APP_SPECIFIC_PASSWORD` (used with notarytool's flag form instead of a Keychain `NOTARY_PROFILE`) |
| `SPARKLE_BIN` | the downloaded Sparkle `2.9.5` `bin/` |
| `SPARKLE_ED_KEY_FILE` | temp file holding `SPARKLE_ED_PRIVATE_KEY` |

Locally you instead set `NOTARY_PROFILE` and let `generate_appcast` read the key
from your Keychain — the script supports both paths.

---

## Homebrew tap update

Before bumping the tap, the tagged workflow publishes the GitHub release. If a
newer stable release already exists, this release is created or edited with
`--latest=false` so Sparkle's `releases/latest` appcast does not point at a
stale version. If the release already exists from a failed prior attempt, the
workflow edits the title and notes from the CHANGELOG section and re-uploads the
DMG, appcast, and SHA256 assets with `--clobber` so the tap update can be
retried by rerunning the job. If that existing release is a draft left behind by
an interrupted asset-backed create, the rerun publishes it after the replacement
assets are uploaded.
The tap bump then checks the newest semantic-versioned, non-prerelease GitHub
release and skips the cask write if this tag is stale, preventing an older rerun
from downgrading Homebrew installs after a newer release has shipped. After
cloning the tap, it also refuses to overwrite a cask version newer than the
current tag, closing the race between overlapping tag jobs.

On a tagged run the workflow clones `michaeltookes/homebrew-tap`, copies this
repo's `Distribution/sentwise.rb` template over `Casks/sentwise.rb`, stamps the
new `version` and DMG `sha256`, and commits in the tap's house style:
`sentwise: X.Y.Z`.

> The tap's `depends_on` line only updates the next time this workflow runs on a
> tag. Keep the bare-symbol form (`depends_on macos: :sonoma`, meaning Sonoma or
> newer) so the cask tracks the app's deployment target. Homebrew deprecated the
> string-comparison form (`">= :sonoma"`) and warns on every install when it is
> used. `Distribution/scripts/tests/test-cask-template.sh` (run in CI) fails if
> the template drifts back to the string form or away from
> `MACOSX_DEPLOYMENT_TARGET`.

---

## Testing the workflow without a release

Run a dry run to exercise everything that needs no secrets:

```bash
gh workflow run release.yml -f dry_run=true
gh run watch
```

This archives, lays out the DMG, and runs the launch smoke test on the runner —
proving the plumbing without signing, notarizing, or publishing.

---

## Transient Apple errors

GitHub-hosted runners sometimes lose DNS or the connection to Apple mid-run.
`release.sh` retries notarytool and stapler up to 3 times on network errors
only, and treats a `stapler validate` network failure after a successful staple
as a warning; rejections and missing tickets still fail fast (details in
`releasing.md` → Guards worth knowing). If a run still fails on a network
error, re-run the failed job. The per-run signing keychain password is masked
in the job log (`::add-mask::`).

## Versioning

The version is defined in one file, `Sentwise/Config/Version.xcconfig`
(`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`). It is the base configuration
of the project-level Debug, Release, and QA build configurations, and no target or
configuration sets either value in `project.pbxproj`, so every build (production,
QA, tests) reports the same version. `release.sh`, `qa-build.sh`, and the
release workflow read it from that file. Bump it there and nowhere else.

## First real release checklist

1. Add all seven secrets above.
2. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in
   `Sentwise/Config/Version.xcconfig`, add the CHANGELOG
   `## [X.Y.Z]` section, and merge to `main`. That section is also embedded in
   the appcast as the Sparkle update dialog's release notes; `release.sh` fails
   the run if it is missing (see `releasing.md` → Release notes in the appcast). The build number must be greater
   than the previous stable release's Sparkle build.
3. Tag and push: `git tag v0.1.2 && git push origin v0.1.2`.
4. Watch the run (`gh run watch`); confirm the GitHub release, the appcast
   asset, and the `sentwise: X.Y.Z` commit in the tap.
5. Verify Sparkle auto-update end to end from an installed older build (the
   item 29 / item 11 carry-over), including that the update dialog shows the
   release notes for the new version (item 114) rather than a blank area.
