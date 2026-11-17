#!/usr/bin/env bash
# Tests for cone/upstream-watch.sh (cone-buzz-infra Slice 54, ADR-375): the
# stable-tag choice, the next version, the tag after a merge, the triage and
# the workflow guard. No network: `tag` runs against a local bare origin, and
# `gh` is a stub that answers `workflow list` from a fixture through the real
# jq with the script's own --jq filter (a mock of a reader reproduces its
# parsing, ADR-0016).
#
#   bash cone/upstream-test.sh        (from the repository root)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$PWD"
W="$ROOT/cone/upstream-watch.sh"

pass=0; fail=0
ok() { echo "ok   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1"; fail=$((fail + 1)); }
has() { # <name> <grep pattern> <text>: the text has a matching line
  if grep -q -e "$2" <<<"$3"; then ok "$1"; else bad "$1"; fi
}
hasnt() { # <name> <grep pattern> <text>: no line matches
  if grep -q -e "$2" <<<"$3"; then bad "$1"; else ok "$1"; fi
}
eq() { # <name> <want> <got>
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1: want '$2', got '$3'"; fi
}

# --- newest: only stable vX.Y.Z above the current tag, compared numerically
tags=$'v1.0.3-preview.2\nv1.0.2\nv1.0.1\nv1.0.0\nv0.7.0-preview.275.1\ndesktop-v0.5.25\nv2.0.0-beta.1\nv1.0.0-beta.2'
eq "newest picks the highest stable tag" "v1.0.2" "$(printf '%s\n' "$tags" | "$W" newest v1.0.0)"
eq "newest ignores previews, betas and desktop-v tags" "" "$(printf 'v1.0.3-preview.2\nv2.0.0-beta.1\ndesktop-v9.9.9\n' | "$W" newest v1.0.2)"
eq "newest prints nothing when current is the newest" "" "$(printf '%s\n' "$tags" | "$W" newest v1.0.2)"
eq "newest compares numerically (1.10.0 > 1.9.0)" "v1.10.0" "$(printf 'v1.9.0\nv1.10.0\nv1.2.0\n' | "$W" newest v1.8.0)"
eq "newest: a higher minor beats a higher patch" "v1.1.0" "$(printf 'v1.0.9\nv1.1.0\n' | "$W" newest v1.0.0)"
if printf 'v1.0.1\n' | "$W" newest main >/dev/null 2>&1; then bad "newest refuses a current that is not a stable tag"; else ok "newest refuses a current that is not a stable tag"; fi

# --- next-version: the next minor on the 2.x line, from this fork's tags only
eq "next-version after 2.1.0" "2.2.0" "$(printf 'cone-desktop-v2.0.0\ncone-desktop-v2.0.1\ncone-desktop-v2.1.0\ncone-desktop-v1.1.1\n' | "$W" next-version)"
eq "next-version counts minors numerically" "2.11.0" "$(printf 'cone-desktop-v2.9.0\ncone-desktop-v2.10.0\ncone-desktop-v2.2.5\n' | "$W" next-version)"
eq "next-version ignores 1.x, 3.x and suffixed tags" "2.2.0" "$(printf 'cone-desktop-v2.1.0\ncone-desktop-v2.5.0-rc1\ncone-desktop-v3.0.0\ncone-desktop-v1.9.0\n' | "$W" next-version)"
if printf 'cone-desktop-v1.1.1\n' | "$W" next-version >/dev/null 2>&1; then bad "next-version refuses without a 2.x tag"; else ok "next-version refuses without a 2.x tag"; fi

