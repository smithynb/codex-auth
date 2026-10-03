import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { parsePokeArgs, buildPokeInvocation, hasUnstartedFiveHourWindow, runPoke } from '../bin/personal-poke.mjs';

test('defaults match the requested ping', () => {
  assert.deepEqual(parsePokeArgs([]), {
    model: 'gpt-6-luna', timeoutSeconds: 120, dryRun: false, help: false,
  });
});

test('rejects invalid options before touching accounts', () => {
  for (const argv of [
    ['--timeout', '0'], ['--timeout', '-1'], ['--timeout', '1.5'],
    ['--timeout', '3601'], ['--timeout'], ['--model'], ['--model', ''],
    ['--model', '--dry-run'], ['--unknown'], ['unexpected-selector'],
  ]) assert.throws(() => parsePokeArgs(argv));
  assert.deepEqual(parsePokeArgs(['--model', 'fixture-model', '--timeout', '5', '--dry-run']), {
    model: 'fixture-model', timeoutSeconds: 5, dryRun: true, help: false,
  });
  assert.equal(parsePokeArgs(['--help']).help, true);
});

test('request is isolated from ambient API keys and user configuration', () => {
  const invocation = buildPokeInvocation('/tmp/private-fixture', 'gpt-6-luna', {
    PATH: '/fixture/bin', OPENAI_API_KEY: 'fake-key',
    CODEX_API_KEY: 'fake-key', OPENAI_BASE_URL: 'https://invalid.example',
  });
  assert.equal(invocation.env.CODEX_HOME, '/tmp/private-fixture');
  assert.equal(invocation.env.HOME, '/tmp/private-fixture');
  assert.equal(invocation.env.OPENAI_API_KEY, undefined);
  assert.equal(invocation.env.CODEX_API_KEY, undefined);
  assert.equal(invocation.env.OPENAI_BASE_URL, undefined);
  assert.equal(invocation.args.at(-1), 'ping!');
  assert.ok(invocation.args.includes('model_reasoning_effort="low"'));
  assert.ok(invocation.args.includes('cli_auth_credentials_store="file"'));
  assert.ok(invocation.args.includes('--ignore-user-config'));
  assert.ok(invocation.args.includes('--ephemeral'));
  assert.ok(invocation.args.includes('read-only'));
  assert.equal(invocation.cwd, '/tmp/private-fixture/work');
});

test('five-hour eligibility is exact to the displayed minute, not rounded hours or percent', () => {
  const now = 1800000025;
  const idle = { used_percent: 0, window_minutes: 300, resets_at: now + 18000 };
  const account = primary => ({ usage: {
    source: 'api', refresh: { status: 'ok' }, primary,
  } });
  const minuteStart = Math.floor((now + 18000) / 60) * 60;
  for (const resets_at of [minuteStart, minuteStart + 59, now + 18000]) {
    assert.equal(hasUnstartedFiveHourWindow(account({ ...idle, resets_at }), now), true);
  }
  for (const resets_at of [minuteStart - 1, minuteStart + 60, now + 17900, now + 3600,
    now - 1, null, '1800018025']) {
    assert.equal(hasUnstartedFiveHourWindow(account({ ...idle, resets_at }), now), false);
  }
  for (const used_percent of [0.01, 1, 100, null]) {
    assert.equal(hasUnstartedFiveHourWindow(account({ ...idle, used_percent }), now), false);
  }
  assert.equal(hasUnstartedFiveHourWindow(account({ ...idle, window_minutes: 10080 }), now), false);
  assert.equal(hasUnstartedFiveHourWindow(account({ ...idle, window_minutes: null }), now), true);
  assert.equal(hasUnstartedFiveHourWindow(account(null), now), false);
  assert.equal(hasUnstartedFiveHourWindow(null, now), false);
  for (const usage of [
    { ...account(idle).usage, source: 'cache' },
    { ...account(idle).usage, refresh: { status: 'http_error' } },
    { ...account(idle).usage, refresh: null },
  ]) assert.equal(hasUnstartedFiveHourWindow({ usage }, now), false);
  assert.equal(hasUnstartedFiveHourWindow({ usage: {
    ...account({ ...idle, window_minutes: 10080 }).usage, secondary: idle,
  } }, now), true);
});

