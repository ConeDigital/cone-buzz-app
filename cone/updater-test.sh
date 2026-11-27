#!/usr/bin/env bash
# Tests for cone/updater-verify.sh and cone/promote-check.sh. The verifier's
# fixtures are in cone/test/updater/: two throwaway keys made with `tauri
# signer generate` (a.pub, b.pub; the private halves were deleted), payload.bin
# and other.bin signed by key a, payload.bin signed by key b. No Cone key, no
# network. Run by `just cone-updater-test` and by the release workflow. Each
# case names the change to the script under test it must catch.
#
#   cone/updater-test.sh
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
fx="$here/test/updater"
verify="$here/updater-verify.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/cone-updater-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

failed=0
expect() { # expect <case> <want: ok|refused> <stderr must contain> <verify args…>
  local name="$1" want="$2" needle="$3" rc=0
  shift 3
  "$verify" "$@" >"$work/out" 2>"$work/err" || rc=$?
  local got=ok
  (( rc == 0 )) || got=refused
  if (( rc > 1 )); then
    echo "  FAIL $name: tool error (rc $rc): $(cat "$work/err")"; failed=1; return
  fi
  if [[ "$got" != "$want" ]] || { [[ -n "$needle" ]] && ! grep -qF -- "$needle" "$work/err"; }; then
    echo "  FAIL $name: $got, want $want${needle:+ with \"$needle\"}: $(cat "$work/out" "$work/err")"; failed=1; return
  fi
  echo "  ok   $name: $got"
}

# A copy of payload.bin with one byte changed (criterion 5c's shape).
cp "$fx/payload.bin" "$work/tampered.bin"
printf 'X' | dd of="$work/tampered.bin" bs=1 seek=0 conv=notrunc 2>/dev/null
# payload.bin's signature with its trusted comment altered (the global
# signature no longer holds).
base64 -d <"$fx/payload.bin.sig" | sed 's/^trusted comment: \(.*\)$/trusted comment: \1 altered/' | base64 | tr -d '\n' >"$work/comment.sig"

echo "updater-verify:"
# Kills: a verifier that refuses everything; one that drops the BLAKE2b prehash.
expect "a signed archive" ok "" "$fx/payload.bin" "$fx/payload.bin.sig" "$fx/a.pub"
# Kills: the archive's signature not checked.
expect "one byte changed" refused "does not hold over this file" "$work/tampered.bin" "$fx/payload.bin.sig" "$fx/a.pub"
# Kills: the archive's signature not checked (criterion 5b: a real signature
# by the right key, of another file).
expect "another file's signature" refused "does not hold over this file" "$fx/payload.bin" "$fx/other.bin.sig" "$fx/a.pub"
# Kills: the key id not compared (with --key-id-only nothing else looks).
expect "another key, key id only" refused "signed by key" --key-id-only "$fx/payload.bin" "$fx/payload.bin.b.sig" "$fx/a.pub"
# Kills: the key id not compared, or the signature checked against the
# signature's own key (criterion 5a: a valid signature by someone else's key).
expect "another key" refused "signed by key" "$fx/payload.bin" "$fx/payload.bin.b.sig" "$fx/a.pub"
# Kills: the global signature (over the trusted comment) not checked.
expect "trusted comment altered" refused "trusted comment" "$fx/payload.bin" "$work/comment.sig" "$fx/a.pub"
# Kills: --key-id-only refusing a matching key.
expect "the right key, key id only" ok "" --key-id-only "$fx/payload.bin" "$fx/payload.bin.sig" "$fx/a.pub"

