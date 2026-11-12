#!/usr/bin/env bash
# Signs the executables Buzz 1.0 bundles as resources, then the app again
# (Slice 48 merge 2). Tauri signs Contents/MacOS/Buzz and the bundle, but the
# helpers upstream stages into Contents/Resources/bin (the `buzz` CLI,
# `buzz-agent-command`, `goose-acp`) keep the linker's ad-hoc signature, which
# Apple's notary service refuses; upstream signs them with Block's own
# codesign action. Each Mach-O file under Contents/Resources is signed with
# the hardened runtime and a secure timestamp, no entitlements (all are Rust
# executables), then the bundle with upstream's entitlements, which re-seals
# the resources. Inside-out, never --deep.
#
#   cone/sign-nested.sh <Cone.app>
#
# APPLE_SIGNING_IDENTITY names the identity (`-` signs ad hoc, without a
# timestamp: the local test of this script); KEYCHAIN, when set, is where it is.
set -euo pipefail

app="${1:?usage: cone/sign-nested.sh <Cone.app>}"
id="${APPLE_SIGNING_IDENTITY:?APPLE_SIGNING_IDENTITY is not set}"
here="$(cd "$(dirname "$0")" && pwd)"
entitlements="$here/../src-tauri/entitlements.plist"
[[ -d "$app/Contents/Resources" && -f "$entitlements" ]] || { echo "sign-nested: $app is not an app bundle, or $entitlements is missing" >&2; exit 1; }

opts=(--force --options runtime --sign "$id")
if [[ "$id" == - ]]; then opts+=(--timestamp=none); else opts+=(--timestamp); fi
[[ -z "${KEYCHAIN:-}" ]] || opts+=(--keychain "$KEYCHAIN")

n=0
while IFS= read -r -d '' f; do
  file -b "$f" | grep -q '^Mach-O' || continue
  codesign "${opts[@]}" "$f"
  echo "sign-nested: ${f#"$app/"}"
  n=$((n + 1))
done < <(find "$app/Contents/Resources" -type f -print0 | sort -z)
# Upstream ships three; none means its layout moved, and the app would reach
# Apple with whatever it now holds unsigned.
(( n > 0 )) || { echo "sign-nested: no executable under $app/Contents/Resources; upstream's layout moved — look before releasing" >&2; exit 1; }

codesign "${opts[@]}" --entitlements "$entitlements" "$app"
codesign --verify --deep --strict "$app"
echo "sign-nested: $n nested executable(s) and the app signed ($id)"
