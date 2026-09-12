# Releasing Sentwise

The full runbook for cutting a signed, notarized, auto-updating release of the
Sentwise menu-bar app. This covers the **manual** pipeline. The same
`release.sh` also runs unchanged on CI — a version-tag push builds and publishes
the whole release via GitHub Actions; see [`ci-release.md`](./ci-release.md) for
the workflow and its secrets. This page stays the source of truth for the
pipeline itself.

Everything credential-related is supplied at release time through environment
variables — **nothing is stored in the repo**. The scaffolding (scripts, cask
template, Sparkle wiring, DMG assets) lives under `Distribution/`.

---

## What's in the repo vs. what you supply

| In the repo (this branch) | You supply at release time |
| --- | --- |
| `Distribution/scripts/release.sh` — the pipeline | Developer ID Application cert (in login Keychain) |
| `Distribution/scripts/make-dmg.sh` / `make-icns.sh` / `make-appiconset.sh` | notarytool keychain profile |
| `Distribution/assets/**` — branded DMG background + icon masters (Closer palette) | Sparkle EdDSA **private** key matching the committed public key |
| `Distribution/sentwise.rb` — Homebrew cask template | |
| `Sentwise/Info.plist` — Sparkle feed URL + established `SUPublicEDKey` | |

---

## One-time prerequisites

1. **Apple Developer ID Application certificate**
   Installed in your login Keychain. Confirm:
   ```bash
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```
   Note the identity string and your 10-character Team ID.

2. **notarytool keychain profile**
   Store an app-specific password (from appleid.apple.com) once:
   ```bash
   xcrun notarytool store-credentials "Sentwise-Notary" \
     --apple-id "you@example.com" \
     --team-id "YOURTEAMID" \
     --password "app-specific-password"
   ```
   `Sentwise-Notary` is then your `NOTARY_PROFILE`.

3. **Sparkle EdDSA signing keypair** — established for v0.1.0
   The public key is already committed in `Sentwise/Info.plist` as
   `SUPublicEDKey`. For every signed release, use the matching **private** key
   from the maintainer's login Keychain. Never generate a replacement keypair or
   change `SUPublicEDKey` for a normal release: installed clients verify updates
   against the public key that shipped inside their current app.

   - The **private** key stays in the maintainer's login Keychain — never commit
     it, never print it into the repo.
   - To re-print the public half for verification: `./bin/generate_keys -p`.
   - Run Sparkle's `generate_keys` only before the first public release or as an
     intentional key rotation with a migration plan. If it is run accidentally,
     do not paste or commit the new public key.

   The release script still aborts if a signed build contains the old all-`A`
   placeholder or an empty `SUPublicEDKey`.

4. **Tooling**: `create-dmg` (`brew install create-dmg`) and Sparkle's
   `generate_appcast` / `sign_update`. Point `SPARKLE_BIN` at the directory
   holding those two tools if they aren't on your `PATH`.

5. **Homebrew tap** lives at `~/Desktop/Current Projects/homebrew-tap`
   (`michaeltookes/homebrew-tap`). The cask is only added/updated there at
   actual release time — this repo just carries the template.

---

## Versioning

- `MARKETING_VERSION` (currently `0.1.0`) is the human version — bump per
  release. CI release tags and this value must use `X.Y.Z` format, e.g.
  `v0.1.2` / `0.1.2`.
- `CURRENT_PROJECT_VERSION` is an integer Sparkle compares as `CFBundleVersion`
  — bump it every release, even for the same marketing version, so Sparkle can
  order builds. CI tag releases fail before publishing unless it is greater than
  the previous stable release's appcast build.
- Both can be overridden per run: `release.sh --version 0.2.0 --build 5`.

---

## Dry run (no credentials needed — do this first)

Proves the archive → DMG path and the branded layout without any signing:

```bash
Distribution/scripts/release.sh --dry-run
```

Output lands in the gitignored `dist/`:
- `dist/Sentwise-<version>.dmg` — unsigned, for layout inspection only
- `dist/Sentwise-<version>.dmg.sha256`

Open the DMG to confirm the background art and drag-to-Applications layout, then
detach it. **Do not distribute a dry-run DMG** — it is unsigned and
un-notarized, so Gatekeeper will block it on other machines.

---

## Full signed release

