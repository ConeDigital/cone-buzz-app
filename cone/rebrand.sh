#!/usr/bin/env bash
# The in-app rebrand on Buzz 1.0 (cone-buzz-infra Slice 51, ADR-364; Slice
# 36's mechanism, ADR-237, ported from ConeDigital/cone-buzz): apply Cone's
# manifests under cone/rebrand/ to the working copy of upstream's tree right
# before a build, verify nothing is left, and put every file back.
#
#   cone/rebrand.sh apply        replacements (hash-checked), lines, the word rule (count-checked)
#   cone/rebrand.sh scan         after apply: no branded residue outside cone/rebrand/exceptions.tsv
#   cone/rebrand.sh bundle-scan  after a frontend build: no word Buzz in dist/ outside the kept runtime names
#   cone/rebrand.sh restore      every path apply may have written back to HEAD
#   cone/rebrand.sh check        refuse a dirty tree, apply, scan, [--build: typecheck + frontend build + bundle-scan], restore
#   cone/rebrand.sh measure      lines applied, the word counts printed as strings.tsv rows, restored
#
# Run from anywhere with hermit active (node, pnpm). cone/rebrand/transform.mjs
# does the text work; this script does the whole-file replacements and the git
# bookkeeping. Every failure names a path.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
REBRAND=cone/rebrand
TRANSFORM="$REBRAND/transform.mjs"

die() { echo "rebrand: $*" >&2; exit 1; }

# replacements.tsv: path<TAB>sha256 — the upstream file's content. The
# replacement is files/<path>.
replacement_rows() { grep -v -E '^(#|$)' "$REBRAND/replacements.tsv" || true; }

verify_replacements() {
  local bad=0 rel sha have
  while IFS=$'\t' read -r rel sha; do
    [[ -f "$REBRAND/files/$rel" ]] || { echo "rebrand: $rel: no replacement at $REBRAND/files/$rel" >&2; bad=1; continue; }
    [[ -f "$rel" ]] || { echo "rebrand: $rel: replacement target missing upstream" >&2; bad=1; continue; }
    have="$(shasum -a 256 "$rel" | cut -d' ' -f1)"
    [[ "$have" == "$sha" ]] || { echo "rebrand: $rel: upstream content changed (sha256 $have, pinned $sha) — review the diff, carry it into $REBRAND/files/$rel, then update replacements.tsv" >&2; bad=1; }
  done < <(replacement_rows)
  (( bad == 0 )) || exit 1
}

apply_replacements() {
  local rel sha
  while IFS=$'\t' read -r rel sha; do
    cp "$REBRAND/files/$rel" "$rel"
  done < <(replacement_rows)
  echo "rebrand apply: $(replacement_rows | wc -l | tr -d ' ') files replaced"
}

all_paths() {
  { replacement_rows | cut -f1; node "$TRANSFORM" paths; } | sed '/^$/d' | sort -u
}

# Every path apply writes under and restore checks out: a guard on fewer would
# let restore erase an uncommitted edit (review of ConeDigital/cone-buzz#8).
guarded_dirs() { node "$TRANSFORM" roots; }

refuse_dirty() {
  local dirty
  # shellcheck disable=SC2046
  dirty="$(git status --porcelain --untracked-files=all -- $(guarded_dirs) | sed '/^$/d' || true)"
  [[ -z "$dirty" ]] || die "the tree is not clean under $(guarded_dirs | tr '\n' ' '); commit, stash or restore first:"$'\n'"$dirty"
}

cmd_apply() {
  verify_replacements
  apply_replacements
  node "$TRANSFORM" apply
}

cmd_restore() {
  # shellcheck disable=SC2046
  git checkout --quiet -- $(all_paths | while read -r p; do git ls-files --error-unmatch "$p" >/dev/null 2>&1 && printf '%s ' "$p"; done)
  echo "rebrand restore: ok"
}

cmd_scan() { node "$TRANSFORM" scan; }

# The built frontend (dist/, what Tauri embeds compressed — invisible to
# `strings` on the binary): the whole word Buzz appears only inside the kept
# runtime names that reach the frontend (cone/rebrand/keep.tsv rows of
# frontend files), never on its own.
cmd_bundle_scan() {
  local files hits
  ls dist/index.html dist/assets/*.js >/dev/null 2>&1 || die "no dist/index.html or dist/assets/*.js: build the frontend first"
  shopt -s nullglob
  files=(dist/*.html dist/assets/*.js dist/assets/*.css)
  shopt -u nullglob
  hits="$(node "$TRANSFORM" bundle-residue "${files[@]}")" || { printf '%s\n' "$hits" >&2; exit 1; }
  echo "$hits"
}

cmd_measure() {
  refuse_dirty
  trap 'cmd_restore >/dev/null' EXIT
  verify_replacements
  apply_replacements >/dev/null
  node "$TRANSFORM" apply-prefix >/dev/null
  node "$TRANSFORM" measure
}

cmd_check() {
  refuse_dirty
  trap 'cmd_restore' EXIT
  cmd_apply
  cmd_scan
  if [[ "${1:-}" == "--build" ]]; then
    pnpm build   # tsc --noEmit, then vite build
    cmd_bundle_scan
    echo "rebrand check: typecheck and frontend build ok"
  fi
  echo "rebrand check: ok"
}

case "${1:-}" in
  apply) cmd_apply ;;
  restore) cmd_restore ;;
  scan) cmd_scan ;;
  bundle-scan) cmd_bundle_scan ;;
  measure) cmd_measure ;;
  check) shift; cmd_check "$@" ;;
  *) die "usage: cone/rebrand.sh apply|restore|scan|bundle-scan|measure|check [--build]" ;;
esac
