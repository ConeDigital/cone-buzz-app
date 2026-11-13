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
The window says "Cone" too: the in-app rebrand (`cone-buzz-infra` Slice 51,
ADR-364) rewrites the build's working copy and puts it back, so the tracked
tree still differs from the tag under `cone/` only.

| Path | What |
|------|------|
| `UPSTREAM` | the pinned upstream tag: a stable `vX.Y.Z`, never a beta, a preview or an internal `desktop-v*` tag |
| `build.env` | the build-time configuration (no secret): the default community, Builderlab set empty on purpose |
| `build-env.sh` | refuses a repository-root `.env*`, clears every `BUZZ_*` the build reads or the shell exports, then loads `build.env` |
| `tauri.cone.conf.json` | the Tauri config delta: name, identifier, icons, `Info.plist`, DMG layout and background |
| `Info.plist`, `icons/`, `make-assets.py` | the menu-bar name and the microphone usage string; the icons and DMG background, generated from `icons/source.png` |
| `cone.just` | `cone-desktop-build`, `cone-shallow-check`, `cone-build-env-check`, `cone-rebrand-check`, `cone-rebrand-test`, `cone-notarize-test`, `cone-updater-test` |
| `rebrand.sh`, `rebrand/`, `rebrand-test.sh` | the in-app rebrand: the transform, its manifests and replacement pictures, its mutation test (below) |
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

## The in-app rebrand

`cone/rebrand.sh apply` replaces every capitalised `Buzz` in the string text
of what the app ships with `cone/rebrand/word` (`Cone`), by exact count, and
`restore` puts the files back; `cone-desktop-build` does both around `tauri
build`. What is in scope: TypeScript/TSX/JS under `src/` (not tests),
`public/*.js` and `*.svg`, the root HTML pages, Rust in `src-tauri/src` and
every crate it links plus `crates/agent-command`, and — whole, comments
included — every file the app imports as a string (`?raw`, Markdown, JSON)
or embeds with `include_str!`. `node cone/rebrand/transform.mjs scope` lists it.

| Manifest | What |
|----------|------|
| `strings.tsv` | path and the exact count of the word in its string text. Written by `cone/rebrand.sh measure` |
| `keep.tsv` | text whose `Buzz` is a name another program reads (relay headers, the relay's NIP-11 name, the huddle marker, harness homes on disk, `TERM_PROGRAM`, the phone app's name): left alone, and its count must hold |
| `lines.tsv` | exact text replacements (the share card's mark and its "BUZZ AGENT") |
| `replacements.tsv` | whole files from `rebrand/files/`, each pinned to the upstream file's SHA-256 (the wordmark, marks, the QR icon); `make-rebrand-assets.py` renders the PNGs |
| `exceptions.tsv` | residue-scan hits that stay, each with a reason |

The window title is not in `tauri.cone.conf.json`: `transform.mjs
window-delta <target>` writes upstream's own window settings for that
platform with the title changed, as a `--config` delta per build.

`just cone-rebrand-check` applies, scans for `Buzz`, `BUZZ`, `Block` and
bees, builds the frontend, checks the bundle and restores; `just
cone-rebrand-test` plants seventeen mutations, each of which must fail.
Both run on every pull request.

**When the check fails on an upstream update:** a count in `strings.tsv` —
run `cone/rebrand.sh measure > /tmp/s && head -1 cone/rebrand/strings.tsv | cat - /tmp/s > cone/rebrand/strings.tsv`
on a clean tree, read the diff, and look at each new hit (`node
cone/rebrand/transform.mjs hits`): a name another program reads goes into
`keep.tsv`, everything else is rebranded by the rule. A `keep.tsv` count —
upstream added or dropped a use of that name: decide which. A hash in
`replacements.tsv` — `git diff <old> <new> -- <path>`, carry the change into
`rebrand/files/<path>` or say why not, then update the hash. A residue —
a row or an exception with a reason.

## Upstream update

Merge the next stable upstream tag into a branch `cone-update/<tag>` (merge,
never rebase): `git fetch upstream tag <tag> && git merge <tag>`; set
`cone/UPSTREAM` to it, `just cone-shallow-check`, `just cone-build-env-check`,
`just cone-rebrand-check` (fix what it names, above), build locally, then a pull request to `cone` (`gh pr create -R
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
