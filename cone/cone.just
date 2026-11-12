# Cone Desktop recipes on Buzz 1.0 (Slice 48, cone-buzz-infra
# slices/48-cone-desktop-on-buzz-app.md; the layout of Slice 29's fork).
# Imported by the root justfile with one line; everything else Cone adds lives
# under cone/ (decision 1). No recipe here changes a tracked file outside cone/.

# Paths a Cone commit may change, relative to the pinned upstream tag.
cone_allowed := "^(cone/.*|\\.github/workflows/cone-desktop\\.yml|justfile)$"

# The fork stays shallow (criterion 2): every path that differs from the pinned
# upstream tag is under cone/, is the Cone workflow, or is the justfile with
# exactly the one import line added. Judges HEAD and the working tree. The pin
# is a stable upstream tag vX.Y.Z, never a beta or a preview (ADR-340 as
# amended by Slice 48 merge 1).
cone-shallow-check:
    #!/usr/bin/env bash
    set -euo pipefail
    base="$(tr -d '[:space:]' < cone/UPSTREAM)"
    [[ "$base" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || { echo "cone-shallow-check: cone/UPSTREAM holds '$base', not a stable upstream tag vX.Y.Z" >&2; exit 1; }
    git rev-parse --verify --quiet "$base^{commit}" >/dev/null || { echo "cone-shallow-check: $base is not a commit here (git fetch upstream tag $base)" >&2; exit 1; }
    paths="$( { git diff --name-only --no-renames "$base" HEAD; git status --porcelain --untracked-files=all | cut -c4-; } | sed '/^$/d' | sort -u)"
    bad="$(printf '%s\n' "$paths" | grep -Ev '{{cone_allowed}}' || true)"
    if [[ -n "$bad" ]]; then printf 'cone-shallow-check: outside cone/:\n%s\n' "$bad" >&2; exit 1; fi
    if printf '%s\n' "$paths" | grep -qx justfile; then
      added="$(git diff --no-renames "$base" -- justfile | grep '^+' | grep -v '^+++' || true)"
      removed="$(git diff --no-renames "$base" -- justfile | grep '^-' | grep -v '^---' || true)"
      if [[ -n "$removed" || "$added" != "+import 'cone/cone.just'" ]]; then
        printf 'cone-shallow-check: the justfile may only gain the import line; diff:\n%s\n%s\n' "$removed" "$added" >&2; exit 1
      fi
    fi
    echo "cone-shallow-check: ok ($(printf '%s\n' "$paths" | grep -c . || true) path(s) differ from $base, all Cone's)"

# The build's configuration is exactly cone/build.env: with a leftover value
# planted for every BUZZ_* name the build's readers mention (and one they do
# not), cone_build_env leaves each name cone/build.env sets at that value —
# empty included — and every other name unset; a repository-root env file
# makes it refuse.
cone-build-env-check:
    #!/usr/bin/env bash
    set -euo pipefail
    . cone/build-env.sh
    planted=(BUZZ_CONE_PLANTED_UNKNOWN $(cone_build_vars))
    for v in "${planted[@]}"; do export "$v=leftover-$v"; done
    cone_build_env
    bad=0
    for v in "${planted[@]}"; do
      if grep -qE "^$v=" cone/build.env; then
        want="$(grep -E "^$v=" cone/build.env | tail -n 1 | cut -d= -f2-)"
        [[ -n "${!v+x}" && "${!v}" == "$want" ]] || { echo "cone-build-env-check: $v is '${!v-<unset>}', not '$want'" >&2; bad=1; }
      else
        [[ -z "${!v+x}" ]] || { echo "cone-build-env-check: $v is '${!v}', but cone/build.env does not set it" >&2; bad=1; }
      fi
    done
    scratch="$(mktemp -d)"
    trap 'rm -rf "$scratch"' EXIT
    mkdir -p "$scratch/repo/src-tauri" && cp -R cone vite.config.ts "$scratch/repo/" && cp src-tauri/build.rs "$scratch/repo/src-tauri/"
    if (cd "$scratch/repo" && : > .env.local && . cone/build-env.sh && cone_build_env) 2>/dev/null; then
      echo "cone-build-env-check: a repository-root .env.local did not stop cone_build_env" >&2; bad=1
    fi
    (( bad == 0 )) || exit 1
    echo "cone-build-env-check: ok (${#planted[@]} names planted, each as cone/build.env sets it or unset; an env file refused)"

# Build the Cone Desktop for one Apple target, unsigned (ad-hoc), with
# upstream's pinned toolchain (bin/activate-hermit). `version` goes into the
# build through a --config delta outside the tree, as upstream's
# scripts/candidate-version.mjs does; no tracked file is edited. Merge 2 adds
# the Developer ID, notarization and the updater.
cone-desktop-build target="aarch64-apple-darwin" version="2.0.0-local":
    #!/usr/bin/env bash
    set -euo pipefail
    TARGET={{quote(target)}}
    VERSION={{quote(version)}}
    [[ "$(uname -s)" == Darwin && "$TARGET" =~ ^(aarch64|x86_64)-apple-darwin$ ]] || { echo "cone-desktop-build: aarch64-apple-darwin or x86_64-apple-darwin, on macOS" >&2; exit 2; }
    [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || { echo "cone-desktop-build: '$VERSION' is not SemVer" >&2; exit 2; }
    . bin/activate-hermit >/dev/null
    just cone-shallow-check
    just cone-build-env-check
    . cone/build-env.sh
    cone_build_env
    rustup target add "$TARGET" >/dev/null
    export APPLE_SIGNING_IDENTITY="${APPLE_SIGNING_IDENTITY:--}"
    pnpm install --frozen-lockfile
    # The second delta: the version, and no updater artifacts (merge 1).
    delta="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/cone-build.XXXXXX")/tauri.version.conf.json"
    node -e 'require("fs").writeFileSync(process.argv[1], JSON.stringify({ version: process.argv[2], bundle: { createUpdaterArtifacts: false } }, null, 2) + "\n")' "$delta" "$VERSION"
    rm -rf "target/$TARGET/release/bundle"
    # CI=true makes Tauri's bundle_dmg.sh skip its Finder AppleScript (the
    # window layout and the background), which needs an Automation grant on a
    # workstation; the release (merge 2) sets TAURI_BUNDLER_DMG_IGNORE_CI=true.
    CI=true pnpm tauri build --ci --bundles app,dmg --target "$TARGET" --config "$PWD/cone/tauri.cone.conf.json" --config "$delta" -- --locked
    bundle="target/$TARGET/release/bundle"
    plist="$bundle/macos/Cone.app/Contents/Info.plist"
    for k in CFBundleName CFBundleDisplayName CFBundleIdentifier CFBundleShortVersionString NSMicrophoneUsageDescription; do
      printf '%s = %s\n' "$k" "$(/usr/libexec/PlistBuddy -c "Print :$k" "$plist" 2>/dev/null || echo '<absent>')"
    done
    ls -1 "$bundle/dmg/"
    left="$(git status --porcelain --untracked-files=all | sed '/^$/d' || true)"
    [[ -z "$left" ]] || { printf 'cone-desktop-build: the tree is not clean after the build:\n%s\n' "$left" >&2; exit 1; }
    echo "cone-desktop-build: $bundle/macos/Cone.app, tree clean"
