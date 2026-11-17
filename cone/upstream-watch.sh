#!/usr/bin/env bash
# The Cone Desktop follows block/buzz-app's stable releases (cone-buzz-infra
# Slice 54, ADR-375). Run by .github/workflows/cone-upstream.yml:
#
#   cone/upstream-watch.sh run [<tag>]          open the update pull request for the newest stable
#                                               tag newer than cone/UPSTREAM (or <tag>), once per tag
#   cone/upstream-watch.sh tag <before> <after> after a push to cone that changed cone/UPSTREAM:
#                                               tag <after> cone-desktop-v2.<next minor>.0
#   cone/upstream-watch.sh disable-workflows    every active workflow that is not Cone's is disabled
#
# and the pure parts, which cone/upstream-test.sh tests:
#
#   newest <current>       stdin: release tag names; prints the newest stable vX.Y.Z above <current>
#   pick <current> [<tag>] stdin: the published stable release tags; prints <tag> when it is one of
#                          them and newer than <current>, else dies; without <tag>, the newest
#   guard <base> <head>    stdin: "<state> <path>" per workflow GitHub knows; dies when <base>..<head>
#                          adds a workflow file or changes one that is not disabled_manually
#   next-version           stdin: this fork's tag names; prints the next minor 2.Y.0
#   triage <old> <new>     the pull request's body sections, from git log <old>..<new>
#
# The update is a merge of the upstream tag into a branch cone-update/<tag>
# (cone/README.md, "Upstream update"), cone/UPSTREAM set to it and strings.tsv
# re-measured; the pull request's own CI runs every check. Nothing is pushed
# when the merge brings a workflow that could run here (`guard`): a branch
# push, a pull request or the merge itself starts any workflow file GitHub
# has not been told is disabled, and disabling it afterwards stops no run
# that has started. Nothing here
# builds, signs or publishes: merging the pull request tags the release, and
# the release still waits for the owner at cone-release.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

UPSTREAM_REPO="block/buzz-app"
UPSTREAM_URL="${CONE_UPSTREAM_URL:-https://github.com/$UPSTREAM_REPO.git}"
FORK_REPO="${GITHUB_REPOSITORY:-ConeDigital/cone-buzz-app}"
STABLE_RE='^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'

die() { echo "upstream-watch: $*" >&2; exit 1; }

