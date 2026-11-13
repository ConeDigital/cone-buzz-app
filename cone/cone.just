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
      if [[ "$v" == BUZZ_UPDATER_PUBLIC_KEY ]]; then
        want="$(tr -d '[:space:]' < cone/updater.pub)"
        [[ "${!v-}" == "$want" ]] || { echo "cone-build-env-check: $v is '${!v-<unset>}', not cone/updater.pub's key" >&2; bad=1; }
      elif grep -qE "^$v=" cone/build.env; then
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
    echo "cone-build-env-check: ok (${#planted[@]} names planted, each as cone/build.env sets it, the updater key as cone/updater.pub holds it, or unset; an env file refused)"

# Build the Cone Desktop for one Apple target with upstream's pinned toolchain
# (bin/activate-hermit). `version` and the updater (Cone's key and feed, from
# cone_build_env) go into the build through a --config delta outside the tree,
# as upstream's scripts/candidate-version.mjs does; no tracked file is edited.
# Without a Developer ID in the environment the app is ad-hoc signed (a local
# build); the release workflow supplies APPLE_SIGNING_IDENTITY and KEYCHAIN,
# and then cone/sign-nested.sh signs the helpers Tauri leaves unsigned. With
# the updater key in the environment Tauri also makes and signs its own
# Cone.app.tar.gz — before notarization, so the release replaces it
# (cone/updater-archive.sh); here it proves the key and password early.
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
    # The second delta: the version and the updater (RFC 7396 replaces any
    # endpoints array); the same key and endpoint build.rs compiles in.
    delta="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/cone-build.XXXXXX")/tauri.release.conf.json"
    artifacts=false
    [[ -n "${TAURI_SIGNING_PRIVATE_KEY:-}" ]] && artifacts=true
    node -e 'const [file, version, pubkey, endpoint, artifacts] = process.argv.slice(1);
      require("fs").writeFileSync(file, JSON.stringify({ version, bundle: { createUpdaterArtifacts: artifacts === "true" },
        plugins: { updater: { pubkey, endpoints: [endpoint] } } }, null, 2) + "\n");' \
      "$delta" "$VERSION" "$BUZZ_UPDATER_PUBLIC_KEY" "$BUZZ_UPDATER_ENDPOINT" "$artifacts"
    echo "updater: $BUZZ_UPDATER_ENDPOINT, updater artifacts $artifacts"
    # The in-app rebrand (cone-buzz-infra Slice 51, ADR-364): cone/rebrand.sh
    # rewrites the working copy (exact manifests, the residue scan) after the
    # shallowness check has judged the source, and the trap puts every file
    # back. The window's title is a third delta, made from upstream's own
    # window settings for this target's platform.
    root="$PWD"
    trap 'cd "$root" && cone/rebrand.sh restore' EXIT
    cone/rebrand.sh apply
    cone/rebrand.sh scan
    windows="$(dirname "$delta")/tauri.cone-windows.conf.json"
    node cone/rebrand/transform.mjs window-delta "$TARGET" > "$windows"
    rm -rf "target/$TARGET/release/bundle"
    # CI=true makes Tauri's bundle_dmg.sh skip its Finder AppleScript (the
    # window layout and the background), which needs an Automation grant on a
    # workstation; the release (merge 2) sets TAURI_BUNDLER_DMG_IGNORE_CI=true.
    CI=true pnpm tauri build --ci --bundles app,dmg --target "$TARGET" --config "$PWD/cone/tauri.cone.conf.json" --config "$windows" --config "$delta" -- --locked
    cone/rebrand.sh bundle-scan
    # Put the tree back now (the trap stays for the failure paths); the clean
    # tree is asserted at the end.
    cone/rebrand.sh restore
    trap - EXIT
    bundle="target/$TARGET/release/bundle"
    if [[ "$APPLE_SIGNING_IDENTITY" != - ]]; then cone/sign-nested.sh "$bundle/macos/Cone.app"; fi
    plist="$bundle/macos/Cone.app/Contents/Info.plist"
    for k in CFBundleName CFBundleDisplayName CFBundleIdentifier CFBundleShortVersionString NSMicrophoneUsageDescription; do
      printf '%s = %s\n' "$k" "$(/usr/libexec/PlistBuddy -c "Print :$k" "$plist" 2>/dev/null || echo '<absent>')"
    done
    ls -1 "$bundle/dmg/"
    left="$(git status --porcelain --untracked-files=all | sed '/^$/d' || true)"
    [[ -z "$left" ]] || { printf 'cone-desktop-build: the tree is not clean after the build:\n%s\n' "$left" >&2; exit 1; }
    echo "cone-desktop-build: $bundle/macos/Cone.app, tree clean"

# The in-app rebrand is exact (Slice 51 criterion 1, ADR-364): every
# replacement's upstream hash, every lines.tsv row and every strings.tsv and
# keep.tsv count holds; the residue scan over every file in scope finds no
# "Buzz", "Block" or bee outside cone/rebrand/exceptions.tsv; the transformed
# frontend type-checks and builds and its bundle carries the word only inside
# kept runtime names; the tree is restored. Refuses a dirty tree under the
# paths it rewrites (they would be restored to HEAD).
cone-rebrand-check:
    #!/usr/bin/env bash
    set -euo pipefail
    . bin/activate-hermit >/dev/null
    cone/rebrand.sh check --build

# Planted changes, each committed in a disposable worktree, each failing the
# check naming the path (cone/rebrand-test.sh lists them).
cone-rebrand-test:
    #!/usr/bin/env bash
    set -euo pipefail
    . bin/activate-hermit >/dev/null
    bash cone/rebrand-test.sh

# cone/updater-verify.sh and cone/promote-check.sh against throwaway keys'
# signatures and planted feeds (cone/test/updater).
cone-updater-test:
    bash cone/updater-test.sh

# cone/notarize.sh, cone/release-advance.sh and cone/updater-archive.sh
# against mocks of xcrun, hdiutil and codesign: acceptance, a dropped request
# and a held copy, refusal, the deadline, a resume at every stage.
cone-notarize-test:
    bash cone/notarize-test.sh
