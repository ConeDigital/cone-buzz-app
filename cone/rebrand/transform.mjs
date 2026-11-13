#!/usr/bin/env node
// The in-app rebrand's transform on Buzz 1.0 (cone-buzz-infra Slice 51,
// ADR-364; the mechanism of Slice 36 / ADR-237, ported from
// ConeDigital/cone-buzz to this fork's layout).
//
// Rewrites the capitalised word "Buzz" inside *string text only* — TypeScript,
// TSX and JavaScript string literals, template literal text and JSX text; Rust
// string literals; whole text files the app embeds (Markdown and JSON a module
// imports, `include_str!` sources, the launch page, the SVGs in public/) — and
// scans the same text for anything branded that remains. Identifiers,
// comments, URLs and every lower-case `buzz` are never touched. Driven by
// cone/rebrand.sh; the manifests live beside this file:
//
//   word              the replacement word, one line
//   strings.tsv       path<TAB>count — the exact number of word hits in the
//                     file's string text after blocks and lines are applied
//   lines.tsv         path<TAB>old<TAB>new[<TAB>count] — old/new as JSON
//                     strings; old must occur exactly `count` (default 1) times
//   keep.tsv          path<TAB>text<TAB>count<TAB>reason — a string (JSON)
//                     whose `Buzz` is a runtime name, not a brand: it occurs
//                     exactly `count` times in the file's string text and the
//                     word rule leaves every hit inside it alone
//   replacements.tsv  path<TAB>sha256 — files/<path> replaces the upstream file
//                     whose content hashes so ("-": a new file, must not exist)
//   exceptions.tsv    path<TAB>text<TAB>reason — a scan hit on a line that
//                     contains `text` in that file is not a finding
//
// Commands (cwd: the repository root):
//   measure        print path<TAB>count for every scoped file with hits (after keep)
//   hits           print path:line<TAB>the string text around each hit (for review)
//   apply          lines, the word rule (counts verified); exit 1 on any miss
//   apply-prefix   lines only (what `measure` counts after)
//   scan           after apply: every branded residue, exit 1 if any
//   bundle-residue <files…>  the built frontend: the word outside kept runtime names, exit 1 if any
//   window-delta <target>    a Tauri --config delta: upstream's windows for that target's platform, titled with the word
//   paths          every path apply may write (for restore)
//   roots          every directory apply may write under
//   scope          every file in scope, one per line
//
// The replacements (whole files) are the shell driver's job: it hashes and
// copies, this script never does.

import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";

const ROOT = process.cwd();
const HERE = path.join(ROOT, "cone", "rebrand");
const WORD = "Buzz";
// TypeScript 7 (the native compiler upstream pins) has no JavaScript API; the
// parser is rolldown's (oxc), a direct dependency of the app, ESTree with
// UTF-16 offsets.
const require = createRequire(path.join(ROOT, "package.json"));
const { parseAst } = require("rolldown/parseAst");

// ---------------------------------------------------------------- scope ----

// The app crate and every workspace crate it links, transitively (path
// dependencies in each Cargo.toml's dependency tables), plus the agent command
// the app bundles as a sidecar (scripts/build-agent-command.mjs): their string
// literals end up in a binary the app ships.
const SIDECAR_CRATES = ["crates/agent-command"];

function pathDeps(crateDir) {
  const toml = fs.readFileSync(path.join(ROOT, crateDir, "Cargo.toml"), "utf8");
  const deps = [];
  let section = "";
  for (const line of toml.split("\n")) {
    const h = line.match(/^\s*\[([^\]]+)\]/);
    if (h) { section = h[1]; continue; }
    if (!/(^|\.)(dependencies|build-dependencies)$/.test(section) || /dev-dependencies/.test(section)) continue;
    const m = line.match(/path\s*=\s*"([^"]+)"/);
    if (m) deps.push(path.relative(ROOT, path.resolve(ROOT, crateDir, m[1])));
  }
  return deps;
}