```bash
export SIGNING_IDENTITY="Developer ID Application: Your Name (YOURTEAMID)"
export DEVELOPMENT_TEAM="YOURTEAMID"
export NOTARY_PROFILE="Sentwise-Notary"
# export SPARKLE_BIN="/path/to/Sparkle/bin"   # if not on PATH

Distribution/scripts/release.sh --version 0.1.0 --build 1
```

What `release.sh` does, step by step:

1. **Archive** the `Sentwise` scheme in Release, stamping the version/build.
2. **Export** a Developer-ID-signed `.app` (hardened runtime, secure timestamp)
   via a generated `ExportOptions.plist`. It then **hard-aborts if the built
   app's `SUPublicEDKey` is empty or still carries the legacy all-`A`
   placeholder**, so a signed release can never ship without its
   update-verification key. This is a guard against missing/legacy wiring;
   normal releases must keep the committed public key and sign appcasts with the
   matching private key (prerequisite 3).
3. **Stage** the app as `Sentwise.app` so the DMG icon label reads as the
   brand name.
4. **Notarize + staple the app** — the ticket is stapled to the `.app`
   **before** it goes into the DMG (notarytool takes a throwaway zip; the ticket
   staples onto the bundle), so the app is independently notarized, not only the
   DMG.
5. **Build the DMG** with the branded background (`make-dmg.sh`, fixed geometry),
   then **notarize + staple the DMG** (`notarytool submit --wait`).
6. **Launch smoke test** — mount the final DMG, `spctl`-assess the app, launch
   it, confirm the process is still alive after ~5s, then kill and detach. This
   hard-fails the release on a dyld/startup crash; it is the only gate that
   would have caught the v0.1.0 launch crash (signatures and unit tests never
   execute the binary). It runs in both dry-run and signed modes.
7. **Appcast + checksums**: `generate_appcast dist/` signs the DMG with the
   EdDSA private key and writes `dist/appcast.xml`; the script then verifies the
   appcast actually references the new DMG (a silent `generate_appcast` failure
   is what shipped a broken v0.1.0 step). A `.sha256` is written too.

**Guards worth knowing:**
- **Stale-dist guard.** The script refuses to build if `dist/` holds a DMG, ZIP,
  or pkg from another version (a leftover dry-run artifact with a duplicate
  bundle version corrupts appcast generation). Clear `dist/` or pass
  `--clean-dist` to remove the strays automatically.
- **Fail-loud.** Every step's failure aborts the script with a named
  command/line; the run can no longer exit `0` after a step has failed.
- **CI credential form.** Instead of `NOTARY_PROFILE`, CI supplies
  `NOTARY_APPLE_ID` / `NOTARY_TEAM_ID` / `NOTARY_PASSWORD` (notarytool's flag
  form) and `SPARKLE_ED_KEY_FILE` (passed to `generate_appcast --ed-key-file`,
  since the runner has no login Keychain). Both credential paths are supported
  by the one script.

---

## Publishing

1. Create or update the GitHub release tagged `v<version>` on
   `github.com/michaeltookes/sentwise`.
2. Upload `Sentwise-<version>.dmg`, `appcast.xml`, and the DMG `.sha256` as
   release assets. On a CI rerun for an existing release, the workflow edits the
   release notes, re-uploads those assets with `--clobber`, and publishes any
   recovered draft before retrying the tap update. If a newer stable release
   already exists, CI marks the stale release `--latest=false`. The app's
   `SUFeedURL` points at
   `releases/latest/download/appcast.xml`, so the appcast must be an asset on
   the release marked **latest**.
3. **Homebrew cask**: copy `Distribution/sentwise.rb` into the tap at
   `~/Desktop/Current Projects/homebrew-tap/Casks/`, set `version` and the DMG
   `sha256` (from the `.sha256` file), then commit/push the tap. Users install
   with:
   ```bash
   brew install --cask michaeltookes/tap/sentwise
   ```
   CI skips this tap write when the tag is no longer the newest
   semantic-versioned, non-prerelease GitHub release, so an older rerun cannot
   downgrade the cask after a newer release has shipped. The tap step also
   refuses to overwrite a cloned cask that already contains a newer semantic
   version.

---

## Update flow (how users get new versions)

- On launch, Sparkle quietly checks the appcast (`SUEnableAutomaticChecks`).
- The menu's **Check for Updates…** item triggers an interactive check.
- Sparkle downloads the new DMG and verifies it against `SUPublicEDKey` before
  installing — which is why future appcasts must be signed with the private key
  matching the public key already shipped in the app.
