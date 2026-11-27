# Cone Desktop (Buzz 1.0)

Cone's build of Buzz 1.0 (`block/buzz-app`): upstream's app at the stable tag
in `cone/UPSTREAM`, named, iconed and configured for `buzz.cone.digital`. The
plan and its record are in `cone-buzz-infra`,
`slices/48-cone-desktop-on-buzz-app.md` (ADR-340, amended by ADR-353). The old
Cone app (`1.1.x`, Buzz 0.X) is built from `ConeDigital/cone-buzz` and stays
there until every Mac has moved.

**The fork stays shallow:** everything Cone adds is under `cone/`, plus one
`import 'cone/cone.just'` line in the root `justfile` and
`.github/workflows/cone-desktop.yml` and `cone-upstream.yml`. `just cone-shallow-check` refuses any
other path, locally and on every pull request. Never change an upstream file.
The window says "Cone" too: the in-app rebrand (`cone-buzz-infra` Slice 51,
ADR-364) rewrites the build's working copy and puts it back, so the tracked
tree still differs from the tag under `cone/` only.

| Path | What |
|------|------|
| `UPSTREAM` | the pinned upstream tag: a stable `vX.Y.Z`, never a beta, a preview or an internal `desktop-v*` tag |
| `build.env` | the build-time configuration (no secret): the default community, Builderlab set empty on purpose |
| `build-env.sh` | refuses a repository-root `.env*`, clears every `BUZZ_*` the build reads or the shell exports, then loads `build.env`; the release and window `--config` deltas both platforms' builds write (`cone_release_delta`, `cone_window_delta`) |
| `tauri.cone.conf.json` | the Tauri config delta: name, identifier, icons, `Info.plist`, DMG layout and background |
| `tauri.cone.windows.conf.json` | the Windows-only delta: the publisher (`Cone Digital AB`, confirmed by the owner; the one place it is set) and the setup and uninstaller icons (`icons/icon.ico`; NSIS's generic icon otherwise) |
| `windows-build.sh` | the Windows x86_64 NSIS installer in two phases, `compile` and `bundle`, unsigned or (`--release`) signed (below) |
| `windows-sign.lock`, `windows-sign.sh`, `windows-sign-test.sh` | the Authenticode signature (Azure Artifact Signing): the pinned dlib package and its SHA-256, the metadata, the `signCommand` delta, the token warm-up, the probe's signing; their test against mocks |
| `windows-install-check.ps1`, `windows-signature-check.ps1` | what the installer lays down, checked on the runner (`-Signed`: every executable signed by the publisher and timestamped) |
| `workflow-test.mjs` | which jobs of `cone-desktop.yml` run for which event and ref (the sign probe above all), the workflow's standing rules, and planted changes each failing a named check |
| `Info.plist`, `icons/`, `make-assets.py` | the menu-bar name and the microphone usage string; the icons and DMG background, generated from `icons/source.png`; `icon.ico` (Windows only) is the mark full-bleed (`make-assets.py ico`) |
| `cone.just` | `cone-desktop-build`, `cone-shallow-check`, `cone-build-env-check`, `cone-rebrand-check`, `cone-rebrand-test`, `cone-notarize-test`, `cone-updater-test`, `cone-upstream-test`, `cone-sign-test`, `cone-workflow-test` |
| `rebrand.sh`, `rebrand/`, `rebrand-test.sh` | the in-app rebrand: the transform, its manifests and replacement pictures, its mutation test (below) |
| `upstream-watch.sh`, `upstream-test.sh` | the upstream watcher (below): the update pull request for each new stable tag, the tag after it merges, the workflow guard; their test |
| `updater.pub` | the updater's public key (minisign `A11AAB7556EB3BE2`, the old app's), compiled into every build with the feed `https://buzz.cone.digital/desktop/2/latest.json` |
| `sign-nested.sh` | signs the helpers Buzz 1.0 bundles in `Contents/Resources/bin` (Tauri leaves them linker-signed), then the app |
| `notarize.sh`, `release-advance.sh`, `notarize-test.sh` | notarization (submit; wait through dropped requests; staple), the resumable stages of one architecture's release, and their test against mocks |
| `updater-archive.sh`, `updater-verify.sh`, `promote-check.sh`, `updater-test.sh`, `test/updater/` | the updater archive from the stapled app; the signature check an app makes; the promotion's refusals (an older version, a platform the feed has dropped, any object but `2/latest.json`); their test, with `promote-check.sh`'s planted mutations |

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

## Windows (unsigned, a check)

`cone/windows-build.sh <version>` builds `Cone_<version>_x64-setup.exe`, an
NSIS installer for Windows x86_64 (`cone-buzz-infra` Slice 38; per user,
Tauri's default `currentUser`, so no admin rights). It runs in Git Bash on
Windows with upstream's pinned Rust, Node and pnpm (no hermit, no `just`
there): `cone_build_env`, the same release delta (no updater signature:
`createUpdaterArtifacts` false) and window delta as the Macs plus
`tauri.cone.windows.conf.json`. It is two phases, as the signed release
needs them (below): `compile` applies, scans and restores the rebrand around
`pnpm tauri build --ci --no-bundle` and gates the built frontend; `bundle`
runs `pnpm tauri bundle --ci --bundles nsis --no-sign` with the same deltas
on the clean tree. `cone/windows-build.sh <version>` runs both. It is not
Authenticode-signed: Windows warns about an unknown publisher.