function linkedCrates() {
  const seen = new Set();
  const queue = ["src-tauri", ...SIDECAR_CRATES];
  while (queue.length) {
    const c = queue.shift();
    if (seen.has(c)) continue;
    seen.add(c);
    for (const d of pathDeps(c)) queue.push(d);
  }
  return [...seen].sort();
}
const CRATES = linkedCrates();
const RUST_ROOTS = CRATES.map((c) => `${c}/src`);
const SRC_ROOTS = ["src", "public", ...RUST_ROOTS];

const TEST_TS = /\.(test|spec|fixture|stories|conformance)\.[^/]+$/;

function isRustSource(rel) {
  if (!rel.endsWith(".rs")) return false;
  if (/(_tests?|\/tests)\.rs$/.test(rel)) return false;
  if (/\/(tests|testdata|fixtures|benches|examples)\//.test(rel)) return false;
  return true;
}

function isScopedSource(rel) {
  if (RUST_ROOTS.some((r) => rel.startsWith(r + "/"))) return isRustSource(rel);
  if (rel.startsWith("src/")) {
    if (!/\.(ts|tsx|js|mjs)$/.test(rel) || rel.endsWith(".d.ts")) return false;
    if (TEST_TS.test(rel)) return false;
    if (/\/(testing|__tests__|__mocks__|tests|fixtures)\//.test(rel)) return false;
    if (/(^|\/)([a-z-]+-)?testing\.tsx?$/.test(rel)) return false;
    return true;
  }
  if (rel.startsWith("public/")) return /\.(js|svg)$/.test(rel);
  return false;
}

function walk(dir, out) {
  if (!fs.existsSync(dir)) return out;
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (entry.name === "node_modules" || entry.name === "target" || entry.name === "dist") continue;
      walk(p, out);
    } else if (entry.isFile()) out.push(path.relative(ROOT, p));
  }
  return out;
}

function scopedSources() {
  const all = [];
  for (const r of SRC_ROOTS) walk(path.join(ROOT, r), all);
  return all.filter(isScopedSource).sort();
}

// Text a scoped Rust file embeds with include_str!: in scope as whole text.
function rustIncludes(sources) {
  const found = new Set();
  for (const rel of sources) {
    if (!rel.endsWith(".rs")) continue;
    const text = fs.readFileSync(path.join(ROOT, rel), "utf8");
    const tests = rustTestSpans(text);
    for (const m of text.matchAll(/include_str!\(\s*"([^"]+)"\s*,?\s*\)/g)) {
      if (tests.some(([a, b]) => m.index >= a && m.index < b)) continue; // a test's fixture, not shipped
      found.add(path.relative(ROOT, path.resolve(ROOT, path.dirname(rel), m[1])));
    }
  }
  return [...found];
}

// Text a scoped module imports as a string (`./x.md?raw`, `./codex.sh?raw`,
// `@/…/manifest.json`) or globs (`import.meta.glob("./*/README.md")`): in
// scope as whole text, comments included — a raw import reaches the bundle
// and the disk verbatim (the harness launchers and hosts are written out and
// run). Shaders, stylesheets and packages' icons carry no words.
function resolveSpec(fromRel, spec) {
  const bare = spec.replace(/\?.*$/, "");
  if (bare.startsWith("@/")) return path.join("src", bare.slice(2));
  if (bare.startsWith(".")) return path.relative(ROOT, path.resolve(ROOT, path.dirname(fromRel), bare));
  return null;
}

function globToRegExp(glob) {
  let re = "";
  for (let i = 0; i < glob.length; i++) {
    const c = glob[i];
    if (c === "*") re += "[^/]*";
    else if (c === "{") { const end = glob.indexOf("}", i); re += "(" + glob.slice(i + 1, end).split(",").map(escapeRe).join("|") + ")"; i = end; }
    else re += escapeRe(c);
  }
  return new RegExp("^" + re + "$");
}
function escapeRe(s) { return s.replace(/[.+?^${}()|[\]\\/]/g, "\\$&"); }

