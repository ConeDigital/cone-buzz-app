#!/usr/bin/env bash
# The Cone Desktop for Windows x86_64: Tauri's NSIS installer, unsigned
# (cone-buzz-infra slices/38-windows-desktop.md decisions 2, 4 and 7, on
# Slice 48's Buzz 1.0 base). The Windows counterpart of cone.just's
# cone-desktop-build: a script, because a Windows runner has neither hermit
# nor just. Run in Git Bash from anywhere, with upstream's pinned Rust, Node
# and pnpm on PATH and `pnpm install --frozen-lockfile` done:
#
#   cone/windows-build.sh <version>
#   → target/release/bundle/nsis/Cone_<version>_x64-setup.exe
#
# The same configuration as the Macs: cone/build.env through cone_build_env,
# cone/tauri.cone.conf.json, the release delta (the version, Cone's updater
# key and feed) and the window delta (upstream's own Windows window, titled
# Cone) from the functions cone.just uses; the in-app rebrand applied, scanned
# and restored around `tauri build`, the bundle gate after it, and a clean
# tree at the end. Windows-only settings (the publisher) are the delta
# cone/tauri.cone.windows.conf.json, never cone/tauri.cone.conf.json's shared
# keys (decision 7). No secret is read: there is no Authenticode signing and
# no updater signature (createUpdaterArtifacts false); the signed release is
# a later change.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

die() { echo "windows-build: $*" >&2; exit 1; }

VERSION="${1:-}"
TARGET=x86_64-pc-windows-msvc
case "$(uname -s)" in MINGW* | MSYS*) ;; *) die "runs in Git Bash on Windows (the macOS build is just cone-desktop-build)" ;; esac
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || die "usage: cone/windows-build.sh <version>; '$VERSION' is not SemVer"
host="$(rustc -vV | sed -n 's/^host: //p')"
[[ "$host" == "$TARGET" ]] || die "Rust's host is '$host', not $TARGET: the installer is built natively, as upstream's is"
[[ -z "${TAURI_SIGNING_PRIVATE_KEY:-}" ]] || die "TAURI_SIGNING_PRIVATE_KEY is set: this build is unsigned and makes no updater signature"
left="$(git status --porcelain --untracked-files=all | sed '/^$/d' || true)"
[[ -z "$left" ]] || die "the tree is not clean before the build:"$'\n'"$left"

# shellcheck source=cone/build-env.sh
. cone/build-env.sh
cone_build_env

# Tauri's CLI runs in src-tauri and reads --config files there, so every
# path it is given is absolute, in the D:/… form a Windows program takes.
winpath() { cygpath -m "$1"; }
scratch="$(mktemp -d "$(cygpath -u "${RUNNER_TEMP:-$TEMP}")/cone-build.XXXXXX")"
delta="$scratch/tauri.release.conf.json"
windows="$scratch/tauri.cone-windows.conf.json"
cone_release_delta "$(winpath "$delta")" "$VERSION" false
echo "updater: $BUZZ_UPDATER_ENDPOINT, updater artifacts false"

# The in-app rebrand (cone-buzz-infra Slice 51, ADR-364), as on the Macs:
# rewrite the working copy, scan it, build, check the bundle, put every file
# back; the trap restores on any failure.
root="$PWD"
trap 'cd "$root" && cone/rebrand.sh restore' EXIT
cone/rebrand.sh apply
cone/rebrand.sh scan
cone_window_delta "$TARGET" "$windows"
bundle="target/release/bundle/nsis"
rm -rf "$bundle"
# Upstream's own Windows build (desktop-build.yml, job windows): the host's
# target, so the bundle is under target/release.
pnpm tauri build --ci --no-sign --bundles nsis \
  --config "$(winpath "$PWD/cone/tauri.cone.conf.json")" \
  --config "$(winpath "$PWD/cone/tauri.cone.windows.conf.json")" \
  --config "$(winpath "$windows")" \
  --config "$(winpath "$delta")" \
  -- --locked
cone/rebrand.sh bundle-scan
cone/rebrand.sh restore
trap - EXIT

shopt -s nullglob
installers=("$bundle"/*.exe)
shopt -u nullglob
want="Cone_${VERSION}_x64-setup.exe"
[[ "${#installers[@]}" -eq 1 && "${installers[0]}" == "$bundle/$want" ]] \
  || die "expected exactly $bundle/$want, found: ${installers[*]:-nothing}"
left="$(git status --porcelain --untracked-files=all | sed '/^$/d' || true)"
[[ -z "$left" ]] || die "the tree is not clean after the build:"$'\n'"$left"
ls -l "$bundle/$want"
echo "windows-build: $bundle/$want, tree clean"
