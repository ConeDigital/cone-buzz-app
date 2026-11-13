#!/usr/bin/env bash
# The rebrand's mutation test on Buzz 1.0 (cone-buzz-infra Slice 51,
# criterion 1; Slice 36's test, ported): each planted change must make the
# guard it targets fail with that guard's diagnostic, naming the planted path.
#
#   bash cone/rebrand-test.sh        (from the repository root, hermit active, pnpm install done)
#
# Every case runs in a disposable worktree at HEAD where the plant is
# COMMITTED (an uncommitted plant is refused by the dirty-tree guard first,
# which would never exercise the intended guard — review of
# ConeDigital/cone-buzz#8). The worktree borrows this checkout's node_modules
# (the transform parses with the app's own rolldown).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$PWD"

pass=0; fail=0
snapshot() { # prints the path of a fresh committed worktree at HEAD
  local tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/cone-rebrand-test.XXXXXX")"
  git worktree add -q --detach "$tmp" HEAD
  ln -s "$ROOT/node_modules" "$tmp/node_modules"
  printf '/node_modules\n' >> "$(git -C "$tmp" rev-parse --git-path info/exclude)"
  echo "$tmp"
}
drop() { git worktree remove --force "$1" >/dev/null 2>&1 || true; }
verdict() { # <name> <want path> <want diagnostic> <exit status> <output>
  local name="$1" want_path="$2" want_diag="$3" status="$4" out="$5"
  if [[ "$status" == 0 ]]; then
    echo "FAIL $name: the guard passed"; fail=$((fail + 1))
  elif grep -qF "is not clean" <<<"$out"; then
    echo "FAIL $name: refused as dirty instead of judged"; fail=$((fail + 1))
  elif ! grep -qF "$want_path" <<<"$out" || ! grep -qF "$want_diag" <<<"$out"; then
    echo "FAIL $name: failed without '$want_diag' on $want_path"; echo "$out" | tail -4; fail=$((fail + 1))
  else
    echo "ok   $name"; pass=$((pass + 1))
  fi
}

# case_ <name> <path that must be named> <diagnostic that must appear> <plant function>
case_() {
  local name="$1" want_path="$2" want_diag="$3" plant="$4" tmp out status=0
  tmp="$(snapshot)"
  ( cd "$tmp" && "$plant" && git add -A && git -c user.name=test -c user.email=test@cone.digital commit -q -m "plant: $name" )
  out="$( cd "$tmp" && cone/rebrand.sh check 2>&1 )" || status=$?
  verdict "$name" "$want_path" "$want_diag" "$status" "$out"
  drop "$tmp"
}

# 1. an extra "Buzz" string in a listed file: its count moves
p1() { printf '\nexport const PLANTED_ONE = "Planted Buzz string";\n' >> src/app/Settings.tsx; }
case_ "extra Buzz string in a listed file" src/app/Settings.tsx "in string text, strings.tsv says 2" p1

# 2. a "Block …" string in a listed file: the count is unchanged, the scan must see it
p2() { printf '\nexport const PLANTED_TWO = "Block built this";\n' >> src/app/Settings.tsx; }
case_ "Block string in a listed file" src/app/Settings.tsx "rebrand scan: src/app/Settings.tsx" p2

# 3. a "Buzz" string in an unlisted file
p3() { printf '\nexport const PLANTED_THREE = "Buzz here";\n' >> src/main.tsx; }
case_ "Buzz string in an unlisted file" src/main.tsx "strings.tsv says 0" p3

# 4. a line in a raw-imported prompt (whole text: comments and prose alike)
p4() { printf '\nPlanted: Buzz again.\n' >> src/features/agent-harness/base_prompt.md; }
case_ "line in a raw-imported prompt" src/features/agent-harness/base_prompt.md "in string text, strings.tsv says" p4

# 5. a comment in a raw-imported launcher: what is written to disk counts too
p5() { printf '\n# Planted: Buzz in a comment.\n' >> src/bundled/codex/codex.sh; }
case_ "comment in a raw-imported script" src/bundled/codex/codex.sh "in string text, strings.tsv says" p5

# 6. the bee motif
p6() { printf '\nexport const PLANTED_SIX = "a bee in the corner";\n' >> src/main.tsx; }
case_ "bee string" src/main.tsx ": bee:" p6