The job **Windows check (unsigned)** in `cone-desktop.yml` runs it on
`windows-2025` from any branch, with no environment and no secret:

```bash
gh workflow run cone-desktop.yml -R ConeDigital/cone-buzz-app --ref <branch> -f windows_check=<version>
gh run download <run> -R ConeDigital/cone-buzz-app -n cone-desktop-windows-x64-unsigned
```

It runs the rebrand's mutation test and check on Windows, compiles, bundles,
installs the installer silently into a scratch folder of the runner, and
checks what it wrote (`cone/windows-install-check.ps1`): `Buzz.exe` (upstream's binary name, as on a Mac) and `bin\buzz.exe`,
`bin\goose-acp.exe`, `bin\buzz-agent-command.exe`; the uninstall entry's
name, publisher and version; the `buzz://` scheme registered for
`digital.cone.desktop`; the shortcuts and the user `PATH`; Cone's updater
key and feed compiled in and no Block feed; then the uninstaller. The
installer, `SHA256SUMS` and `SOURCE_COMMIT` are kept 7 days as the artifact
`cone-desktop-windows-x64-unsigned`. Never distribute it: the signed
release is a later change. A check runs in its own concurrency group
(`cone-desktop-windows-check-<ref>`), so it never replaces a pending
release, resume or promotion of the same tag.

What the first green run showed (run 45972802521, `2.5.0-windows.1`, 45 min
cold; the Rust build 29 min of it): a 60 MiB installer that lays down
`Buzz.exe` (168 MB), `bin\buzz.exe`, `bin\goose-acp.exe`,
`bin\buzz-agent-command.exe`, `bin\.gitkeep` and `uninstall.exe`; Apps &
features shows `Cone`, `Cone Digital AB`, the version; the exe's version
resource says `Cone` and `Cone Digital AB`; the app's data folders are
`%APPDATA%` and `%LOCALAPPDATA%\digital.cone.desktop`. The feed's URL is
compiled into `Buzz.exe` whole. The bundle gate finds the word only inside
kept runtime names, 29 of them, as on a Mac. The runner's Git converts to
CRLF by default (`core.autocrlf true` in its system config), which would
break the rebrand's hashes and exact matches: the job sets it to `false`
before checking out.

## Windows (signed, the release)

The job **Build Windows x64 (signed)** (`build-windows`) runs on every
release tag beside the macOS builds, in `cone-release`, and is the check's
steps with Cone's Authenticode signature (`cone-buzz-infra` Slice 48 decision
W7, ADR-492): Azure Artifact Signing over GitHub OIDC, inside Tauri's build.

1. `cone/windows-sign.sh prepare` (before the compile, no Azure yet): the
   dlib package `Microsoft.ArtifactSigning.Client` at the version and SHA-256
   in `cone/windows-sign.lock`, its x64 dlib, the .NET runtime its
   runtimeconfig names asserted on the runner (never installed), `signtool`
   through the Windows SDK's registry root; it writes the metadata
   (endpoint, account, profile from `cone-release`, every credential type
   but `AzureCliCredential` excluded) and the per-run delta
   `bundle.windows.signCommand` in its object form, outside the tree.
