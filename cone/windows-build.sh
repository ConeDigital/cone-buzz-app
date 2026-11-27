#!/usr/bin/env bash
# The Cone Desktop for Windows x86_64: Tauri's NSIS installer (cone-buzz-infra
# Slice 48 decisions W2, W3, W5 and W7, ADR-492). The Windows counterpart of
# cone.just's cone-desktop-build: a script, because a Windows runner has
# neither hermit nor just. Run in Git Bash from anywhere, with upstream's
# pinned Rust, Node and pnpm on PATH and `pnpm install --frozen-lockfile`
# done:
#
#   cone/windows-build.sh compile <version> [--release]
#   cone/windows-build.sh bundle <version> [--release <sign-delta>]
#   cone/windows-build.sh <version>            both, unsigned (a local check)
#   → target/release/bundle/nsis/Cone_<version>_x64-setup.exe (+ .sig with --release)
#
# Two phases, because the signature must come from a fresh Azure sign-in:
# GitHub's OIDC assertion lives minutes, the compile half an hour, and Tauri
# signs only while it bundles. `compile` is `tauri build --no-bundle`: the
# rebrand applied, scanned, the frontend and the binaries built, the bundle
# gate on the built frontend, the tree restored and clean. `bundle` is `tauri
# bundle --bundles nsis` with the same --config deltas, on that clean tree:
# Tauri patches and signs Buzz.exe, signs each bin\*.exe helper, the NSIS
# plugins, the uninstaller and the installer, and with the updater key writes
# the installer's .sig last (tauri-cli 2.12.3 bundle.rs, tauri-bundler 2.10.3
# bundle.rs and windows/nsis/mod.rs). The rebrand changes only source files
# the compile reads; the bundler reads none of them.
#
# The configuration is the Macs': cone/build.env through cone_build_env,
# cone/tauri.cone.conf.json, the release delta (the version, Cone's updater
# key and feed) and the window delta from the functions cone.just uses, then
# the Windows-only delta cone/tauri.cone.windows.conf.json (the publisher,
# decision W5), never cone/tauri.cone.conf.json's shared keys.
#
# Unsigned (no --release): no secret is read — TAURI_SIGNING_PRIVATE_KEY set
# is refused, createUpdaterArtifacts is false, the bundle runs with --no-sign.
# --release: createUpdaterArtifacts true; the bundle needs the updater key in
# the environment and <sign-delta>, cone/windows-sign.sh's
# bundle.windows.signCommand, passed last and only to the bundle.
#
# The compile leaves its deltas and what it built from (the version, the
# mode, the commit) in ${RUNNER_TEMP:-$TEMP}/cone-windows-build; the bundle
# reuses those very files and refuses another version, mode or commit.
set -euo pipefail
CALLER_PWD="$PWD"
cd "$(dirname "${BASH_SOURCE[0]}")/.."

die() { echo "windows-build: $*" >&2; exit 1; }
usage() { die "usage: cone/windows-build.sh compile <version> [--release] | bundle <version> [--release <sign-delta>] | <version>"; }

TARGET=x86_64-pc-windows-msvc
case "$(uname -s)" in MINGW* | MSYS*) ;; *) die "runs in Git Bash on Windows (the macOS build is just cone-desktop-build)" ;; esac

# Tauri's CLI runs in src-tauri and reads --config files there, so every
# path it is given is absolute, in the D:/… form a Windows program takes.
winpath() { cygpath -m "$1"; }
STATE="$(cygpath -u "${RUNNER_TEMP:-$TEMP}")/cone-windows-build"
BUNDLE=target/release/bundle/nsis

clean_tree() { # <when>
  local left
  left="$(git status --porcelain --untracked-files=all | sed '/^$/d' || true)"
  [[ -z "$left" ]] || die "the tree is not clean $1:"$'\n'"$left"
}

check_version() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || die "'$1' is not SemVer"
}

# The --config files every phase passes, in order (decision W5: the Windows
# delta after the shared one, the release delta last).
configs() {
  local c
  for c in "$PWD/cone/tauri.cone.conf.json" "$PWD/cone/tauri.cone.windows.conf.json" "$STATE/tauri.cone-windows.conf.json" "$STATE/tauri.release.conf.json"; do
    printf -- '--config\n%s\n' "$(winpath "$c")"
  done
}