# --- tag: on a scratch repository with a bare origin
T="$(mktemp -d "${TMPDIR:-/tmp}/cone-upstream-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
git init -q --bare "$T/origin.git"
git init -q -b cone "$T/repo"
mkdir -p "$T/repo/cone"
cp "$W" "$T/repo/cone/upstream-watch.sh"
(
  cd "$T/repo"
  git config user.name test; git config user.email test@cone.digital
  git remote add origin "$T/origin.git"
  echo v1.0.0 > cone/UPSTREAM; echo one > app.txt
  git add -A; git commit -q -m base; git tag cone-desktop-v2.1.0; git push -q origin cone --tags
)
c1="$(git -C "$T/repo" rev-parse HEAD)"
( cd "$T/repo" && echo two > app.txt && git commit -qam "an app change" )
c2="$(git -C "$T/repo" rev-parse HEAD)"
out="$( cd "$T/repo" && cone/upstream-watch.sh tag "$c1" "$c2" )"
eq "tag: cone/UPSTREAM unchanged → nothing" "upstream-watch: cone/UPSTREAM unchanged; nothing to tag" "$out"
eq "tag: … and no tag was pushed" "cone-desktop-v2.1.0" "$(git -C "$T/origin.git" tag --list | tr '\n' ' ' | sed 's/ $//')"
out="$( cd "$T/repo" && cone/upstream-watch.sh tag 0000000000000000000000000000000000000000 "$c2" )"
eq "tag: no previous commit → nothing" "upstream-watch: no previous commit to compare; nothing to tag" "$out"
( cd "$T/repo" && echo v1.0.2 > cone/UPSTREAM && git commit -qam "cone/UPSTREAM: v1.0.2" )
c3="$(git -C "$T/repo" rev-parse HEAD)"
( cd "$T/repo" && git push -q origin cone )
out="$( cd "$T/repo" && cone/upstream-watch.sh tag "$c2" "$c3" 2>/dev/null )"
eq "tag: cone/UPSTREAM changed → the next minor, said" "upstream-watch: tagged $c3 cone-desktop-v2.2.0 (upstream v1.0.2); the release waits for the owner at cone-release" "$out"
eq "tag: … pushed to origin on that commit" "$c3" "$(git -C "$T/origin.git" rev-parse --verify --quiet 'cone-desktop-v2.2.0^{commit}' || true)"
out="$( cd "$T/repo" && cone/upstream-watch.sh tag "$c2" "$c3" )"
eq "tag: a commit already tagged is not tagged again" "upstream-watch: $c3 is already cone-desktop-v2.2.0" "$out"
( cd "$T/repo" && echo main > cone/UPSTREAM && git commit -qam "cone/UPSTREAM: main" )
c4="$(git -C "$T/repo" rev-parse HEAD)"
if ( cd "$T/repo" && cone/upstream-watch.sh tag "$c3" "$c4" >/dev/null 2>&1 ); then bad "tag refuses a cone/UPSTREAM that is not a stable tag"; else ok "tag refuses a cone/UPSTREAM that is not a stable tag"; fi

# --- triage: each commit once, under the first group it matches
(
  cd "$T/repo"
  git tag v-old HEAD
  for s in "fix(identity): keep the saved key safe" "fix(messages): space one author's messages" \
           "fix(relay): keep delivery during a pause" "Fix Windows sign-in styling" "feat(charts): a renderer"; do
    git commit -q --allow-empty -m "$s"
  done
  git tag v-new
)
tri="$( cd "$T/repo" && cone/upstream-watch.sh triage v-old v-new )"
sec="$(printf '%s\n' "$tri" | sed -n '/^#### Security/,/^####/p')"
has "triage: an identity fix is under security" "keep the saved key safe" "$sec"
has "triage: a commit in two groups is under the first" "Windows sign-in styling" "$sec"
hasnt "triage: 'author' is not 'auth'" "author's" "$sec"
has "triage: relay group counted" "^#### Relay, sync and membership (1)" "$tri"
once=1
for s in "keep the saved key safe" "space one author's messages" "keep delivery during a pause" "Windows sign-in styling" "a renderer"; do
  n="$(grep -c -F "$s" <<<"$tri" || true)"
  [[ "$n" == 1 ]] || { bad "triage: '$s' listed $n times"; once=0; }
