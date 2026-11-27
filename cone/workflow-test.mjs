// Which jobs of .github/workflows/cone-desktop.yml run, for which event and
// ref (cone-buzz-infra Slice 48 merge 3b, ADR-492): above all, that a sign
// probe tag cone-desktop-v0.0.0-signprobe.N runs the job sign-probe and
// nothing that builds, releases or promotes, and that every such job refuses
// that ref by its own condition, not only through a skipped dependency. Also
// the workflow's standing rules: which jobs hold the environment cone-release
// and id-token: write, the old feed secret names absent, every action pinned
// by SHA, the Azure sign-in directly before the signing.
//
//   node cone/workflow-test.mjs              the checks on the workflow
//   node cone/workflow-test.mjs --mutations  then each planted change to a
//                                            copy of it must fail the named check
//
// No dependency: a reader for this file's own shape (jobs at two spaces,
// their keys at four, `if: >-` folded) and an evaluator of the GitHub
// expressions it uses — `==` and `!=` with GitHub's case-insensitive strings
// and its number coercion (so an input missing from a push event equals ''),
// `!`, `&&`, `||`, startsWith, contains, and the status functions with
// GitHub's implicit success() for a job whose condition names none. A
// matrix job is one job; its result is the matrix's.
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const WORKFLOW = join(dirname(fileURLToPath(import.meta.url)), '..', '.github', 'workflows', 'cone-desktop.yml');
const PROBE_PREFIX = 'refs/tags/cone-desktop-v0.0.0-signprobe.';
const PROBE = `${PROBE_PREFIX}1`;
const RELEASE = 'refs/tags/cone-desktop-v2.5.0';
const AZURE_LOGIN = 'azure/login@a641126d1b8aa4d1fa005f4f92df94a3a4c4c906';

// ---- the reader ----------------------------------------------------------
function parse(text) {
  const lines = text.split('\n');
  const wf = { text, permissions: {}, jobs: {} };
  let section = null, job = null, key = null, step = null;
  const indent = (l) => l.length - l.trimStart().length;
  const value = (v) => {
    v = v.replace(/\s+#.*$/, '').trim();
    if (/^'.*'$/.test(v)) return v.slice(1, -1).replace(/''/g, "'");
    if (/^".*"$/.test(v)) return v.slice(1, -1);
    return v;
  };
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (!line.trim() || line.trimStart().startsWith('#')) continue;
    const n = indent(line);
    if (n === 0) { section = line.replace(/:.*$/, ''); job = null; continue; }
    if (section === 'permissions' && n === 2) {
      const m = line.trim().match(/^([\w-]+):\s*(.*)$/);
      wf.permissions[m[1]] = value(m[2]);
      continue;
    }
    if (section !== 'jobs') continue;
    if (n === 2) {
      const name = line.trim().replace(/:$/, '');
      job = wf.jobs[name] = { name, if: null, needs: [], environment: null, permissions: {}, steps: [], lines: [] };
      key = null;
    }
    if (!job) continue;
    job.lines.push(line);
    if (n === 4) {
      const m = line.trim().match(/^([\w-]+):\s*(.*)$/);
      if (!m) continue;
      key = m[1];
      const v = m[2];
      if (key === 'if') {
        if (/^[>|]-?$/.test(v.trim())) {
          const parts = [];
          while (i + 1 < lines.length && (indent(lines[i + 1]) > 4 || !lines[i + 1].trim())) {
            i++;
            job.lines.push(lines[i]);
            if (lines[i].trim()) parts.push(lines[i].trim());
          }
          job.if = parts.join(' ');
        } else {
          job.if = value(v);
        }
      } else if (key === 'needs') {
        const nv = value(v);
        job.needs = nv.startsWith('[') ? nv.slice(1, -1).split(',').map((s) => s.trim()).filter(Boolean) : [nv];
      } else if (key === 'environment') {
        job.environment = value(v);
      }
      continue;
    }
    if (key === 'permissions' && n === 6) {
      const m = line.trim().match(/^([\w-]+):\s*(.*)$/);
      if (m) job.permissions[m[1]] = value(m[2]);
    }
    if (key === 'steps') {
      if (n === 6 && line.trim().startsWith('- ')) {
        step = {};
        job.steps.push(step);
        const m = line.trim().slice(2).match(/^([\w-]+):\s*(.*)$/);
        if (m) step[m[1]] = value(m[2]);
      } else if (n === 8 && step) {
        const m = line.trim().match(/^([\w-]+):\s*(.*)$/);
        if (m && !(m[1] in step)) step[m[1]] = value(m[2]);
      }
    }
  }
  return wf;
}