cmd_compile() { # <version> <release: true|false>
  local version="$1" release="$2" host args=()
  check_version "$version"
  host="$(rustc -vV | sed -n 's/^host: //p')"
  [[ "$host" == "$TARGET" ]] || die "Rust's host is '$host', not $TARGET: the installer is built natively, as upstream's is"
  # The compile never needs the updater key: only the bundle signs.
  [[ -z "${TAURI_SIGNING_PRIVATE_KEY:-}" ]] || die "TAURI_SIGNING_PRIVATE_KEY is set: the compile reads no secret (only the bundle does)"
  clean_tree "before the build"

  # shellcheck source=cone/build-env.sh
  . cone/build-env.sh
  cone_build_env
  rm -rf "$STATE"
  mkdir -p "$STATE"
  cone_release_delta "$(winpath "$STATE/tauri.release.conf.json")" "$version" "$release"
  echo "updater: $BUZZ_UPDATER_ENDPOINT, updater artifacts $release"

  # The in-app rebrand (cone-buzz-infra Slice 51, ADR-364), as on the Macs:
  # rewrite the working copy, scan it, build, gate the built frontend, put
  # every file back; the trap restores on any failure.
  local root="$PWD"
  trap 'cd "$root" && cone/rebrand.sh restore' EXIT
  cone/rebrand.sh apply
  cone/rebrand.sh scan
  cone_window_delta "$TARGET" "$STATE/tauri.cone-windows.conf.json"
  rm -rf "$BUNDLE"
  while IFS= read -r a; do args+=("$a"); done < <(configs)
  # Upstream's own Windows build (desktop-build.yml, job windows): the host's
  # target, so the binaries are under target/release.
  pnpm tauri build --ci --no-bundle "${args[@]}" -- --locked
  cone/rebrand.sh bundle-scan
  cone/rebrand.sh restore
  trap - EXIT
  clean_tree "after the compile"
  printf 'version=%s\nrelease=%s\ncommit=%s\n' "$version" "$release" "$(git rev-parse HEAD)" > "$STATE/compiled"
  echo "windows-build: compiled $version (release $release) at $(git rev-parse --short HEAD), tree clean"
}

cmd_bundle() { # <version> <release: true|false> [sign-delta]
  local version="$1" release="$2" sign="${3:-}" want args=() sign_args=()
  check_version "$version"
  [[ -f "$STATE/compiled" ]] || die "no compile in $STATE: run cone/windows-build.sh compile first"
  want="$(printf 'version=%s\nrelease=%s\ncommit=%s' "$version" "$release" "$(git rev-parse HEAD)")"
  [[ "$(cat "$STATE/compiled")" == "$want" ]] \
    || die "the compile in $STATE was another build:"$'\n'"$(cat "$STATE/compiled")"$'\n'"not:"$'\n'"$want"
  clean_tree "before the bundle"
  if [[ "$release" == true ]]; then
    [[ -n "${TAURI_SIGNING_PRIVATE_KEY:-}" ]] || die "--release needs the updater key (TAURI_SIGNING_PRIVATE_KEY) for the installer's .sig"
    [[ -f "$sign" ]] || die "--release needs the signing delta from cone/windows-sign.sh prepare (got '$sign')"
    node -e 'const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).bundle.windows.signCommand;
      if (typeof s !== "object" || typeof s.cmd !== "string" || !s.args.includes("%1")) process.exit(1);' "$sign" \
      || die "$sign holds no object-form bundle.windows.signCommand with \"%1\""
    sign_args=(--config "$(winpath "$sign")")
  else
    [[ -z "${TAURI_SIGNING_PRIVATE_KEY:-}" ]] || die "TAURI_SIGNING_PRIVATE_KEY is set: this build is unsigned and makes no updater signature"
    sign_args=(--no-sign)
  fi

  # The same process environment the compile had (build.rs does not run
  # again; the bundler reads the --config files).
  # shellcheck source=cone/build-env.sh
  . cone/build-env.sh
  cone_build_env
  rm -rf "$BUNDLE"
  while IFS= read -r a; do args+=("$a"); done < <(configs)
  pnpm tauri bundle --ci --bundles nsis "${args[@]}" "${sign_args[@]}"

  shopt -s nullglob
  local installers=("$BUNDLE"/*.exe) sigs=("$BUNDLE"/*.sig)
  shopt -u nullglob
  local exe="Cone_${version}_x64-setup.exe"
  [[ "${#installers[@]}" -eq 1 && "${installers[0]}" == "$BUNDLE/$exe" ]] \
    || die "expected exactly $BUNDLE/$exe, found: ${installers[*]:-nothing}"
  if [[ "$release" == true ]]; then
    # Tauri only warns when the key does not match the configured public key;
    # the release job verifies the .sig against cone/updater.pub.
    [[ "${#sigs[@]}" -eq 1 && "${sigs[0]}" == "$BUNDLE/$exe.sig" && -s "${sigs[0]}" ]] \
      || die "expected exactly $BUNDLE/$exe.sig, found: ${sigs[*]:-nothing}"
  else
    [[ "${#sigs[@]}" -eq 0 ]] || die "an unsigned build made an updater signature: ${sigs[*]}"
  fi
  clean_tree "after the bundle"
  ls -l "$BUNDLE"
  echo "windows-build: $BUNDLE/$exe$([[ "$release" == true ]] && echo ' and its .sig'), tree clean"
}

phase="${1:-}"
case "$phase" in
  compile | bundle) shift ;;
  -* | '') usage ;;
  *) phase=all ;;
esac
version="${1:-}"
[[ -n "$version" ]] || usage
shift
release=false sign=""
if (( $# > 0 )); then
  [[ "$1" == --release && "$phase" != all ]] || usage
  release=true
  shift
  if [[ "$phase" == bundle ]]; then
    (( $# == 1 )) || usage
    sign="$1"
    [[ "$sign" == /* || "$sign" == [A-Za-z]:* ]] || sign="$CALLER_PWD/$sign"
    shift
  fi
fi
(( $# == 0 )) || usage

case "$phase" in
  compile) cmd_compile "$version" "$release" ;;
  bundle) cmd_bundle "$version" "$release" "$sign" ;;
  all) cmd_compile "$version" false && cmd_bundle "$version" false ;;
esac