function fixtureAuth(id, changes = {}) {
  const claims = { email: `${id}@example.invalid`, 'https://api.openai.com/auth': {
    chatgpt_user_id: 'fixture-user', chatgpt_account_id: id,
  } };
  return { auth_mode: 'chatgpt', OPENAI_API_KEY: null, tokens: {
    id_token: `e30.${Buffer.from(JSON.stringify(claims)).toString('base64url')}.fixture`,
    access_token: `fixture-access-${id}`, refresh_token: `fixture-refresh-${id}`, account_id: id,
  }, ...changes };
}

async function makeHarness(t, options = {}) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'poke-test-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const home = path.join(root, 'home');
  const tools = path.join(root, 'tools');
  await fs.mkdir(path.join(home, 'accounts'), { recursive: true });
  await fs.mkdir(tools);
  const active = JSON.stringify(fixtureAuth('active'));
  const registry = JSON.stringify({ active_account_key: 'fixture-user::active', fixture: true });
  await fs.writeFile(path.join(home, 'auth.json'), active);
  await fs.writeFile(path.join(home, 'accounts', 'registry.json'), registry);
  const accounts = options.accounts ?? { a: fixtureAuth('a'), b: fixtureAuth('b') };
  for (const [name, auth] of Object.entries(accounts)) {
    await fs.writeFile(path.join(home, 'accounts', `${name}.auth.json`),
      typeof auth === 'string' ? auth : JSON.stringify(auth), { mode: 0o600 });
  }
  const config = path.join(root, 'config.json');
  const log = path.join(root, 'calls.jsonl');
  const nowSeconds = Math.floor(Date.now() / 1000);
  await fs.writeFile(config, JSON.stringify({ ...options, nowSeconds }));
  const preamble = `#!${process.execPath}
import fs from 'node:fs';
import path from 'node:path';
const config = JSON.parse(fs.readFileSync(process.env.POKE_FIXTURE_CONFIG));
const source = process.env.POKE_FIXTURE_HOME;
const log = (record) => fs.appendFileSync(process.env.POKE_FIXTURE_LOG, JSON.stringify(record) + '\\n');
`;
  const native = path.join(tools, 'native-auth');
  await fs.writeFile(native, preamble + `
const [command, destination] = process.argv.slice(2);
log({type: command, home: process.env.CODEX_HOME, destination});
if (command === 'list') {
  if (config.listFail) { console.error('fixture-refresh-a'); process.exit(9); }
  if (config.listInvalid) { console.log('invalid-json'); process.exit(0); }
  const now = config.nowSeconds;
  const accounts = config.accounts ?? { a: {}, b: {} };
  console.log(JSON.stringify({ schema_version: 1, command: 'list', accounts:
    Object.keys(accounts).map(id => ({ account_key: 'fixture-user::' + id, usage: {
      source: 'api', refresh: { requested: true, status: 'ok', method: 'api' },
      primary: { used_percent: 0, window_minutes: 300, resets_at: now + 18000 },
      ...config.usage?.[id],
    } })).filter(a => !config.missingUsage?.includes(a.account_key.split('::')[1]))
  }));
} else if (command === 'export') {
  if (config.exportFail) { console.error('fixture-refresh-a'); process.exit(9); }
  fs.mkdirSync(destination, {recursive: true});
  for (const name of fs.readdirSync(path.join(source, 'accounts')).filter(n => n.endsWith('.auth.json'))) {
    fs.copyFileSync(path.join(source, 'accounts', name), path.join(destination, name));
  }
} else if (command === 'import') {
  if (config.importFail) process.exit(9);
  for (const name of fs.readdirSync(destination)) fs.copyFileSync(path.join(destination, name), path.join(source, 'accounts', name));
} else if (['--help', '-h', 'help'].includes(command)) console.log('native help');
else if (command === '--version') console.log('fixture version');
else process.exit(8);
`, { mode: 0o755 });
  await fs.writeFile(path.join(tools, 'codex'), preamble + `
const home = process.env.CODEX_HOME;
const authPath = path.join(home, 'auth.json');
const auth = JSON.parse(fs.readFileSync(authPath));
const id = auth.tokens.account_id;
log({type: 'exec', id, args: process.argv.slice(2), home, cwd: process.cwd(),
  apiKey: process.env.OPENAI_API_KEY ?? null, codexKey: process.env.CODEX_API_KEY ?? null,
  baseUrl: process.env.OPENAI_BASE_URL ?? null,
  homeMode: fs.statSync(home).mode & 0o777, authMode: fs.statSync(authPath).mode & 0o777,
  projectFiles: fs.readdirSync(process.cwd()),
});
const behavior = config.behavior?.[id] ?? {};
if (behavior.refresh) {
  auth.tokens.access_token = 'fixture-renewed-access';
  auth.tokens.refresh_token = 'fixture-renewed-refresh';
  if (behavior.wrongIdentity) auth.tokens.account_id = 'different-account';
  fs.writeFileSync(authPath, JSON.stringify(auth));
}
if (behavior.changeSource) {
  const newer = {...auth, last_refresh: 'concurrent-newer-fixture'};
  fs.writeFileSync(path.join(source, 'accounts', id + '.auth.json'), JSON.stringify(newer));
}
console.error(auth.tokens.refresh_token);
if (behavior.delay) await new Promise(resolve => setTimeout(resolve, behavior.delay));
process.exit(behavior.fail ? 7 : 0);
`, { mode: 0o755 });
  const env = { ...process.env, CODEX_HOME: home, PATH: `${tools}${path.delimiter}${process.env.PATH}`,
    POKE_FIXTURE_CONFIG: config, POKE_FIXTURE_HOME: home, POKE_FIXTURE_LOG: log,
    OPENAI_API_KEY: 'fixture-api-key', CODEX_API_KEY: 'fixture-api-key', OPENAI_BASE_URL: 'https://invalid.example',
    TMPDIR: root, TMP: root, TEMP: root,
  };
  async function calls() {
    try { return (await fs.readFile(log, 'utf8')).trim().split('\n').filter(Boolean).map(JSON.parse); }
    catch (error) { if (error.code === 'ENOENT') return []; throw error; }
  }
  async function unchanged() {
    assert.equal(await fs.readFile(path.join(home, 'auth.json'), 'utf8'), active);
    assert.equal(await fs.readFile(path.join(home, 'accounts', 'registry.json'), 'utf8'), registry);
    await assert.rejects(fs.stat(path.join(home, 'accounts', '.poke.lock')), { code: 'ENOENT' });
    for (const call of await calls()) {
      if (call.type === 'exec') await assert.rejects(fs.stat(call.home), { code: 'ENOENT' });
      if (call.type === 'export') await assert.rejects(fs.stat(call.destination), { code: 'ENOENT' });
    }
  }
  async function run(argv = []) {
    let output = '';
    const stream = { write(value) { output += value; } };
    const status = await runPoke({ binaryPath: native, argv, env, stdout: stream, stderr: stream,
      now: () => nowSeconds * 1000 });
    assert.ok(!/fixture-(access|refresh|renewed|api-key)/.test(output), output);
    return { status, output, calls: await calls() };
  }
  async function launcher() {
    const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
    const bin = path.join(root, 'bin');
    await fs.mkdir(bin, { recursive: true });
    for (const name of ['codex-auth.js', 'personal-poke.mjs']) await fs.copyFile(path.join(repo, 'bin', name), path.join(bin, name));
    await fs.writeFile(path.join(root, 'package.json'), JSON.stringify({ type: 'module' }));
    const packageDir = path.join(root, 'node_modules', '@loongphy', `codex-auth-${process.platform}-${process.arch}`);
    await fs.mkdir(path.join(packageDir, 'bin'), { recursive: true });
    await fs.writeFile(path.join(packageDir, 'package.json'), '{}');
    await fs.copyFile(native, path.join(packageDir, 'bin', 'codex-auth'));
    return path.join(bin, 'codex-auth.js');
  }
  return { root, home, native, env, run, calls, unchanged, launcher };
}