echo "promote-check:"
# Each case runs cone/promote-check.sh ($PC) on a feed and the manifest about
# to replace it; a failed case is also recorded in $work/failed, which the
# mutation run below reads.
PC="$here/promote-check.sh"
quiet=""
: > "$work/failed"
p3='{"darwin-aarch64":{"signature":"sa","url":"ua"},"darwin-x86_64":{"signature":"sx","url":"ux"},"windows-x86_64":{"signature":"sw","url":"uw"}}'
p2='{"darwin-aarch64":{"signature":"sa","url":"ua"},"darwin-x86_64":{"signature":"sx","url":"ux"}}'
pnoarm='{"darwin-x86_64":{"signature":"sx","url":"ux"},"windows-x86_64":{"signature":"sw","url":"uw"}}'
manifest() { printf '{"version":"%s","notes":"n","pub_date":"d","platforms":%s}' "$1" "${2:-$p3}"; }
promote() { # promote <case> <want: ok|refused> <feed content> <version> [object] [manifest content]
  local rc=0 got=ok
  printf '%s' "$3" >"$work/feed.json"
  printf '%s' "${6:-$(manifest "$4")}" >"$work/manifest.json"
  bash "$PC" "$work/feed.json" "$work/manifest.json" "$4" "${5:-2/latest.json}" >"$work/out" 2>&1 || rc=$?
  (( rc == 0 )) || got=refused
  if (( rc > 1 )) || [[ "$got" != "$2" ]]; then
    printf '%s\n' "$1" >>"$work/failed"
    [[ -n "$quiet" ]] || { echo "  FAIL $1: $got (rc $rc), want $2: $(cat "$work/out")"; failed=1; }
    return 0
  fi
  [[ -n "$quiet" ]] || echo "  ok   $1: $got"
}
promote_cases() {
  # Kills: the check skipped (review of #6: 1.0.0 promoted over 1.0.1).
  promote "an older version" refused '{"version":"1.0.1"}' 1.0.0
  # Kills: versions compared as strings ("1.0.10" < "1.0.9").
  promote "1.0.9 to 1.0.10" ok '{"version":"1.0.9"}' 1.0.10
  # Kills: the major (or minor) not compared — the patch alone decides.
  promote "an older major" refused '{"version":"2.0.0"}' 1.9.9
  # Kills: a later field deciding after an earlier one was already newer.
  promote "1.9.9 to 2.0.0" ok '{"version":"1.9.9"}' 2.0.0
  # Kills: the same version refused (a re-promotion must work).
  promote "the same version" ok '{"version":"1.0.1"}' 1.0.1
  # Kills: the placeholder, which names no version, refused.
  promote "the placeholder" ok '{"placeholder":"no release promoted yet"}' 1.0.0
  # Kills: a missing feed refused.
  promote "no feed" ok '' 1.0.0
  # Kills: a feed version no promotion writes taken as older.
  promote "an unknown feed version" refused '{"version":"1.0.2-tampered"}' 1.0.3
  # Kills: the object guard skipped — the old app's feed at the bucket root.
  promote "the bucket root (the old app's feed)" refused '{"version":"1.0.0"}' 2.0.0 latest.json
  # Kills: a prefix match instead of the exact key.
  promote "another object under 2/" refused '{"version":"1.0.0"}' 2.0.0 2/latest.json.bak
  # Kills: the placeholder the preparation uploads (0.0.0) taken as newer.
  promote "the 0.0.0 placeholder" ok '{"version":"0.0.0","notes":"placeholder","platforms":{}}' 2.0.0
  # Decision W9: a platform the feed has is never dropped.
  # Kills: the first Windows release refused for adding a platform (the sets
  # compared the wrong way round, or for equality).
  promote "the first Windows release adds windows-x86_64" ok "$(manifest 2.4.0 "$p2")" 2.5.0
  # Kills: the drop check removed (an older tag's two-platform promote).
  promote "a newer two-platform manifest over a three-platform feed" refused "$(manifest 2.5.0)" 2.6.0 2/latest.json "$(manifest 2.6.0 "$p2")"
  # Kills: the drop check only for a newer version (a re-promotion from an
  # older tag's workflow rewrites the same version with two platforms).
  promote "the same version again, without windows-x86_64" refused "$(manifest 2.5.0)" 2.5.0 2/latest.json "$(manifest 2.5.0 "$p2")"
  # Kills: only the feed's first platform compared.
  promote "darwin-aarch64 dropped (the first key)" refused "$(manifest 2.5.0)" 2.6.0 2/latest.json "$(manifest 2.6.0 "$pnoarm")"
  # Kills: the drop check skipped when the feed names no version.
  promote "a feed without a version keeps its platforms" refused "{\"platforms\":$p3}" 2.6.0 2/latest.json "$(manifest 2.6.0 "$p2")"
  # Kills: a re-promotion of the same three refused.
  promote "the same three platforms again" ok "$(manifest 2.5.0)" 2.5.0
  # Kills: a feed whose platforms is not an object read as one without any.
  promote "the feed's platforms not an object" refused '{"version":"2.5.0","platforms":["windows-x86_64"]}' 2.6.0
  # Kills: the manifest's version not compared with the one promoted.
  promote "the manifest names another version" refused "$(manifest 2.4.0 "$p2")" 2.5.0 2/latest.json "$(manifest 2.5.1)"
  # Kills: a manifest with no platforms written (every app would stop).
  promote "a manifest without platforms" refused '{"version":"2.4.0"}' 2.5.0 2/latest.json '{"version":"2.5.0","platforms":{}}'
}
promote_cases
cases=$(( 7 + $(grep -c '^  promote "' "$0") ))