// ---- the evaluator -------------------------------------------------------
function tokenize(src) {
  const re = /\s*(?:('(?:[^']|'')*')|(==|!=|&&|\|\||[()!,])|([A-Za-z_][\w-]*(?:\.[A-Za-z_][\w-]*)*)|(\d+(?:\.\d+)?))/y;
  const out = [];
  let m;
  re.lastIndex = 0;
  while (re.lastIndex < src.length) {
    if (/^\s*$/.test(src.slice(re.lastIndex))) break;
    const at = re.lastIndex;
    m = re.exec(src);
    if (!m) throw new Error(`cannot read the expression at '${src.slice(at)}'`);
    if (m[1] !== undefined) out.push({ t: 'str', v: m[1].slice(1, -1).replace(/''/g, "'") });
    else if (m[2] !== undefined) out.push({ t: 'op', v: m[2] });
    else if (m[3] !== undefined) out.push({ t: 'id', v: m[3] });
    else out.push({ t: 'num', v: Number(m[4]) });
  }
  return out;
}

const toNumber = (v) => (v === null || v === undefined ? 0 : typeof v === 'boolean' ? Number(v) : typeof v === 'number' ? v : v.trim() === '' ? 0 : Number(v));
function equal(a, b) {
  a ??= null; b ??= null;
  if (typeof a === 'string' && typeof b === 'string') return a.toLowerCase() === b.toLowerCase();
  if (typeof a === typeof b && a !== null) return a === b;
  if (a === null && b === null) return true;
  const x = toNumber(a), y = toNumber(b);
  return !Number.isNaN(x) && !Number.isNaN(y) && x === y;
}
const truthy = (v) => !(v === null || v === undefined || v === false || v === 0 || v === '' || Number.isNaN(v));
const str = (v) => (v === null || v === undefined ? '' : String(v));

function evaluate(src, ctx) {
  const toks = tokenize(src);
  let p = 0;
  const peek = () => toks[p];
  const take = (v) => { const t = toks[p]; if (v !== undefined && (!t || t.v !== v)) throw new Error(`expected '${v}' in: ${src}`); p++; return t; };
  const or = () => { let l = and(); while (peek()?.v === '||') { take(); const r = and(); l = truthy(l) ? l : r; } return l; };
  const and = () => { let l = not(); while (peek()?.v === '&&') { take(); const r = not(); l = truthy(l) ? r : l; } return l; };
  const not = () => (peek()?.v === '!' && peek().t === 'op' ? (take(), !truthy(not())) : cmp());
  const cmp = () => {
    const l = primary();
    if (peek()?.v === '==' || peek()?.v === '!=') { const op = take().v; const r = primary(); return op === '==' ? equal(l, r) : !equal(l, r); }
    return l;
  };
  const primary = () => {
    const t = take();
    if (!t) throw new Error(`unexpected end of: ${src}`);
    if (t.t === 'str' || t.t === 'num') return t.v;
    if (t.v === '(') { const v = or(); take(')'); return v; }
    if (t.t === 'id') {
      if (peek()?.v === '(') {
        take('(');
        const args = [];
        while (peek()?.v !== ')') { args.push(or()); if (peek()?.v === ',') take(','); }
        take(')');
        return call(t.v, args, ctx);
      }
      if (t.v === 'true') return true;
      if (t.v === 'false') return false;
      if (t.v === 'null') return null;
      return t.v.split('.').reduce((o, k) => (o === null || o === undefined ? null : o[k] ?? null), ctx);
    }
    throw new Error(`unexpected '${t.v}' in: ${src}`);
  };
  const v = or();
  if (p !== toks.length) throw new Error(`trailing tokens in: ${src}`);
  return v;
}