function moduleTextImports(sources) {
  const found = new Set();
  for (const rel of sources) {
    if (!/\.(ts|tsx|js|mjs)$/.test(rel)) continue;
    const text = fs.readFileSync(path.join(ROOT, rel), "utf8");
    for (const m of text.matchAll(/(?:from|import)\s*\(?\s*["']([^"']+(?:\.(?:md|json|txt)|\?raw))["']/g)) {
      if (/\.(frag|vert|css|svg)\?raw$/.test(m[1])) continue;
      const r = resolveSpec(rel, m[1]);
      if (r && fs.existsSync(path.join(ROOT, r))) found.add(r);
    }
    for (const m of text.matchAll(/import\.meta\.glob(?:<[^>]*>)?\(\s*["']([^"']+\.(?:md|json|txt))["']/g)) {
      const pattern = resolveSpec(rel, m[1]);
      if (!pattern) continue;
      const re = globToRegExp(pattern);
      const base = pattern.slice(0, pattern.search(/[*{]/)).replace(/\/[^/]*$/, "");
      for (const f of walk(path.join(ROOT, base), [])) if (re.test(f)) found.add(f);
    }
  }
  return [...found];
}

// The HTML entry pages at the repository root (index.html, huddle.html, …).
const WHOLE_TEXT_FIXED = fs.readdirSync(ROOT).filter((f) => f.endsWith(".html")).sort();

let WHOLE = null; // the whole-text files, once scopeAll has run
function scopeAll() {
  const sources = scopedSources();
  const wholeText = [...new Set([...rustIncludes(sources), ...moduleTextImports(sources), ...WHOLE_TEXT_FIXED])]
    .filter((p) => !/\/(tests|testdata|fixtures)\//.test(p))
    .sort();
  const all = [...new Set([...sources, ...wholeText])].sort(); // a source both scoped and embedded counts once
  WHOLE = new Set(wholeText);
  return { sources, wholeText, all };
}

// --------------------------------------------------------- string text ----

// Returns [start, end) ranges of string text in a file's content.
function textRanges(rel, content) {
  if (WHOLE === null) scopeAll();
  if (WHOLE.has(rel)) return [[0, content.length]]; // embedded or raw-imported: every character ships
  if (/\.(ts|tsx|js|mjs)$/.test(rel)) return tsRanges(rel, content);
  if (rel.endsWith(".rs")) return rustRanges(content);
  return [[0, content.length]]; // markdown, json, svg, html: whole text
}

function tsRanges(rel, content) {
  const lang = rel.endsWith(".tsx") ? "tsx" : rel.endsWith(".ts") ? "ts" : "jsx";
  const ast = parseAst(content, { lang, sourceType: "module" }, rel);
  const ranges = [];
  const visit = (node) => {
    if (!node || typeof node !== "object") return;
    if (Array.isArray(node)) { node.forEach(visit); return; }
    if ((node.type === "Literal" && typeof node.value === "string") || node.type === "JSXText" || node.type === "TemplateElement") {
      ranges.push([node.start, node.end]);
      return;
    }
    for (const k in node) if (k !== "parent" && typeof node[k] === "object") visit(node[k]);
  };
  visit(ast);
  return ranges.sort((a, b) => a[0] - b[0]);
}

// A small Rust lexer: skips // and /* */ comments (nested), char literals,
// lifetimes and every `#[cfg(test)]` item (the brace-delimited item that
// follows the attribute); yields "..." (with escapes), r#"..."#, b"...",
// br"..." literals, delimiters included (so a keep row can name the exact
// literal `"Buzz"`). rustTestSpans() gives the skipped test items.
function rustRanges(src) { return rustLex(src).ranges; }
function rustTestSpans(src) { return rustLex(src).tests; }
function rustLex(src) {
  const ranges = [];
  const tests = [];
  let testStart = -1;
  let i = 0;
  const n = src.length;
  let testPending = false;
  let testDepth = 0;
  const push = (r) => { if (testDepth === 0) ranges.push(r); };
  while (i < n) {
    const c = src[i];
    const d = src[i + 1];
    if (c === "#" && src.startsWith("#[cfg(test)]", i)) { testPending = true; i += 12; continue; }
    if (c === ";" && testPending) { testPending = false; i++; continue; }
    if (c === "{" && (testPending || testDepth > 0)) { if (testDepth === 0) testStart = i; testPending = false; testDepth++; i++; continue; }
    if (c === "}" && testDepth > 0) { testDepth--; if (testDepth === 0) tests.push([testStart, i + 1]); i++; continue; }
    if (c === "/" && d === "/") {
      while (i < n && src[i] !== "\n") i++;
      continue;
    }
    if (c === "/" && d === "*") {
      let depth = 1;
      i += 2;
      while (i < n && depth > 0) {
        if (src[i] === "/" && src[i + 1] === "*") { depth++; i += 2; continue; }
        if (src[i] === "*" && src[i + 1] === "/") { depth--; i += 2; continue; }
        i++;
      }
      continue;
    }
    if (c === "'") {
      if (d === "\\") {
        let j = i + 2;
        while (j < n && src[j] !== "'") j++;
        i = j + 1;
        continue;
      }
      if (src[i + 2] === "'") { i += 3; continue; }
      i++;
      continue;
    }
    if ((c === "r" || (c === "b" && d === "r")) && /[^A-Za-z0-9_]/.test(src[i - 1] ?? " ")) {
      let j = c === "b" ? i + 2 : i + 1;
      let hashes = 0;
      while (src[j] === "#") { hashes++; j++; }
      if (src[j] === '"') {
        const close = '"' + "#".repeat(hashes);
        const end = src.indexOf(close, j + 1);
        if (end < 0) throw new Error("unterminated raw string");
        push([i, end + close.length]);
        i = end + close.length;
        continue;
      }
    }
    if (c === '"') {
      let j = i + 1;
      while (j < n) {
        if (src[j] === "\\") { j += 2; continue; }
        if (src[j] === '"') break;
        j++;
      }
      push([c === '"' && src[i - 1] === "b" ? i - 1 : i, j + 1]);
      i = j + 1;
      continue;
    }
    i++;
  }
  return { ranges, tests };
}

const WORD_RE = () => new RegExp(`\\b${WORD}\\b`, "g");

// Every word hit in string text, as absolute offsets, minus the hits that sit
// inside a keep.tsv text for this file. Returns { hits, keepCounts }.
function wordHits(rel, content, ranges, keeps) {
  const hits = [];
  for (const [s, e] of ranges) {
    const slice = content.slice(s, e);
    for (const m of slice.matchAll(WORD_RE())) hits.push(s + m.index);
  }
  const kept = new Set();
  const keepCounts = new Map();
  for (const text of keeps) {
    let count = 0;
    for (const [s, e] of ranges) {
      const slice = content.slice(s, e);
      let from = 0;
      for (;;) {
        const at = slice.indexOf(text, from);
        if (at < 0) break;
        count++;
        for (const m of text.matchAll(WORD_RE())) kept.add(s + at + m.index);
        from = at + text.length;
      }
    }
    keepCounts.set(text, count);
  }
  return { hits: hits.filter((h) => !kept.has(h)), keepCounts };
}

// ------------------------------------------------------------- manifests ----

function readTsv(name, columns) {
  const file = path.join(HERE, name);
  if (!fs.existsSync(file)) return [];
  return fs
    .readFileSync(file, "utf8")
    .split("\n")
    .filter((l) => l && !l.startsWith("#"))
    .map((l, i) => {
      const cells = l.split("\t");
      if (cells.length < columns) throw new Error(`${name}:${i + 1}: expected ${columns} columns`);
      return cells;
    });
}

function readKeeps() {
  const byPath = new Map();
  for (const [rel, textJson, count] of readTsv("keep.tsv", 4)) {
    const list = byPath.get(rel) ?? [];
    list.push({ text: JSON.parse(textJson), count: Number(count) });
    byPath.set(rel, list);
  }
  return byPath;
}

function readWord() {
  const w = fs.readFileSync(path.join(HERE, "word"), "utf8").trim();
  if (!/^[A-Z][A-Za-z]+$/.test(w)) throw new Error(`word: '${w}' is not a capitalised word`);
  return w;
}

// --------------------------------------------------------------- commands --

function measure() {
  const keeps = readKeeps();
  const rows = [];
  for (const rel of scopeAll().all) {
    const content = fs.readFileSync(path.join(ROOT, rel), "utf8");
    const { hits } = wordHits(rel, content, textRanges(rel, content), (keeps.get(rel) ?? []).map((k) => k.text));
    if (hits.length > 0) rows.push(`${rel}\t${hits.length}`);
  }
  process.stdout.write(rows.join("\n") + (rows.length ? "\n" : ""));
}

function hitsCmd() {
  const keeps = readKeeps();
  const out = [];
  for (const rel of scopeAll().all) {
    const content = fs.readFileSync(path.join(ROOT, rel), "utf8");
    const ranges = textRanges(rel, content);
    const { hits } = wordHits(rel, content, ranges, (keeps.get(rel) ?? []).map((k) => k.text));
    for (const h of hits) {
      const [s, e] = ranges.find(([a, b]) => h >= a && h < b);
      const lineNo = content.slice(0, h).split("\n").length;
      const ctx = content.slice(Math.max(s, h - 60), Math.min(e, h + 60)).replace(/\s+/g, " ");
      out.push(`${rel}:${lineNo}\t${ctx}`);
    }
  }
  process.stdout.write(out.join("\n") + (out.length ? "\n" : ""));
}

function apply() { applyAll(false); }
function applyPrefix() { applyAll(true); }

function applyAll(prefixOnly) {
  const word = readWord();
  const failures = [];
  // 1. lines
  for (const cells of readTsv("lines.tsv", 3)) {
    const [rel, oldJson, newJson, countStr] = cells;
    const want = countStr ? Number(countStr) : 1;
    const old = JSON.parse(oldJson);
    const neu = JSON.parse(newJson);
    const file = path.join(ROOT, rel);
    if (rel.endsWith(".rs") && neu.includes('"#')) { failures.push(`${rel}: line replacement contains '"#', which ends a Rust r#"…"# raw string`); continue; }
    if (!fs.existsSync(file)) { failures.push(`${rel}: missing (lines.tsv)`); continue; }
    const content = fs.readFileSync(file, "utf8");
    const hits = content.split(old).length - 1;
    if (hits !== want) { failures.push(`${rel}: line ${oldJson.slice(0, 60)} found ${hits} times, expected ${want}`); continue; }
    fs.writeFileSync(file, content.split(old).join(neu));
  }
  if (prefixOnly) {
    if (failures.length) { process.stderr.write(failures.map((f) => `rebrand apply: ${f}`).join("\n") + "\n"); process.exit(1); }
    return;
  }
  // 2. the word rule, by exact count, around the kept runtime names
  const expected = new Map(readTsv("strings.tsv", 2).map(([rel, c]) => [rel, Number(c)]));
  const keeps = readKeeps();
  const scope = scopeAll();
  for (const rel of scope.all) {
    const file = path.join(ROOT, rel);
    const content = fs.readFileSync(file, "utf8");
    const ranges = textRanges(rel, content);
    const fileKeeps = keeps.get(rel) ?? [];
    const { hits, keepCounts } = wordHits(rel, content, ranges, fileKeeps.map((k) => k.text));
    for (const k of fileKeeps) {
      const have = keepCounts.get(k.text) ?? 0;
      if (have !== k.count) failures.push(`${rel}: keep ${JSON.stringify(k.text).slice(0, 60)} found ${have} times in string text, keep.tsv says ${k.count}`);
    }
    const want = expected.get(rel) ?? 0;
    if (hits.length !== want) { failures.push(`${rel}: ${hits.length} '${WORD}' in string text, strings.tsv says ${want}`); continue; }
    if (hits.length > 0) {
      let out = "";
      let last = 0;
      for (const h of hits) { out += content.slice(last, h) + word; last = h + WORD.length; }
      fs.writeFileSync(file, out + content.slice(last));
    }
  }
  for (const rel of expected.keys()) {
    if (!scope.all.includes(rel)) failures.push(`${rel}: listed in strings.tsv but not in scope (moved, deleted or excluded)`);
  }
  for (const rel of keeps.keys()) {
    if (!scope.all.includes(rel)) failures.push(`${rel}: listed in keep.tsv but not in scope (moved, deleted or excluded)`);
  }
  if (failures.length) {
    process.stderr.write(failures.map((f) => `rebrand apply: ${f}`).join("\n") + "\n");
    process.exit(1);
  }
  const keepRows = [...keeps.values()].reduce((a, l) => a + l.length, 0);
  process.stdout.write(`rebrand apply: ok (${readTsv("lines.tsv", 3).length} lines, ${expected.size} files by the word rule, ${keepRows} runtime names kept)\n`);
}

const RESIDUE = [
  [() => new RegExp(`\\b${WORD}\\b`, "g"), WORD],
  [() => new RegExp(`\\b${WORD.toUpperCase()}\\b`, "g"), WORD.toUpperCase()], // set in capitals (the share card's "BUZZ AGENT"); BUZZ_* names are not words
  [() => /\bBlock\b/g, "Block"],
  [() => /\bbees?\b/gi, "bee"],
  [() => /🐝/g, "🐝"],
];

function scan() {
  const exceptions = readTsv("exceptions.tsv", 3);
  const keeps = readKeeps();
  const scope = scopeAll();
  const findings = [];
  for (const rel of scope.all) {
    const content = fs.readFileSync(path.join(ROOT, rel), "utf8");
    const lines = content.split("\n");
    const ranges = textRanges(rel, content);
    const fileKeeps = (keeps.get(rel) ?? []).map((k) => k.text);
    for (const [s, e] of ranges) {
      let slice = content.slice(s, e);
      for (const k of fileKeeps) slice = slice.split(k).join(" ".repeat(k.length)); // kept runtime names are not residue
      for (const [mk, label] of RESIDUE) {
        for (const m of slice.matchAll(mk())) {
          const lineNo = content.slice(0, s + m.index).split("\n").length;
          const lineText = lines[lineNo - 1] ?? "";
          const excused = exceptions.some(([p, text]) => p === rel && lineText.includes(text));
          if (!excused) findings.push(`${rel}:${lineNo}: ${label}: ${lineText.trim().slice(0, 140)}`);
        }
      }
    }
  }
  const unique = [...new Set(findings)];
  if (unique.length) {
    process.stderr.write(unique.map((f) => `rebrand scan: ${f}`).join("\n") + `\nrebrand scan: ${unique.length} residue(s)\n`);
    process.exit(1);
  }
  process.stdout.write(`rebrand scan: ok (${scope.all.length} files, ${exceptions.length} exceptions)\n`);
}

// The built frontend: every whole-word Buzz left in the given files must sit
// inside a runtime name keep.tsv lists for a frontend file (its quotes
// dropped: the minifier may change them). Prints a count, or the hits and
// exit 1.
function bundleResidue() {
  const files = process.argv.slice(3);
  scopeAll();
  // A raw-imported file reaches the bundle verbatim, quotes and all; a module
  // is minified, so its keep is matched without its quotes (and a bare
  // "Buzz" from a module would excuse every hit, so it is never one).
  const kept = [...readKeeps().entries()]
    .filter(([rel]) => rel.startsWith("src/") || rel.startsWith("public/") || rel.endsWith(".html"))
    .flatMap(([rel, list]) => list.map((k) => (WHOLE.has(rel) ? k.text : k.text.replace(/^"(.*)"$/s, "$1"))))
    .filter((t) => t !== WORD)
    .sort((a, b) => b.length - a.length);
  let excused = 0;
  const findings = [];
  for (const rel of files) {
    let text = fs.readFileSync(path.join(ROOT, rel), "utf8");
    for (const k of kept) {
      const parts = text.split(k);
      excused += parts.length - 1;
      text = parts.join(" ".repeat(k.length));
    }
    for (const m of text.matchAll(new RegExp(`\\b(${WORD}|${WORD.toUpperCase()})\\b`, "g"))) {
      findings.push(`${rel}: …${text.slice(Math.max(0, m.index - 50), m.index + 54).replace(/\s+/g, " ")}…`);
    }
  }
  if (findings.length) {
    process.stdout.write(findings.slice(0, 30).map((f) => `rebrand bundle-scan: ${f}`).join("\n") + `\nrebrand bundle-scan: the word ${WORD} ${findings.length} time(s) outside the kept runtime names\n`);
    process.exit(1);
  }
  process.stdout.write(`rebrand bundle-scan: ok (${files.length} files; the word ${WORD} only inside kept runtime names, ${excused} of them)\n`);
}

// A Tauri --config delta that names the main window with the word: upstream's
// effective `app.windows` for the target's platform (the platform file's
// array replaces the base's whole, as Tauri merges them, RFC 7396), each
// object unchanged but its title. Generated per build so that upstream's
// window settings are never Cone's stale copy, and each platform keeps its
// own (the macOS window is transparent and hidden until ready; Windows has no
// decorations).
function windowDelta() {
  const target = process.argv[3] ?? "";
  const platform = /apple-darwin$/.test(target) ? "macos" : /windows/.test(target) ? "windows" : /linux/.test(target) ? "linux" : null;
  if (!platform) { process.stderr.write(`window-delta: '${target}' is not a Rust target triple for macOS, Windows or Linux\n`); process.exit(2); }
  const read = (rel) => JSON.parse(fs.readFileSync(path.join(ROOT, rel), "utf8"));
  const base = read("src-tauri/tauri.conf.json");
  const platformFile = `src-tauri/tauri.${platform}.conf.json`;
  const own = fs.existsSync(path.join(ROOT, platformFile)) ? read(platformFile) : {};
  const windows = own.app?.windows ?? base.app?.windows;
  if (!Array.isArray(windows) || windows.length === 0) { process.stderr.write(`window-delta: no app.windows in ${platformFile} or src-tauri/tauri.conf.json\n`); process.exit(1); }
  const word = readWord();
  for (const w of windows) {
    if (typeof w.title !== "string" || !new RegExp(`\\b${WORD}\\b`).test(w.title)) { process.stderr.write(`window-delta: a window's title is ${JSON.stringify(w.title)}, not upstream's ${WORD}; review the window config\n`); process.exit(1); }
  }
  const out = { app: { windows: windows.map((w) => ({ ...w, title: w.title.replace(WORD_RE(), word) })) } };
  process.stdout.write(JSON.stringify(out, null, 2) + "\n");
}

function paths() {
  const set = new Set();
  for (const [rel] of readTsv("lines.tsv", 3)) set.add(rel);
  for (const [rel] of readTsv("strings.tsv", 2)) set.add(rel);
  process.stdout.write([...set].sort().join("\n") + "\n");
}

function roots() { process.stdout.write([...new Set([...SRC_ROOTS, ...WHOLE_TEXT_FIXED, ...scopeAll().wholeText.map((p) => p.split("/").slice(0, 2).join("/"))])].sort().join("\n") + "\n"); }
function scope() { process.stdout.write(scopeAll().all.join("\n") + "\n"); }

const cmd = process.argv[2];
const commands = { measure, hits: hitsCmd, apply, "apply-prefix": applyPrefix, scan, "bundle-residue": bundleResidue, "window-delta": windowDelta, paths, roots, scope };
if (!commands[cmd]) {
  process.stderr.write(`usage: transform.mjs ${Object.keys(commands).join("|")}\n`);
  process.exit(2);
}
commands[cmd]();
