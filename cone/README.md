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
| `cone.just` | `cone-desktop-build`, `cone-shallow-check`, `cone-build-env-check` |

## Build locally (unsigned)

```bash
. bin/activate-hermit
just cone-desktop-build aarch64-apple-darwin            # or x86_64-apple-darwin; version defaults to 2.0.0-local
# → target/<target>/release/bundle/{macos/Cone.app,dmg/Cone_<version>_<arch>.dmg}
```

Ad-hoc signed, unstyled DMG (the Finder layout needs an Automation grant on
a workstation), no updater. Never distribute a local build. The version goes
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

Merge 2 (signing, notarization, the updater, the feed at
`https://buzz.cone.digital/desktop/2/latest.json`) and merge 3 (Windows).