test('visits accounts sequentially with isolated homes and preserves active state', async t => {
  const h = await makeHarness(t);
  const result = await h.run();
  assert.equal(result.status, 0, result.output);
  const requests = result.calls.filter(c => c.type === 'exec');
  assert.deepEqual(requests.map(c => c.id), ['a', 'b']);
  assert.notEqual(requests[0].home, requests[1].home);
  for (const request of requests) {
    assert.equal(request.args.at(-1), 'ping!');
    assert.ok(request.args.includes('gpt-6-luna'));
    assert.ok(request.args.includes('model_reasoning_effort="low"'));
    assert.equal(request.apiKey, null);
    assert.equal(request.codexKey, null);
    assert.equal(request.baseUrl, null);
    assert.equal(request.homeMode, 0o700);
    assert.equal(request.authMode, 0o600);
    assert.deepEqual(request.projectFiles, []);
  }
  await h.unchanged();
});

test('continues after failure, skips API keys, and reports corrupt saved auth', async t => {
  const h = await makeHarness(t, { accounts: {
    a: fixtureAuth('a'), b: fixtureAuth('b'),
    c: { auth_mode: 'apikey', OPENAI_API_KEY: 'fixture-api-key' }, d: 'broken-json',
  }, behavior: { a: { fail: true } } });
  const result = await h.run();
  assert.equal(result.status, 1);
  assert.deepEqual(result.calls.filter(c => c.type === 'exec').map(c => c.id), ['a', 'b']);
  assert.match(result.output, /1 succeeded, 2 failed, 1 skipped/);
  assert.match(result.output, /no model fallback/);
  await h.unchanged();
});