# Mutation test (ADR-0016, ADR-0051 in cone-buzz-infra): each planted change
# to promote-check.sh must make the named case fail. "Something went red" is
# not a kill.
echo "promote-check mutations:"
mutate() { # <mutation> <exact text> <replacement> <the case that must kill it>
  cp "$here/promote-check.sh" "$work/mutant.sh"
  FROM="$2" TO="$3" perl -0pi -e 'my $n = s/\Q$ENV{FROM}\E/$ENV{TO}/g; die "matched $n times\n" unless $n == 1' "$work/mutant.sh" 2>"$work/perl" \
    || { echo "  FAIL $1: its text is not in promote-check.sh once ($(cat "$work/perl")) — update the mutation"; failed=1; return 0; }
  : >"$work/failed"
  PC="$work/mutant.sh" quiet=1 promote_cases
  if grep -qxF -- "$4" "$work/failed"; then
    echo "  ok   $1: killed by \"$4\""
  else
    echo "  FAIL $1: survived \"$4\" (failed instead: $(tr '\n' ';' <"$work/failed"))"; failed=1
  fi
}
# The mutations are promote-check.sh's own text, quoted, never expanded here.
# shellcheck disable=SC2016
run_mutations() {
  mutate "the drop check removed" 'if [[ -n "$dropped" ]]; then' 'if false; then' \
    "a newer two-platform manifest over a three-platform feed"
  mutate "the sets compared the wrong way round" 'dropped="$(comm -23' 'dropped="$(comm -13' \
    "the first Windows release adds windows-x86_64"
  mutate "only the feed's last platform read" 'then .platforms | keys[] else error("bad") end'"'"' "$current_file"' 'then .platforms | keys[-1] else error("bad") end'"'"' "$current_file"' \
    "darwin-aarch64 dropped (the first key)"
  mutate "a non-object platforms read as none" 'else error("bad") end'"'"' "$current_file"' 'else empty end'"'"' "$current_file"' \
    "the feed's platforms not an object"
  mutate "the drop check after the no-version exit" 'if [[ -n "$dropped" ]]; then' 'if [[ -n "$current" && -n "$dropped" ]]; then' \
    "a feed without a version keeps its platforms"
  mutate "the drop check for a newer version only" 'if [[ -n "$dropped" ]]; then' 'if [[ -n "$dropped" && "$current" != "$version" ]]; then' \
    "the same version again, without windows-x86_64"
  mutate "the manifest's version not compared" 'if .version == $v and' 'if true and' \
    "the manifest names another version"
  mutate "an empty platforms object allowed" 'and (.platforms | length) > 0' 'and true' \
    "a manifest without platforms"
  mutate "an older version allowed" 'if (( 10#${new[i]} < 10#${cur[i]} )); then' 'if false; then' \
    "an older version"
  mutate "the object guard removed" '[[ "$object" == 2/latest.json ]]' '[[ -n "$object" ]]' \
    "the bucket root (the old app's feed)"
}
run_mutations

if (( failed )); then echo "updater-test: FAILED"; exit 1; fi
echo "updater-test: ok ($cases cases, 10 mutations killed)"
