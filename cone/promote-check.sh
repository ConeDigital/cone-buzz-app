#!/usr/bin/env bash
# May the feed move to this manifest? (Slice 29 merge 3, review of #6; Slice 48
# decision W9.) A promotion replaces the one latest.json every app reads, and
# an app looks only for a version newer than its own — so a feed moved back to
# an older release hides the newer one from every app still below it, and a
# feed that loses a platform leaves every app of that platform without
# updates. The promote job runs this against what the bucket holds right
# before it uploads (one promotion at a time: the job's feed-wide concurrency
# group).
#
#   cone/promote-check.sh <current-feed-file> <new-manifest> <version> <object>
#
# <object> is the bucket key the promotion is about to write. Only
# `2/latest.json` — the Buzz 1.0 app's feed, served at
# https://buzz.cone.digital/desktop/2/latest.json — is allowed: the bucket
# root's latest.json is the old app's (Buzz 0.X) feed, which no promotion of
# this fork may touch (Slice 48, criterion 4).
#
# <new-manifest> is the latest.json about to be uploaded: JSON whose `version`
# is <version> and whose `platforms` is an object with at least one key.
#
# <current-feed-file> is the latest.json the feed holds now; a missing or
# empty file, or one without a `version` (the placeholder), allows any
# version. Allowed: the same version again (a re-promotion) or a newer one,
# carrying every platform the current feed has (more is fine: the first
# Windows release adds windows-x86_64). Refused: an older version; a manifest
# without a platform the feed has (decision W9 — an older tag's promote writes
# two); a current version that is not X.Y.Z or a current `platforms` that is
# not an object (the feed holds something no promotion wrote: look at it
# first). Exits 0 allowed, 1 refused, 2 on a usage error. Restoring a saved
# feed byte for byte is not a promotion (docs/operations.md in
# cone-buzz-infra).
set -euo pipefail

(( $# == 4 )) || { echo "usage: cone/promote-check.sh <current-feed-file> <new-manifest> <version> <object>" >&2; exit 2; }
current_file="$1" manifest="$2" version="$3" object="$4"
[[ "$object" == 2/latest.json ]] \
  || { echo "promote-check: REFUSED — '$object' is not 2/latest.json; this fork never writes the old app's feed or anything else in the bucket" >&2; exit 1; }
semver='^([0-9]+)\.([0-9]+)\.([0-9]+)$'
[[ "$version" =~ $semver ]] || { echo "promote-check: '$version' is not X.Y.Z" >&2; exit 2; }
new=("${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}")

# The manifest: this version, and the platforms it carries (sorted, one per line).
[[ -s "$manifest" ]] || { echo "promote-check: no manifest at '$manifest'" >&2; exit 2; }
new_platforms="$(jq -r --arg v "$version" 'if .version == $v and (.platforms | type) == "object" and (.platforms | length) > 0
  then .platforms | keys[] else error("bad") end' "$manifest" 2>/dev/null)" \
  || { echo "promote-check: REFUSED — the manifest is not JSON of version $version with a platforms object" >&2; exit 1; }

current="" current_platforms=""
if [[ -s "$current_file" ]]; then
  current="$(jq -r '.version // empty' "$current_file" 2>/dev/null)" \
    || { echo "promote-check: REFUSED — the feed serves something that is not JSON; look at it first" >&2; exit 1; }
  current_platforms="$(jq -r 'if has("platforms") | not then empty
    elif (.platforms | type) == "object" then .platforms | keys[] else error("bad") end' "$current_file" 2>/dev/null)" \
    || { echo "promote-check: REFUSED — the feed's platforms is not an object; look at it first" >&2; exit 1; }
fi

# Every platform the feed has stays (decision W9).
dropped="$(comm -23 <(printf '%s\n' "$current_platforms" | sed '/^$/d' | LC_ALL=C sort) <(printf '%s\n' "$new_platforms" | LC_ALL=C sort))"
if [[ -n "$dropped" ]]; then
  echo "promote-check: REFUSED — the feed has $(tr '\n' ' ' <<<"$dropped")which the manifest drops; every app on it would stop updating" >&2
  exit 1
fi

if [[ -z "$current" ]]; then
  echo "promote-check: the feed names no version; $version allowed ($(tr '\n' ' ' <<<"$new_platforms" | sed 's/ $//'))"
  exit 0
fi
[[ "$current" =~ $semver ]] \
  || { echo "promote-check: REFUSED — the feed serves version '$current', which no promotion writes; look at it first" >&2; exit 1; }
cur=("${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}")

for i in 0 1 2; do
  if (( 10#${new[i]} > 10#${cur[i]} )); then echo "promote-check: $current → $version allowed (newer; $(tr '\n' ' ' <<<"$new_platforms" | sed 's/ $//'))"; exit 0; fi
  if (( 10#${new[i]} < 10#${cur[i]} )); then
    echo "promote-check: REFUSED — the feed serves $current; $version is older and would hide $current from every app below it" >&2
    exit 1
  fi
done
echo "promote-check: $version again allowed (the feed already serves it; $(tr '\n' ' ' <<<"$new_platforms" | sed 's/ $//'))"