function call(name, args, ctx) {
  switch (name) {
    case 'startsWith': return str(args[0]).toLowerCase().startsWith(str(args[1]).toLowerCase());
    case 'endsWith': return str(args[0]).toLowerCase().endsWith(str(args[1]).toLowerCase());
    case 'contains': return str(args[0]).toLowerCase().includes(str(args[1]).toLowerCase());
    case 'always': return true;
    case 'cancelled': return false;
    case 'success': return Object.values(ctx.needs).every((n) => n.result === 'success');
    case 'failure': return Object.values(ctx.needs).some((n) => n.result === 'failure');
    default: throw new Error(`unknown function ${name}()`);
  }
}

// One job's condition as GitHub reads it: none is success(); one without a
// status function is success() && (it).
function condition(job, ctx) {
  const src = job.if ?? 'success()';
  const full = /\b(always|success|failure|cancelled)\(/.test(src) ? src : `success() && (${src})`;
  return truthy(evaluate(full, ctx));
}

function context(wf, event, ref, inputs, needsOf) {
  return {
    github: { event_name: event, ref, ref_name: ref.replace(/^refs\/(heads|tags)\//, '') },
    inputs: event === 'workflow_dispatch' ? { resume_run_id: '', promote: '', windows_check: '', ...inputs } : {},
    needs: needsOf,
  };
}

// The jobs a run starts, each job's result being `results[job]` (default
// success) when it runs. Jobs in dependency order.
function run(wf, { event, ref, inputs = {}, results = {} }) {
  const done = {};
  const order = [];
  const visit = (name) => {
    if (done[name] !== undefined) return;
    const job = wf.jobs[name];
    if (!job) throw new Error(`no job ${name}`);
    for (const n of job.needs) visit(n);
    const needs = Object.fromEntries(job.needs.map((n) => [n, { result: done[n] }]));
    done[name] = condition(job, context(wf, event, ref, inputs, needs)) ? results[name] ?? 'success' : 'skipped';
    order.push(name);
  };
  Object.keys(wf.jobs).forEach(visit);
  return Object.keys(done).filter((n) => done[n] !== 'skipped').sort();
}

// ---- the checks ----------------------------------------------------------
const RELEASE_JOBS = ['shallow', 'build', 'build-windows', 'windows-resume', 'release', 'promote'];
const DISPATCHES = { resume: { resume_run_id: '123' }, promote: { promote: 'cone-desktop-v2.5.0' }, windows_check: { windows_check: '2.5.0-windows.9' } };

function checks(wf) {
  const results = [];
  const check = (name, fn) => {
    let ok, why = '';
    try { const r = fn(); ok = r === true; if (!ok) why = typeof r === 'string' ? r : JSON.stringify(r); } catch (e) { ok = false; why = e.message; }
    results.push({ name, ok, why });
  };
  const same = (got, want) => (JSON.stringify(got) === JSON.stringify([...want].sort()) ? true : `runs ${JSON.stringify(got)}, want ${JSON.stringify([...want].sort())}`);

  check('a sign probe tag runs sign-probe alone', () => same(run(wf, { event: 'push', ref: PROBE }), ['sign-probe']));
  check('a release tag runs shallow, both macOS builds, build-windows and release', () =>
    same(run(wf, { event: 'push', ref: RELEASE }), ['shallow', 'build', 'build-windows', 'release']));
  check('a release tag publishes nothing when build-windows fails', () =>
    same(run(wf, { event: 'push', ref: RELEASE, results: { 'build-windows': 'failure' } }), ['shallow', 'build', 'build-windows']));
  check('a release tag publishes nothing when a macOS build fails', () =>
    same(run(wf, { event: 'push', ref: RELEASE, results: { build: 'failure' } }), ['shallow', 'build', 'build-windows']));
  check('a resume runs build, windows-resume and release', () =>
    same(run(wf, { event: 'workflow_dispatch', ref: RELEASE, inputs: DISPATCHES.resume }), ['build', 'windows-resume', 'release']));
  check('a resume without the Windows installer publishes nothing', () =>
    same(run(wf, { event: 'workflow_dispatch', ref: RELEASE, inputs: DISPATCHES.resume, results: { 'windows-resume': 'failure' } }), ['build', 'windows-resume']));
  check('a promote dispatch runs promote alone, and never a release', () =>
    same(run(wf, { event: 'workflow_dispatch', ref: RELEASE, inputs: DISPATCHES.promote }), ['promote']));
  check('a windows_check dispatch runs windows-check alone', () =>
    same(run(wf, { event: 'workflow_dispatch', ref: 'refs/heads/cone-windows-signed', inputs: DISPATCHES.windows_check }), ['windows-check']));
  check('a pull request runs shallow alone', () => same(run(wf, { event: 'pull_request', ref: 'refs/pull/14/merge' }), ['shallow']));
  check('a push to cone runs shallow alone', () => same(run(wf, { event: 'push', ref: 'refs/heads/cone' }), ['shallow']));
  check('two inputs at once run dispatch-inputs alone', () =>
    same(run(wf, { event: 'workflow_dispatch', ref: RELEASE, inputs: { ...DISPATCHES.resume, ...DISPATCHES.promote } }), ['dispatch-inputs']));
  check('a resume or promote dispatched on a probe tag runs nothing', () => {
    const r = run(wf, { event: 'workflow_dispatch', ref: PROBE, inputs: DISPATCHES.resume });
    const p = run(wf, { event: 'workflow_dispatch', ref: PROBE, inputs: DISPATCHES.promote });
    return r.length + p.length === 0 || `resume runs ${r}, promote runs ${p}`;
  });
  // The guard each job carries itself: a dependency's skip must not be the
  // only thing between a probe tag and a build, a release or the feed.
  check('each job that builds, releases or promotes refuses a probe tag by its own condition', () => {
    const bad = [];
    for (const name of RELEASE_JOBS) {
      const job = wf.jobs[name];
      if (!job) { bad.push(`${name}: missing`); continue; }
      const green = Object.fromEntries(job.needs.map((n) => [n, { result: 'success' }]));
      for (const [event, inputs] of [['push', {}], ['workflow_dispatch', DISPATCHES.resume], ['workflow_dispatch', DISPATCHES.promote]]) {
        if (condition(job, context(wf, event, PROBE, inputs, green))) bad.push(`${name} on ${event} ${JSON.stringify(inputs)}`);
      }
    }
    return bad.length === 0 || `would run for a probe tag: ${bad.join('; ')}`;
  });
  check('the cone-release jobs are exactly build, build-windows, promote and sign-probe', () =>
    same(Object.values(wf.jobs).filter((j) => j.environment !== null).map((j) => `${j.name}:${j.environment}`).sort(),
      ['build:cone-release', 'build-windows:cone-release', 'promote:cone-release', 'sign-probe:cone-release']));
  check('id-token: write in build-windows and sign-probe alone, never workflow-wide', () => {
    const holders = Object.values(wf.jobs).filter((j) => j.permissions['id-token'] === 'write').map((j) => j.name).sort();
    if ('id-token' in wf.permissions) return `the workflow's permissions grant id-token: ${wf.permissions['id-token']}`;
    return same(holders, ['build-windows', 'sign-probe']);
  });
  check('windows-check and windows-resume read no secret', () => {
    const bad = ['windows-check', 'windows-resume'].filter((n) => wf.jobs[n].lines.some((l) => /secrets\./.test(l)));
    return bad.length === 0 || `${bad} read secrets`;
  });
  check('sign-probe reads the signing secrets and nothing else', () => {
    const names = [...new Set(wf.jobs['sign-probe'].lines.join('\n').match(/secrets\.[A-Z0-9_]+/g) ?? [])].sort();
    return same(names, ['secrets.AZURE_CLIENT_ID', 'secrets.AZURE_TENANT_ID', 'secrets.CONE_SIGN_ACCOUNT', 'secrets.CONE_SIGN_ENDPOINT', 'secrets.CONE_SIGN_PROFILE']);
  });
  check('release needs build, build-windows and windows-resume', () => same([...wf.jobs.release.needs].sort(), ['build', 'build-windows', 'windows-resume']));
  check('the old feed secret names appear nowhere (decision W9)', () => {
    const hits = wf.text.split('\n').map((l, i) => [i + 1, l]).filter(([, l]) => /CONE_R2_/.test(l));
    return hits.length === 0 || `lines ${hits.map(([n]) => n).join(', ')}`;
  });
  check('the feed credential is read from the CONE_FEED_R2_* names in promote', () =>
    same([...new Set(wf.jobs.promote.lines.join('\n').match(/secrets\.CONE_FEED_R2_[A-Z_]+/g) ?? [])].sort(),
      ['secrets.CONE_FEED_R2_ACCESS_KEY_ID', 'secrets.CONE_FEED_R2_ENDPOINT', 'secrets.CONE_FEED_R2_SECRET_ACCESS_KEY']));
  check('every action is pinned to a 40-character commit SHA', () => {
    const bad = Object.values(wf.jobs).flatMap((j) => j.steps.filter((s) => s.uses && !s.uses.startsWith('./') && !/@[0-9a-f]{40}$/.test(s.uses)).map((s) => `${j.name}: ${s.uses}`));
    return bad.length === 0 || bad.join('; ');
  });
  check('azure/login is v3.1.0 by its SHA wherever it runs', () => {
    const uses = Object.values(wf.jobs).flatMap((j) => j.steps.filter((s) => /^azure\/login@/.test(s.uses ?? '')).map((s) => `${j.name}:${s.uses}`)).sort();
    return same(uses, [`build-windows:${AZURE_LOGIN}`, `sign-probe:${AZURE_LOGIN}`]);
  });
  check('build-windows: the compile, then the Azure sign-in, the token and the signing bundle back to back', () => {
    const ids = wf.jobs['build-windows'].steps.map((s) => s.id ?? '');
    const at = (id) => ids.indexOf(id);
    const order = ['sign-inputs', 'compile', 'azure-login', 'token', 'bundle'].map(at);
    if (order.includes(-1)) return `step ids ${JSON.stringify(ids)}`;
    if (!order.every((v, i) => i === 0 || v > order[i - 1])) return `out of order: ${order}`;
    return (order[2] === order[1] + 1 && order[3] === order[2] + 1 && order[4] === order[3] + 1) || `steps between them: ${ids.slice(order[1], order[4] + 1)}`;
  });
  return results;
}

// ---- the planted changes -------------------------------------------------
// [mutation, exact text (once in the workflow), replacement, the check that must fail]
const MUTATIONS = [
  ['shallow runs for a probe tag',
    "if: github.event_name != 'workflow_dispatch' && !startsWith(github.ref, 'refs/tags/cone-desktop-v0.0.0-signprobe.')",
    "if: github.event_name != 'workflow_dispatch'",
    'a sign probe tag runs sign-probe alone'],
  ['sign-probe for every tag',
    "if: github.event_name == 'push' && startsWith(github.ref, 'refs/tags/cone-desktop-v0.0.0-signprobe.')",
    "if: github.event_name == 'push' && startsWith(github.ref, 'refs/tags/cone-desktop-v')",
    'a release tag runs shallow, both macOS builds, build-windows and release'],
  ['build without its own probe guard',
    "      !startsWith(github.ref, 'refs/tags/cone-desktop-v0.0.0-signprobe.') &&\n      ((github.event_name == 'push' && startsWith(github.ref, 'refs/tags/cone-desktop-v') && needs.shallow.result == 'success') ||",
    "      ((github.event_name == 'push' && startsWith(github.ref, 'refs/tags/cone-desktop-v') && needs.shallow.result == 'success') ||",
    'each job that builds, releases or promotes refuses a probe tag by its own condition'],
  ['build-windows without its own probe guard',
    "      github.event_name == 'push' && startsWith(github.ref, 'refs/tags/cone-desktop-v') &&\n      !startsWith(github.ref, 'refs/tags/cone-desktop-v0.0.0-signprobe.')\n    runs-on: windows-2025",
    "      github.event_name == 'push' && startsWith(github.ref, 'refs/tags/cone-desktop-v')\n    runs-on: windows-2025",
    'each job that builds, releases or promotes refuses a probe tag by its own condition'],
  ['windows-resume without its probe guard',
    "      startsWith(github.ref, 'refs/tags/cone-desktop-v') &&\n      !startsWith(github.ref, 'refs/tags/cone-desktop-v0.0.0-signprobe.')\n    runs-on: ubuntu-latest",
    "      startsWith(github.ref, 'refs/tags/cone-desktop-v')\n    runs-on: ubuntu-latest",
    'each job that builds, releases or promotes refuses a probe tag by its own condition'],
  ['release without its own probe guard',
    "      startsWith(github.ref, 'refs/tags/cone-desktop-v') &&\n      !startsWith(github.ref, 'refs/tags/cone-desktop-v0.0.0-signprobe.') &&\n      ((github.event_name == 'push'",
    "      startsWith(github.ref, 'refs/tags/cone-desktop-v') &&\n      ((github.event_name == 'push'",
    'each job that builds, releases or promotes refuses a probe tag by its own condition'],
  ['promote dispatchable on a probe tag',
    "inputs.windows_check == '' &&\n      !startsWith(github.ref, 'refs/tags/cone-desktop-v0.0.0-signprobe.')\n    runs-on: ubuntu-latest\n    environment: cone-release",
    "inputs.windows_check == ''\n    runs-on: ubuntu-latest\n    environment: cone-release",
    'a resume or promote dispatched on a probe tag runs nothing'],
  ['release without build-windows',
    'needs: [build, build-windows, windows-resume]', 'needs: [build, windows-resume]',
    'release needs build, build-windows and windows-resume'],
  ['release without the Windows result',
    "((github.event_name == 'push' && needs.build-windows.result == 'success') ||",
    "((github.event_name == 'push') ||",
    'a release tag publishes nothing when build-windows fails'],
  ['a resume never releases',
    "(github.event_name == 'workflow_dispatch' && needs.windows-resume.result == 'success'))",
    '(false))',
    'a resume runs build, windows-resume and release'],
  ['a resume releases without the installer',
    "(github.event_name == 'workflow_dispatch' && needs.windows-resume.result == 'success'))",
    "(github.event_name == 'workflow_dispatch'))",
    'a resume without the Windows installer publishes nothing'],
  ['id-token for the whole workflow',
    '\npermissions:\n  contents: read\n', '\npermissions:\n  contents: read\n  id-token: write\n',
    'id-token: write in build-windows and sign-probe alone, never workflow-wide'],
  ['id-token for windows-check',
    "    name: Windows check (unsigned)\n    if: github.event_name == 'workflow_dispatch' && inputs.windows_check != '' && inputs.resume_run_id == '' && inputs.promote == ''\n    runs-on: windows-2025\n    timeout-minutes: 150\n    permissions:\n      contents: read\n",
    "    name: Windows check (unsigned)\n    if: github.event_name == 'workflow_dispatch' && inputs.windows_check != '' && inputs.resume_run_id == '' && inputs.promote == ''\n    runs-on: windows-2025\n    timeout-minutes: 150\n    permissions:\n      contents: read\n      id-token: write\n",
    'id-token: write in build-windows and sign-probe alone, never workflow-wide'],
  ['windows-check in cone-release',
    '    name: Windows check (unsigned)\n', '    name: Windows check (unsigned)\n    environment: cone-release\n',
    'the cone-release jobs are exactly build, build-windows, promote and sign-probe'],
  ['the probe reads the updater key',
    "          CONE_SIGN_PROFILE: ${{ secrets.CONE_SIGN_PROFILE }}\n        run: cone/windows-sign.sh prepare \"$RUNNER_TEMP/cone-sign\"\n\n      # Two copies",
    "          CONE_SIGN_PROFILE: ${{ secrets.CONE_SIGN_PROFILE }}\n          TAURI_SIGNING_PRIVATE_KEY: ${{ secrets.TAURI_SIGNING_PRIVATE_KEY }}\n        run: cone/windows-sign.sh prepare \"$RUNNER_TEMP/cone-sign\"\n\n      # Two copies",
    'sign-probe reads the signing secrets and nothing else'],
  ['an old feed secret name',
    'secrets.CONE_FEED_R2_ENDPOINT', 'secrets.CONE_R2_ENDPOINT',
    'the old feed secret names appear nowhere (decision W9)'],
  ['azure/login by tag',
    `        id: azure-login\n        uses: ${AZURE_LOGIN} # v3.1.0`, '        id: azure-login\n        uses: azure/login@v3.1.0',
    'every action is pinned to a 40-character commit SHA'],
  ['a step between the sign-in and the signing',
    '      - name: The signing token, cached while the assertion is fresh\n        id: token\n',
    '      - name: Something slow\n        run: sleep 900\n      - name: The signing token, cached while the assertion is fresh\n        id: token\n',
    'build-windows: the compile, then the Azure sign-in, the token and the signing bundle back to back'],
  ['the sign-in before the compile',
    "      - name: Compile (cone/windows-build.sh compile --release)\n        id: compile\n        run: cone/windows-build.sh compile \"$VERSION\" --release\n\n",
    '',
    'build-windows: the compile, then the Azure sign-in, the token and the signing bundle back to back'],
];

// ---- main ----------------------------------------------------------------
const text = readFileSync(WORKFLOW, 'utf8');
let failed = 0;
console.log('cone-desktop.yml:');
const results = checks(parse(text));
for (const r of results) {
  console.log(`  ${r.ok ? 'ok  ' : 'FAIL'} ${r.name}${r.ok ? '' : `: ${r.why}`}`);
  if (!r.ok) failed++;
}
if (process.argv.includes('--mutations')) {
  console.log('mutations (each must fail the check named):');
  for (const [name, from, to, killer] of MUTATIONS) {
    const n = text.split(from).length - 1;
    if (n !== 1) { console.log(`  FAIL ${name}: its text is in the workflow ${n} times, not once — update the mutation`); failed++; continue; }
    if (!results.find((r) => r.name === killer)) { console.log(`  FAIL ${name}: no check named "${killer}"`); failed++; continue; }
    const fails = checks(parse(text.replace(from, to))).filter((r) => !r.ok).map((r) => r.name);
    if (fails.includes(killer)) console.log(`  ok   ${name}: killed by "${killer}"`);
    else { console.log(`  FAIL ${name}: survived "${killer}" (failed instead: ${fails.join('; ') || 'nothing'})`); failed++; }
  }
}
console.log(failed ? `workflow-test: ${failed} FAILED` : `workflow-test: ok (${results.length} checks${process.argv.includes('--mutations') ? `, ${MUTATIONS.length} mutations killed` : ''})`);
process.exit(failed ? 1 : 0);