done
(( once )) && ok "triage: every commit listed exactly once"
has "triage: the count" '^\*\*5 commits\*\*' "$tri"

# --- disable-workflows: every active workflow but Cone's is disabled
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
# stub: `workflow list`/`release view … --jq <f>` answer their fixture through jq <f> (a
# missing release fixture is gh's "release not found"); `pr list` finds none; `workflow
# disable <name>` and `pr create` are recorded
jqf() { local f=""; while (( $# )); do [[ "$1" == --jq ]] && f="$2"; shift; done; echo "$f"; }
if [[ "$1 $2" == "workflow list" ]]; then
  jq -r "$(jqf "$@")" "$GH_FIXTURE"
elif [[ "$1 $2" == "release view" ]]; then
  [[ -f "${GH_RELEASE:-}" ]] || { echo "release not found" >&2; exit 1; }
  jq -r "$(jqf "$@")" "$GH_RELEASE"
elif [[ "$1 $2" == "pr list" ]]; then
  :
elif [[ "$1 $2" == "pr create" ]]; then
  echo "pr create" >> "$GH_LOG"
elif [[ "$1 $2" == "workflow disable" ]]; then
  echo "${@: -1}" >> "$GH_LOG"
else
  echo "gh stub: unexpected $*" >&2; exit 2
fi
EOF
chmod +x "$T/bin/gh"
cat > "$T/workflows.json" <<'EOF'
[{"path":".github/workflows/cone-desktop.yml","state":"active"},
 {"path":".github/workflows/cone-upstream.yml","state":"active"},
 {"path":".github/workflows/ci.yml","state":"disabled_manually"},
 {"path":".github/workflows/desktop-new.yml","state":"active"},
 {"path":".github/workflows/cone-desktop.yml.bak","state":"active"},
 {"path":".github/workflows/release.yml","state":"disabled_fork"}]
EOF
: > "$T/disabled.log"
PATH="$T/bin:$PATH" GH_FIXTURE="$T/workflows.json" GH_LOG="$T/disabled.log" "$W" disable-workflows >/dev/null
eq "disable-workflows: the active upstream ones, nothing of Cone's" "cone-desktop.yml.bak desktop-new.yml" "$(sort "$T/disabled.log" | tr '\n' ' ' | sed 's/ $//')"

# --- pick: an explicit tag must be a published stable release, like the newest is
pub=$'v1.0.4\nv1.0.3\nv1.0.2'
eq "pick: a published stable tag asked for" "v1.0.3" "$(printf '%s\n' "$pub" | "$W" pick v1.0.2 v1.0.3)"
eq "pick: no tag asked for is the newest" "v1.0.4" "$(printf '%s\n' "$pub" | "$W" pick v1.0.2)"
if printf '%s\n' "$pub" | "$W" pick v1.0.2 v1.0.9 >/dev/null 2>&1; then bad "pick refuses a tag with no published release"; else ok "pick refuses a tag with no published release"; fi
if printf '' | "$W" pick v1.0.2 v1.0.3 >/dev/null 2>&1; then bad "pick refuses a draft or prerelease (not in the list)"; else ok "pick refuses a draft or prerelease (not in the list)"; fi
if printf 'v1.0.2\n' | "$W" pick v1.0.2 v1.0.2 >/dev/null 2>&1; then bad "pick refuses a tag not newer than cone/UPSTREAM"; else ok "pick refuses a tag not newer than cone/UPSTREAM"; fi

# --- guard: a workflow file the merge adds, or changes while it is not disabled_manually
G="$T/guard"; git init -q -b cone "$G"
(
  cd "$G"; git config user.name test; git config user.email test@cone.digital
  mkdir -p .github/workflows
  for f in ci release cone-desktop desktop-build "my flow"; do echo "on: push" > ".github/workflows/$f.yml"; done
  git add -A; git commit -q -m base; git tag g-base
  echo "on: [push, pull_request]" > .github/workflows/new.yml; git add -A; git commit -q -m add; git tag g-add
  git reset -q --hard g-base; echo "# changed" >> .github/workflows/ci.yml; git rm -q .github/workflows/desktop-build.yml
  echo notes > .github/workflows/README.md; git add -A; git commit -q -m change; git tag g-change
  git reset -q --hard g-base; echo "# changed" >> .github/workflows/release.yml; git commit -qam live; git tag g-live
  git reset -q --hard g-base; git mv .github/workflows/ci.yml .github/workflows/ci2.yml; git commit -qm rename; git tag g-rename
  git reset -q --hard g-base; echo "on: push" > .github/workflows/发布.yml; git add -A; git commit -qm unicode; git tag g-unicode
  git reset -q --hard g-base; echo "on: push" > .github/workflows/Deploy.YML; git add -A; git commit -qm upper; git tag g-upper
  git reset -q --hard g-base; echo "# changed" >> ".github/workflows/my flow.yml"; git commit -qam space; git tag g-space
)
states=$'disabled_manually .github/workflows/ci.yml\ndisabled_fork .github/workflows/release.yml\nactive .github/workflows/cone-desktop.yml\ndisabled_manually .github/workflows/desktop-build.yml\ndisabled_manually .github/workflows/my flow.yml'
mkdir -p "$G/cone"; cp "$W" "$G/cone/upstream-watch.sh" # the script works in its own repository
gw() { ( cd "$G" && printf '%s\n' "$states" | cone/upstream-watch.sh guard "$1" "$2" 2>&1 ); }
if ( cd "$G" && printf '' | cone/upstream-watch.sh guard g-base no-such-ref >/dev/null 2>&1 ); then bad "guard stops when it cannot diff"; else ok "guard stops when it cannot diff"; fi
if out="$(gw g-base g-add)"; then bad "guard refuses an added workflow"; else has "guard refuses an added workflow, naming it" "new.yml: new" "$out"; fi
if out="$(gw g-base g-change)"; then ok "guard passes a change to a disabled_manually workflow, a deletion and a non-YAML file"; else bad "guard passes a change to a disabled_manually workflow: $out"; fi
if out="$(gw g-base g-live)"; then bad "guard refuses a changed workflow that is not disabled_manually"; else has "guard refuses a changed workflow that is not disabled_manually (disabled_fork)" "release.yml: changed, state 'disabled_fork'" "$out"; fi
if out="$(gw g-base g-rename)"; then bad "guard refuses a renamed workflow (a new path)"; else has "guard refuses a renamed workflow (a new path)" "ci2.yml: new" "$out"; fi
if out="$(gw g-base g-unicode)"; then bad "guard refuses an added workflow with a non-ASCII name"; else has "guard refuses an added workflow with a non-ASCII name, named as stored" "发布.yml: new" "$out"; fi
if out="$(gw g-base g-upper)"; then bad "guard refuses an added .YML workflow"; else has "guard refuses an added .YML workflow" "Deploy.YML: new" "$out"; fi
if out="$(gw g-base g-space)"; then ok "guard matches a workflow's state by its whole path (a name with a space)"; else bad "guard matches a workflow's state by its whole path (a name with a space): $out"; fi

# --- run: the whole path up to the push, against a local upstream and a bare fork origin
U="$T/up"; git init -q -b main "$U"
(
  cd "$U"; git config user.name up; git config user.email up@example.com
  mkdir -p .github/workflows; echo a > app.txt; echo "on: push" > .github/workflows/ci.yml
  git add -A; git commit -q -m one; git tag v1.0.0
  echo "on: [push, pull_request]" > .github/workflows/new.yml; echo b > app.txt; git add -A; git commit -q -m two; git tag v1.0.1
  git reset -q --hard v1.0.0; echo "# changed" >> .github/workflows/ci.yml; echo c > app.txt; git commit -qam three; git tag v1.0.2
)
git init -q --bare "$T/fork.git"; F="$T/fork"; git init -q -b cone "$F"
(
  cd "$F"; git config user.name test; git config user.email test@cone.digital
  git fetch -q "$U" "+refs/tags/v1.0.0:refs/tags/v1.0.0"; git reset -q --hard v1.0.0
  mkdir -p cone; cp "$W" cone/upstream-watch.sh; echo v1.0.0 > cone/UPSTREAM
  git add -A; git commit -q -m "cone"; git tag cone-desktop-v2.3.0
  git remote add origin "$T/fork.git"; git push -q origin cone cone-desktop-v2.3.0; git fetch -q origin
)
cat > "$T/bin/pnpm" <<'EOF'
#!/usr/bin/env bash
echo "pnpm $*" >> "$GH_LOG"
EOF
chmod +x "$T/bin/pnpm"
echo '[{"path":".github/workflows/ci.yml","state":"disabled_manually"},{"path":".github/workflows/cone-upstream.yml","state":"active"}]' > "$T/states.json"
runf() { # <tag> <release fixture or ""> → the run's output; the exit status in $T/rc
  : > "$T/run.log"
  ( cd "$F" && PATH="$T/bin:$PATH" CONE_UPSTREAM_URL="$U" GH_RELEASE="$2" GH_FIXTURE="$T/states.json" GH_LOG="$T/run.log" \
      cone/upstream-watch.sh run "$1" 2>&1; echo $? > "$T/rc" )
}
pushed() { git -C "$T/fork.git" for-each-ref --format='%(refname:short)' 'refs/heads/cone-update/*' | tr '\n' ' ' | sed 's/ $//'; }
# (v1.0.2 passes the workflow guard, so only the release check can stop these two)
echo '{"tagName":"v1.0.2","isDraft":false,"isPrerelease":true}' > "$T/rel-pre.json"
out="$(runf v1.0.2 "$T/rel-pre.json")"
eq "run refuses an explicit tag whose release is a prerelease" "1" "$(cat "$T/rc")"
has "… saying it is not a published stable release" "not a published, non-draft, non-prerelease" "$out"
out="$(runf v1.0.2 "")"
eq "run refuses an explicit tag with no release (a draft is invisible: not found)" "1" "$(cat "$T/rc")"
eq "… and neither pushed a branch" "" "$(pushed)"
echo '{"tagName":"v1.0.1","isDraft":false,"isPrerelease":false}' > "$T/rel-101.json"
out="$(runf v1.0.1 "$T/rel-101.json")"
eq "run stops when the merge adds a workflow" "1" "$(cat "$T/rc")"
has "… naming it" "new.yml: new" "$out"
eq "… and pushed no branch" "" "$(pushed)"
hasnt "… and opened no pull request" "pr create" "$(cat "$T/run.log")"
echo '{"tagName":"v1.0.2","isDraft":false,"isPrerelease":false}' > "$T/rel-102.json"
out="$(runf v1.0.2 "$T/rel-102.json")"
eq "run passes a change to a disabled_manually workflow" "0" "$(cat "$T/rc")"
eq "… pushed cone-update/v1.0.2 with cone/UPSTREAM set" "v1.0.2" "$(git -C "$T/fork.git" show cone-update/v1.0.2:cone/UPSTREAM 2>/dev/null)"
has "… and opened the pull request" "^pr create" "$(cat "$T/run.log")"
echo '[{"path":".github/workflows/ci.yml","state":"disabled_fork"}]' > "$T/states.json"
git -C "$F" switch -q cone; git -C "$F" branch -q -D cone-update/v1.0.2; git -C "$T/fork.git" branch -q -D cone-update/v1.0.2
out="$(runf v1.0.2 "$T/rel-102.json")"
has "run stops when a changed workflow is not disabled_manually" "ci.yml: changed, state 'disabled_fork'" "$out"
hasnt "… before pnpm" "pnpm" "$(cat "$T/run.log")"
eq "… and pushed no branch" "" "$(pushed)"

echo "upstream-test: $pass passed, $fail failed"
(( fail == 0 ))