2. `cone/windows-build.sh compile <v> --release` — half an hour cold.
3. `azure/login` (OIDC, the app registration's one federated credential),
   then at once `cone/windows-sign.sh token`: the Azure CLI fetches the
   token the dlib asks for while GitHub's assertion (minutes) is fresh, and
   caches it (an hour or more).
4. `cone/windows-build.sh bundle <v> --release <delta>` with the updater key:
   Tauri signs `Buzz.exe`, the `bin\` helpers, the NSIS plugins, the
   uninstaller and the installer, and writes the installer's `.sig` last.
5. `cone/windows-install-check.ps1 -Signed`: the installer, `Buzz.exe`, every
   helper and the installed `uninstall.exe` signed by `Cone Digital AB` and
   timestamped (`signtool verify /pa /all /tw` and
   `Get-AuthenticodeSignature`), with every check of the unsigned build.

The release (`release`) needs both macOS builds and `build-windows`, verifies
the installer's `.sig` against `updater.pub` and publishes
`Cone_<v>_x64-setup.exe` and its `.sig` with the DMGs and archives;
`SHA256SUMS` covers it. A resume carries the installer over from the run it
resumes (`windows-resume`); if that run's Windows job failed, re-run it there.

**The sign probe** proves the signing on two small test executables before
any build uses it. The environment admits only `cone-desktop-v*` tags, so a
probe is a tag `cone-desktop-v0.0.0-signprobe.N`: its push runs the job
`sign-probe` alone (the owner approves it), which prepares, signs one file at
once and the second after GitHub's assertion has expired, and verifies both.
Every job that builds, releases or promotes refuses such a ref in its own
condition; `cone/workflow-test.mjs` proves which jobs run for it. A probe tag
can be deleted afterwards; nothing refers to it.

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
| `lines.tsv` | exact text replacements: the share card's mark and its "BUZZ AGENT"; the default accent `iris` (purple); the welcome screen in Cone's colours — the logo's purple-red-orange gradient, white lettering, white and peach marks, the onboarding cards' tint |
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

**The watcher does this** (`cone-buzz-infra` Slice 54, ADR-375):
`.github/workflows/cone-upstream.yml` runs daily (05:23 UTC) and on demand
(Actions → *Cone upstream* → *Run workflow* on `cone`, optionally with a
tag, which must be a published, non-draft, non-prerelease release). For
each stable `block/buzz-app` release newer than `UPSTREAM` it opens
**one** pull request `Upstream vX.Y.Z (cone-desktop-v2.N.0)` from
`cone-update/<tag>`: the tag merged, `UPSTREAM` set, `strings.tsv`
re-measured, `rebrand.sh check`'s result and the triage of the commits
(security and identity, relay and membership, Windows, updater and builds,
changed upstream workflows and Tauri config). Its CI is the usual one. A
draft means the check failed: fix what it names on that branch (above).
**Merging it tags `cone-desktop-v2.<next minor>.0`** (the `tag` job, on any
push to `cone` that changes `UPSTREAM`), which starts the release below; the
build still waits for the owner. Before it tags, every active workflow
that is not Cone's is disabled, a backstop: a workflow that ran on the tag
push would otherwise start. **Nothing is pushed when the merge adds a
workflow file, or changes one that is not `disabled_manually`** (`guard`):
the branch push, the pull request or the merge would start it, and
disabling it afterwards stops no run that has started. The run fails
naming them, every day until a person handles it. **Closing it skips that tag**; the watcher never reopens
a tag that has had a pull request. **A newer tag's pull request closes the
older ones still open**, saying which supersedes them: it holds every commit
they hold and both would tag the same version (v1.0.5 and v1.0.6 waited
side by side in November 2026); a fix made by hand on the older branch is
carried over by hand. It asks the logins in the environment variable
`CONE_UPSTREAM_REVIEWERS` (comma-separated) for a review, which is what
notifies a person. It acts as the GitHub App
`cone-desktop-updater` (key in the environment `cone-upstream`), because a
pull request `GITHUB_TOKEN` opens runs no CI and `GITHUB_TOKEN` may not push
an upstream merge that touches a workflow file.

By hand, when the merge conflicts or brings a workflow (the run fails naming
the files) or the watcher is off: merge the next stable upstream tag into a branch `cone-update/<tag>` (merge,
never rebase): `git fetch upstream tag <tag> && git merge <tag>`; set
`cone/UPSTREAM` to it, `just cone-shallow-check`, `just cone-build-env-check`,
`just cone-rebrand-check` (fix what it names, above), build locally, then a pull request to `cone` (`gh pr create -R
ConeDigital/cone-buzz-app`). **Before pushing a branch that adds a workflow
file** (or changes one that is not `disabled_manually`, `gh workflow list
--all`), read its `on:`: push only when it holds nothing but
`workflow_dispatch` or `workflow_call`. Anything else can start it before
it is disabled: a push of a branch or of a tag (merging an update pushes a
`cone-desktop-v*` tag), a pull request, a schedule, `workflow_run`, a
release. Say so in the pull request; after it merges, check that the `tag`
job disabled it (`gh workflow list --all -R ConeDigital/cone-buzz-app`). Otherwise that update waits: there is no safe way yet to import a
workflow that would run (`cone-buzz-infra` Slice 54, §8).
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
4. The run builds Apple silicon, Intel and Windows x86_64 (above), signs the app, the helpers Buzz 1.0
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
   approved by the owner. It verifies both archives and the Windows
   installer against `cone/updater.pub` and `SHA256SUMS`, writes
   `latest.json` with exactly `darwin-aarch64`, `darwin-x86_64` and
   `windows-x86_64` and uploads it to the object `2/latest.json` in the R2
   bucket `cone-desktop-updates`, then reads it back through
   `https://buzz.cone.digital/desktop/2/latest.json`. It refuses an older
   version than the object holds, a manifest that drops a platform the
   object has, and any other object (`cone/promote-check.sh`), and fails if
   the old app's feed (`/desktop/latest.json`, the bucket root) changed by a
   byte. The bucket token is read from `CONE_FEED_R2_ACCESS_KEY_ID`,
   `CONE_FEED_R2_SECRET_ACCESS_KEY` and `CONE_FEED_R2_ENDPOINT` (decision W9):
   the names older tags read are deleted from `cone-release` before the first
   Windows promotion, so an older tag's two-platform promote cannot write.

Secrets are in the environment `cone-release` only (deployments from tags
`cone-desktop-v*`, the owner a required reviewer); their sources are in
1Password `Cone Buzz Backup Keys`. `cone/updater.pub` is the old app's key
(minisign `A11AAB7556EB3BE2`): never change it.