test('dry run has no Codex requests or refreshed-auth imports', async t => {
  const h = await makeHarness(t);
  const result = await h.run(['--dry-run']);
  assert.equal(result.status, 0);
  assert.deepEqual(result.calls.map(c => c.type), ['list', 'export']);
  assert.match(result.output, /would send ping!/);
  await h.unchanged();
});

test('only pings unstarted windows and prints (skipped) for active or unverified accounts', async t => {
  const h = await makeHarness(t, { accounts: {
    a: fixtureAuth('a'), b: fixtureAuth('b'), c: fixtureAuth('c'), d: fixtureAuth('d'),
    e: fixtureAuth('e'), f: fixtureAuth('f'),
  }, usage: {
    a: { primary: { used_percent: 0, window_minutes: 300, resets_at: Math.floor(Date.now() / 1000) + 17800 } },
    c: { source: 'cache', refresh: { requested: true, status: 'http_error', method: 'api' } },
    d: { primary: null },
    e: { primary: { used_percent: 1, window_minutes: 300, resets_at: Math.floor(Date.now() / 1000) + 18000 } },
  }, missingUsage: ['f'] });
  const result = await h.run();
  assert.equal(result.status, 0, result.output);
  assert.deepEqual(result.calls.filter(c => c.type === 'exec').map(c => c.id), ['b']);
  for (const id of ['a', 'c', 'd', 'e', 'f']) {
    assert.ok(result.output.includes(`${id}@example.invalid (${id}): (skipped)\n`), result.output);
  }
  assert.match(result.output, /1 succeeded, 0 failed, 5 skipped/);
  assert.deepEqual(result.calls[0], { type: 'list', home: h.home, destination: '--api' });
  await h.unchanged();
});

test('dry run also filters active windows without model requests', async t => {
  const h = await makeHarness(t, { usage: {
    a: { primary: { used_percent: 0, window_minutes: 300, resets_at: Math.floor(Date.now() / 1000) + 9000 } },
  } });
  const result = await h.run(['--dry-run']);
  assert.equal(result.status, 0, result.output);
  assert.deepEqual(result.calls.map(c => c.type), ['list', 'export']);
  assert.ok(result.output.includes('a@example.invalid (a): (skipped)\n'));
  assert.ok(!result.output.includes('a@example.invalid (a): would send ping!'));
  assert.ok(result.output.includes('b@example.invalid (b): would send ping!'));
  await h.unchanged();
});

test('failed or malformed usage listing stops before any model request', async t => {
  for (const options of [{ listFail: true }, { listInvalid: true }]) {
    const h = await makeHarness(t, options);
    const result = await h.run();
    assert.equal(result.status, 1, result.output);
    assert.deepEqual(result.calls.map(c => c.type), ['list']);
    assert.match(result.output, /Could not check five-hour resets; no pings were sent/);
    await h.unchanged();
  }
});