# 6b. the word in capitals, which the word rule does not rewrite
p6b() { printf '\nexport const PLANTED_SIXB = "BUZZ ONLY";\n' >> src/main.tsx; }
case_ "BUZZ in capitals" src/main.tsx ": BUZZ:" p6b

# 7. a lines.tsv row whose upstream text was edited
p7() { sed -i '' 's|context.scale(52 / 64, 52 / 64);|context.scale(52 / 64, 53 / 64);|' src/features/agents/share-card.ts; }
case_ "edited lines.tsv target" src/features/agents/share-card.ts "found 0 times, expected 1" p7

# 8. a deleted replacement target
p8() { rm public/welcome-bee.svg; }
case_ "deleted replacement target" public/welcome-bee.svg "replacement target missing upstream" p8

# 9. a replacement whose upstream content was edited: the hash moves
p9() { printf '\n<!-- upstream edited this file -->\n' >> public/buzz-mark.svg; }
case_ "edited replacement upstream" public/buzz-mark.svg "upstream content changed" p9

# 10. a kept runtime name used once more upstream: its count moves (a new use is reviewed, not kept blindly)
p10() { printf '\nexport const PLANTED_TEN = { "X-Buzz-Read-Priority": "low" };\n' >> src/features/relay/transport.ts; }
case_ "kept runtime name used once more" src/features/relay/transport.ts "keep.tsv says 4" p10

# 11. a kept runtime name gone upstream (the relay's NIP-11 name compared differently)
p11() { sed -i '' 's/name !== "Buzz Relay" \&\&/name !== "Buzz Relay 2" \&\&/' src/features/communities/community-name.ts; }
case_ "kept runtime name changed upstream" src/features/communities/community-name.ts "keep.tsv says 1" p11

# 12. a new include_str! source with the word
p12() { printf '\nconst PLANTED_TWELVE: &str = include_str!("planted.md");\n' >> src-tauri/src/keep_awake.rs; printf '# Buzz planted\n' > src-tauri/src/planted.md; }
case_ "new embedded template" src-tauri/src/planted.md "strings.tsv says 0" p12

# 13. a new ?raw import with the word
p13() { printf '\nimport planted from "./planted.sh?raw";\nexport const PLANTED_THIRTEEN = planted;\n' >> src/main.tsx; printf '# Buzz planted\n' > src/planted.sh; }
case_ "new raw import" src/planted.sh "strings.tsv says 0" p13

# 14. the window delta refuses an upstream title that is no longer the word
tmp="$(snapshot)"; status=0
out="$( cd "$tmp" && sed -i '' 's/"title": "Buzz"/"title": "Foundation"/' src-tauri/tauri.macos.conf.json && node cone/rebrand/transform.mjs window-delta aarch64-apple-darwin 2>&1 )" || status=$?
verdict "window title moved upstream" "window-delta" "not upstream's Buzz" "$status" "$out"; drop "$tmp"

# 15–16. the bundle gate, on a planted build output (no build: bundle-scan reads dist/ only)
tmp="$(snapshot)"; mkdir -p "$tmp/dist/assets"; printf '<title>Cone</title>\n' > "$tmp/dist/index.html"
printf 'const h={"X-Buzz-Live-ID":1},y="Hello Buzz";\n' > "$tmp/dist/assets/planted.js"; status=0
out="$( cd "$tmp" && cone/rebrand.sh bundle-scan 2>&1 )" || status=$?
verdict "whole word in the bundle" "dist/assets/planted.js" "the word Buzz 1 time(s)" "$status" "$out"
printf 'const h={"X-Buzz-Live-ID":1};\n' > "$tmp/dist/assets/planted.js"
if out="$( cd "$tmp" && cone/rebrand.sh bundle-scan 2>&1 )" && grep -qF "1 of them" <<<"$out"; then
  echo "ok   kept runtime name in the bundle passes"; pass=$((pass + 1))
else echo "FAIL kept runtime name in the bundle: $out"; fail=$((fail + 1)); fi
drop "$tmp"

echo "rebrand-test: $pass passed, $fail failed"
(( fail == 0 ))