# semver_gt <a> <b>: a > b, both vX.Y.Z or X.Y.Z
semver_gt() {
  local a="${1#v}" b="${2#v}" i
  local -a x y
  IFS=. read -r -a x <<<"$a"
  IFS=. read -r -a y <<<"$b"
  for i in 0 1 2; do
    (( 10#${x[i]} > 10#${y[i]} )) && return 0
    (( 10#${x[i]} < 10#${y[i]} )) && return 1
  done
  return 1
}

cmd_newest() {
  local current="$1" best="" t
  [[ "$current" =~ $STABLE_RE ]] || die "current '$current' is not a stable tag vX.Y.Z"
  while read -r t; do
    [[ "$t" =~ $STABLE_RE ]] || continue
    semver_gt "$t" "$current" || continue
    if [[ -z "$best" ]] || semver_gt "$t" "$best"; then best="$t"; fi
  done
  [[ -z "$best" ]] || echo "$best"
}

cmd_pick() {
  local current="$1" want="${2:-}" t found=0
  if [[ -z "$want" ]]; then cmd_newest "$current"; return; fi
  [[ "$want" =~ $STABLE_RE ]] || die "'$want' is not a stable tag vX.Y.Z"
  while read -r t; do [[ "$t" == "$want" ]] && found=1; done
  (( found )) || die "$want is not a published, non-draft, non-prerelease $UPSTREAM_REPO release"
  semver_gt "$want" "$current" || die "$want is not newer than cone/UPSTREAM ($current)"
  echo "$want"
}

# published_stable [<tag>]: the tags of block/buzz-app's published releases
# that are neither drafts nor prereleases (only <tag>'s, when given).
published_stable() {
  if [[ -n "${1:-}" ]]; then
    gh release view "$1" -R "$UPSTREAM_REPO" --json tagName,isDraft,isPrerelease \
      --jq 'select((.isDraft or .isPrerelease) | not) | .tagName' 2>/dev/null || true
  else
    gh release list -R "$UPSTREAM_REPO" --exclude-drafts --exclude-pre-releases --limit 100 --json tagName --jq '.[].tagName'
  fi
}

# "<state> <path>" for every workflow GitHub knows in the fork. Reading them
# takes Actions read, which the App does not hold: the job's GITHUB_TOKEN
# (ACTIONS_READ_TOKEN) reads them.
workflow_states() {
  GH_TOKEN="${ACTIONS_READ_TOKEN:-${GH_TOKEN:-}}" \
    gh workflow list -R "$FORK_REPO" --all --limit 200 --json path,state --jq '.[] | "\(.state) \(.path)"'
}

# A workflow file the merge adds has no state yet, so it runs on the branch
# push, the pull request or the merge; one it changes that is not
# disabled_manually may be live too (v1.0.2 turned release.yml from
# disabled_fork to active). Both stop the update before anything is pushed.
cmd_guard() {
  local base="$1" head="$2" st path state bad="" changes
  local -a known=()
  while read -r state path; do [[ -n "$path" ]] && known+=("$state $path"); done
  # a failed diff stops the update; it never reads as "no workflow changed"
  changes="$(git diff --name-status --no-renames "$base" "$head" -- .github/workflows)" \
    || die "cannot diff $base..$head; nothing pushed"
  while IFS=$'\t' read -r st path; do
    [[ "$path" =~ \.ya?ml$ ]] || continue
    case "$st" in
      D) continue ;;
      A) bad+="  $path: new, GitHub has no disabled state for it"$'\n'; continue ;;
    esac
    state="$(printf '%s\n' ${known[@]+"${known[@]}"} | awk -v p="$path" '$2 == p {print $1}')"
    [[ "$state" == disabled_manually ]] || bad+="  $path: changed, state '${state:-unknown}', not disabled_manually"$'\n'
  done <<<"$changes"
  [[ -z "$bad" ]] && return 0
  printf '%s' "$bad" >&2
  die "the merge brings the workflows above, which could run in this fork; nothing pushed — read their triggers and update by hand (cone/README.md, Upstream update)"
}

cmd_next_version() {
  local major=2 minor=-1 t m
  while read -r t; do
    [[ "$t" =~ ^cone-desktop-v2\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || continue
    m="${BASH_REMATCH[1]}"
    (( m > minor )) && minor="$m"
  done
  (( minor >= 0 )) || die "no cone-desktop-v2.Y.Z tag to count from"
  echo "$major.$((minor + 1)).0"
}

# The commits that matter to Cone first, by subject; a commit is listed under
# the first group it matches, and every commit is in the full list.
TRIAGE_GROUPS=(
  "Security and identity|secur|vuln|cve|identity|keychain|private key|nsec|credential|sign-in|sign in|signin|sign out|(^|[^a-z])auth([^o]|$)|authenticat|authoriz|csp|sandbox|permission"
  "Relay, sync and membership|relay|sync|roster|membership|invite|deliver|offline|reconnect|nostr|nip-"
  "Windows|windows|nsis|msvc|win32"
  "Updater, packaging and builds|updater|update feed|notari|codesign|bundle|dmg|installer|tauri|release"
)

cmd_triage() {
  local old="$1" new="$2" log n files g name re hit
  log="$(git log --no-merges --format='%h %s' "$old..$new")"
  n="$(printf '%s\n' "$log" | grep -c . || true)"
  files="$(git diff --name-only "$old" "$new" | grep -c . || true)"
  echo "**$n commits** ($files files) from \`$old\` to \`$new\`."
  echo
  local rest="$log"
  for g in "${TRIAGE_GROUPS[@]}"; do
    name="${g%%|*}"; re="${g#*|}"
    hit="$(printf '%s\n' "$rest" | grep -i -E "$re" || true)"
    rest="$(printf '%s\n' "$rest" | grep -v -i -E "$re" || true)"
    [[ -n "$hit" ]] || continue
    echo "#### $name ($(printf '%s\n' "$hit" | grep -c .))"
    echo
    printf '%s\n' "$hit" | sed 's/^/- /'
    echo
  done
  echo "#### Outside the app"
  echo
  local wf conf
  wf="$(git diff --name-status "$old" "$new" -- .github/workflows | sed 's/^/- /')"
  conf="$(git diff --name-status "$old" "$new" -- 'src-tauri/tauri*.conf.json' justfile | sed 's/^/- /')"
  echo "Upstream workflows changed (each one already disabled here, checked before this branch was pushed): ${wf:+$'\n\n'}${wf:-none}"
  echo
  echo "Tauri configuration and justfile: ${conf:+$'\n\n'}${conf:-unchanged}"
  echo
  echo "<details><summary>Every other commit ($(printf '%s\n' "$rest" | grep -c . || true))</summary>"
  echo
  printf '%s\n' "$rest" | sed '/^$/d; s/^/- /'
  echo
  echo "</details>"
}

cmd_run() {
  local want="${1:-}" current tag branch prs measure_out check_out check_ok=1 next body states
  current="$(tr -d '[:space:]' < cone/UPSTREAM)"
  # read every day, so a token that cannot read them fails now, not on the day a release comes
  states="$(workflow_states)" || die "cannot read this fork's workflow states (the guard's input); nothing done"
  tag="$(published_stable "$want" | cmd_pick "$current" "$want")"
  if [[ -z "$tag" ]]; then echo "upstream-watch: cone/UPSTREAM $current is the newest stable $UPSTREAM_REPO release"; return 0; fi
  branch="cone-update/$tag"
  prs="$(gh pr list -R "$FORK_REPO" --head "$branch" --state all --json number,state --jq '.[] | "#\(.number) \(.state)"')"
  if [[ -n "$prs" ]]; then echo "upstream-watch: $tag already has a pull request ($prs); nothing to do"; return 0; fi
  echo "upstream-watch: $current → $tag"

  git fetch --no-tags "$UPSTREAM_URL" "+refs/tags/$tag:refs/tags/$tag" "+refs/tags/$current:refs/tags/$current"
  git switch -C "$branch" origin/cone
  if ! git merge --no-ff --no-edit -m "Merge upstream $tag" "$tag"; then
    git diff --name-only --diff-filter=U >&2
    die "merging $tag conflicts in the files above; merge it by hand (cone/README.md, Upstream update)"
  fi
  printf '%s\n' "$states" | cmd_guard origin/cone HEAD
  echo "$tag" > cone/UPSTREAM
  git commit -q -m "cone/UPSTREAM: $tag" -- cone/UPSTREAM

  pnpm install --frozen-lockfile
  if measure_out="$(cone/rebrand.sh measure 2>&1)"; then
    { head -1 cone/rebrand/strings.tsv; printf '%s\n' "$measure_out"; } > cone/rebrand/strings.tsv.new
    mv cone/rebrand/strings.tsv.new cone/rebrand/strings.tsv
    git diff --quiet -- cone/rebrand/strings.tsv || git commit -q -m "cone/rebrand/strings.tsv: measured at $tag" -- cone/rebrand/strings.tsv
    measure_out="strings.tsv measured at $tag: $(git diff --shortstat "origin/cone" -- cone/rebrand/strings.tsv | sed 's/^ *//')"
  else
    check_ok=0
    measure_out="measure failed: $(printf '%s\n' "$measure_out" | tail -5)"
  fi
  if check_out="$(cone/rebrand.sh check 2>&1)"; then :; else check_ok=0; fi

  next="$(git ls-remote --tags --refs origin 'cone-desktop-v2.*' | sed 's|.*refs/tags/||' | cmd_next_version)"
  body="$(mktemp)"
  {
    echo "Block released **$tag** (the fork is at \`$current\`): [release notes](https://github.com/$UPSTREAM_REPO/releases/tag/$tag)."
    echo
    echo "**Merging this pull request tags \`cone-desktop-v$next\`**; the build then waits for the owner at \`cone-release\`, and installed apps get it only once it is promoted. Closing it skips $tag; the watcher opens the next stable tag when one appears."
    echo
    echo "### The rebrand after the merge"
    echo
    echo "$measure_out"
    echo
    if (( check_ok )); then echo "\`cone/rebrand.sh check\` (without the frontend build, which this pull request's CI runs): **ok**"
    else echo "\`cone/rebrand.sh check\` **fails**; fix what it names on this branch (cone/README.md, \"When the check fails on an upstream update\"):"; fi
    echo
    echo '```text'
    printf '%s\n' "$check_out" | tail -30
    echo '```'
    echo
    echo "### What changed upstream"
    echo
    cmd_triage "$current" "$tag"
    echo
    echo "Opened by \`cone/upstream-watch.sh\` (cone-buzz-infra Slice 54, ADR-375)."
  } > "$body"

  git push --force origin "$branch"
  local draft=()
  (( check_ok )) || draft=(--draft)
  gh pr create -R "$FORK_REPO" --base cone --head "$branch" ${draft[@]+"${draft[@]}"} \
    --title "Upstream $tag (cone-desktop-v$next)" --body-file "$body"
}

cmd_tag() {
  local before="$1" after="$2" upstream next existing
  [[ "$before" =~ ^[0-9a-f]{40}$ && "$before" != 0000000000000000000000000000000000000000 ]] || { echo "upstream-watch: no previous commit to compare; nothing to tag"; return 0; }
  if git diff --quiet "$before" "$after" -- cone/UPSTREAM; then echo "upstream-watch: cone/UPSTREAM unchanged; nothing to tag"; return 0; fi
  upstream="$(git show "$after:cone/UPSTREAM" | tr -d '[:space:]')"
  [[ "$upstream" =~ $STABLE_RE ]] || die "cone/UPSTREAM at $after holds '$upstream'"
  existing="$(git tag --points-at "$after" --list 'cone-desktop-v*')"
  [[ -z "$existing" ]] || { echo "upstream-watch: $after is already $existing"; return 0; }
  next="$(git ls-remote --tags --refs origin 'cone-desktop-v2.*' | sed 's|.*refs/tags/||' | cmd_next_version)"
  git tag "cone-desktop-v$next" "$after"
  git push origin "cone-desktop-v$next"
  echo "upstream-watch: tagged $after cone-desktop-v$next (upstream $upstream); the release waits for the owner at cone-release"
}

cmd_disable_workflows() {
  local path
  gh workflow list -R "$FORK_REPO" --all --limit 200 --json path,state --jq '.[] | select(.state == "active") | .path' |
    while read -r path; do
      [[ "$path" =~ ^\.github/workflows/cone-[a-z-]+\.yml$ ]] && continue
      gh workflow disable -R "$FORK_REPO" "${path##*/}"
      echo "upstream-watch: disabled $path (every upstream workflow stays disabled in this fork)"
    done
}

case "${1:-}" in
  newest) cmd_newest "${2:?current tag}" ;;
  pick) cmd_pick "${2:?current tag}" "${3:-}" ;;
  guard) cmd_guard "${2:?base}" "${3:?head}" ;;
  next-version) cmd_next_version ;;
  triage) cmd_triage "${2:?old}" "${3:?new}" ;;
  run) cmd_run "${2:-}" ;;
  tag) cmd_tag "${2:?before}" "${3:?after}" ;;
  disable-workflows) cmd_disable_workflows ;;
  *) die "usage: cone/upstream-watch.sh newest|pick|guard|next-version|triage|run|tag|disable-workflows" ;;
esac