test('export failure stops before any model request and hides child diagnostics', async t => {
  const h = await makeHarness(t, { exportFail: true });
  const result = await h.run();
  assert.equal(result.status, 1);
  assert.deepEqual(result.calls.map(c => c.type), ['list', 'export']);
  await h.unchanged();
});

test('persists refreshed same-identity credentials even after a failed request', async t => {
  const h = await makeHarness(t, { behavior: { a: { refresh: true, fail: true } } });
  const result = await h.run();
  assert.equal(result.status, 1);
  const refreshed = JSON.parse(await fs.readFile(path.join(h.home, 'accounts', 'a.auth.json'), 'utf8'));
  assert.equal(refreshed.tokens.refresh_token, 'fixture-renewed-refresh');
  assert.equal(result.calls.filter(c => c.type === 'import').length, 1);
  await h.unchanged();
});

test('rejects a changed auth identity rather than importing it', async t => {
  const h = await makeHarness(t, { behavior: { a: { refresh: true, wrongIdentity: true } } });
  const result = await h.run();
  assert.equal(result.status, 1);
  assert.equal(result.calls.filter(c => c.type === 'import').length, 0);
  const auth = JSON.parse(await fs.readFile(path.join(h.home, 'accounts', 'a.auth.json'), 'utf8'));
  assert.equal(auth.tokens.account_id, 'a');
  await h.unchanged();
});

test('refuses to overwrite credentials changed concurrently in the source', async t => {
  const h = await makeHarness(t, { behavior: { a: { refresh: true, changeSource: true } } });
  const result = await h.run();
  assert.equal(result.status, 1);
  assert.equal(result.calls.filter(c => c.type === 'import').length, 0);
  const auth = JSON.parse(await fs.readFile(path.join(h.home, 'accounts', 'a.auth.json'), 'utf8'));
  assert.equal(auth.last_refresh, 'concurrent-newer-fixture');
  await h.unchanged();
});

test('bounds a hung account and still attempts the next account', async t => {
  const h = await makeHarness(t, { behavior: { a: { delay: 2500 } } });
  const result = await h.run(['--timeout', '1']);
  assert.equal(result.status, 1);
  assert.match(result.output, /timed out/);
  assert.deepEqual(result.calls.filter(c => c.type === 'exec').map(c => c.id), ['a', 'b']);
  await h.unchanged();
});

test('rejects a second overlapping poke', async t => {
  const h = await makeHarness(t);
  await fs.mkdir(path.join(h.home, 'accounts', '.poke.lock'));
  const result = await h.run();
  assert.equal(result.status, 1);
  assert.match(result.output, /Another poke/);
});

test('both aliases dispatch to the same poke and never trigger daemon restart', async t => {
  const h = await makeHarness(t);
  const launcher = await h.launcher();
  for (const alias of ['poke', 'tickle']) {
    // Clean call log between aliases.
    const log = h.env.POKE_FIXTURE_LOG;
    try { await fs.unlink(log); } catch {}
    const child = spawn(process.execPath, [launcher, alias, '--dry-run'], { env: h.env });
    let output = '';
    child.stdout?.on('data', d => output += d);
    child.stderr?.on('data', d => output += d);
    const status = await new Promise(resolve => child.once('close', resolve));
    assert.equal(status, 0, `${alias} exit: ${output}`);
    assert.match(output, /would send ping!/);
    assert.ok(!/\\[Y\\/n\\]/.test(output), `${alias} prompted daemon restart`);
  }
});

test('prefers a locally built native binary over the npm platform binary', async t => {
  const h = await makeHarness(t);
  const launcher = await h.launcher();
  const binDir = path.join(h.root, 'zig-out', 'bin');
  await fs.mkdir(binDir, { recursive: true });
  await fs.writeFile(path.join(binDir, process.platform === 'win32' ? 'codex-auth.exe' : 'codex-auth'),
    `#!${process.execPath}\nconsole.log('local-native-fixture');\n`, { mode: 0o755 });
  const child = spawn(process.execPath, [launcher, '--version'], { env: h.env });
  let output = '';
  child.stdout.on('data', data => output += data);
  child.stderr.on('data', data => output += data);
  const status = await new Promise(resolve => child.once('close', resolve));
  assert.equal(status, 0, output);
  assert.equal(output.trim(), 'local-native-fixture');
});
