# Cone Desktop (Buzz 1.0)

Cone's build of Buzz 1.0 (`block/buzz-app`): upstream's app at the stable tag
in `cone/UPSTREAM`, named, iconed and configured for `buzz.cone.digital`. The
plan and its record are in `cone-buzz-infra`,
`slices/48-cone-desktop-on-buzz-app.md` (ADR-340, amended by ADR-353). The old
Cone app (`1.1.x`, Buzz 0.X) is built from `ConeDigital/cone-buzz` and stays
there until every Mac has moved.

**The fork stays shallow:** everything Cone adds is under `cone/`, plus one
`import 'cone/cone.just'` line in the root `justfile` and
`.github/workflows/cone-desktop.yml`. `just cone-shallow-check` refuses any
other path, locally and on every pull request. Never change an upstream file.
The window still says "Buzz": only the bundle is branded (ADR-340 decision 4).

| Path | What |
|------|------|
| `UPSTREAM` | the pinned upstream tag: a stable `vX.Y.Z`, never a beta, a preview or an internal `desktop-v*` tag |
| `build.env` | the build-time configuration (no secret): the default community, Builderlab set empty on purpose |
| `build-env.sh` | refuses a repository-root `.env*`, clears every `BUZZ_*` the build reads or the shell exports, then loads `build.env` |
| `tauri.cone.conf.json` | the Tauri config delta: name, identifier, icons, `Info.plist`, DMG layout and background |
| `Info.plist`, `icons/`, `make-assets.py` | the menu-bar name and the microphone usage string; the icons and DMG background, generated from `icons/source.png` |
| `cone.just` | `cone-desktop-build`, `cone-shallow-check`, `cone-build-env-check`, `cone-notarize-test`, `cone-updater-test` |
| `updater.pub` | the updater's public key (minisign `A11AAB7556EB3BE2`, the old app's), compiled into every build with the feed `https://buzz.cone.digital/desktop/2/latest.json` |
| `sign-nested.sh` | signs the helpers Buzz 1.0 bundles in `Contents/Resources/bin` (Tauri leaves them linker-signed), then the app |
| `notarize.sh`, `release-advance.sh`, `notarize-test.sh` | notarization (submit; wait through dropped requests; staple), the resumable stages of one architecture's release, and their test against mocks |
| `updater-archive.sh`, `updater-verify.sh`, `promote-check.sh`, `updater-test.sh`, `test/updater/` | the updater archive from the stapled app; the signature check an app makes; the promotion's refusals (an older version, any object but `2/latest.json`); their test |

## Build locally (unsigned)

```bash
. bin/activate-hermit
just cone-desktop-build aarch64-apple-darwin            # or x86_64-apple-darwin; version defaults to 2.0.0-local
# → target/<target>/release/bundle/{macos/Cone.app,dmg/Cone_<version>_<arch>.dmg}
```

Ad-hoc signed, unstyled DMG (the Finder layout needs an Automation grant on
a workstation). The updater is built in (Cone's feed and key), so a local
build offers the newest promoted release. Never distribute a local build. The version goes
into the build through a `--config` delta outside the tree, as upstream's
release does; the tree is clean afterwards (the recipe checks).

## What a Mac shares between apps

The identifier is the old Cone app's (`digital.cone.desktop`), so the new app
uses the same `~/Library/Application Support/digital.cone.desktop` and
`~/Library/WebKit/digital.cone.desktop`, and keeps its agents in the
`agents/` folder where the old app keeps `managed-agents.json`. The human key
is in keychain service `xyz.block.buzz.desktop.identity`, which Block's own
Buzz 1.0 uses too; harness homes are under `~/Library/Application Support/Buzz`.
Never confirm the agent-protection storage upgrade while the old app is still
needed: it is one-way for older Buzz 1.0 builds (upstream
`docs/releases.md`).

## Upstream update

Merge the next stable upstream tag into a branch `cone-update/<tag>` (merge,
never rebase): `git fetch upstream tag <tag> && git merge <tag>`; set
`cone/UPSTREAM` to it, `just cone-shallow-check`, `just cone-build-env-check`,
build locally, then a pull request to `cone` (`gh pr create -R
ConeDigital/cone-buzz-app`) that lists any workflow the merge adds; right
after it merges, disable each (`gh workflow disable -R
ConeDigital/cone-buzz-app <name>`): every upstream workflow stays disabled.
Re-read the trigger signals and the facts in `cone-buzz-infra`
`docs/upstream.md` at each update.

## Release

1. Merge to `cone` by pull request (`gh pr create -R ConeDigital/cone-buzz-app`:
   in this fork `gh` may default to `block/buzz-app`).
2. Tag the merge commit and push the tag:
   `git tag cone-desktop-v2.Y.Z origin/cone && git push origin cone-desktop-v2.Y.Z`.
   The line is `2.x` (ADR-340 decision 9); the old app's line ended at `1.1.x`.
3. The owner approves the run (Actions → the run → *Review deployments* →
   `cone-release`). Both builds wait for it; no one approves through the API.
4. The run builds Apple silicon and Intel, signs the app, the helpers Buzz 1.0
   bundles in `Contents/Resources/bin` (`cone/sign-nested.sh`) and the DMG,
   notarizes and staples the app and the DMG, verifies them (`codesign`,
   `spctl`, `stapler`, the entitlements, Team ID, hardened runtime and `lipo`
   on every executable, `buzz --help`; Cone's feed and key compiled in,
   Block's feeds absent), makes each updater archive from the stapled app
   and signs it with the updater key, and creates the GitHub Release with
   both DMGs, both `.app.tar.gz`, both `.sig` and `SHA256SUMS`.
5. If Apple is still working when the run's time is up, the run fails with
   the command that resumes it, and its state is an artifact for 14 days:
   `gh workflow run cone-desktop.yml -R ConeDigital/cone-buzz-app --ref cone-desktop-v2.Y.Z -f resume_run_id=<run>`.
   The owner approves the resume like any run; it continues where the run
   stopped, never rebuilding or resubmitting what Apple already has.
6. **Promote** — the release reaches installed apps only now:
   `gh workflow run cone-desktop.yml -R ConeDigital/cone-buzz-app --ref cone-desktop-v2.Y.Z -f promote=cone-desktop-v2.Y.Z`,
   approved by the owner. It verifies both archives against `cone/updater.pub`
   and `SHA256SUMS`, writes `latest.json` and uploads it to the object
   `2/latest.json` in the R2 bucket `cone-desktop-updates`, then reads it back
   through `https://buzz.cone.digital/desktop/2/latest.json`. It refuses an
   older version than the object holds and any other object
   (`cone/promote-check.sh`), and fails if the old app's feed
   (`/desktop/latest.json`, the bucket root) changed by a byte.

Secrets are in the environment `cone-release` only (deployments from tags
`cone-desktop-v*`, the owner a required reviewer); their sources are in
1Password `Cone Buzz Backup Keys`. `cone/updater.pub` is the old app's key
(minisign `A11AAB7556EB3BE2`): never change it.
