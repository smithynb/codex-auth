import path from 'node:path';
import fs from 'node:fs/promises';
import os from 'node:os';
import { spawn } from 'node:child_process';

export function parsePokeArgs(argv) {
  const options = { model: 'gpt-6-luna', timeoutSeconds: 120, dryRun: false, help: false };
  for (let index = 0; index < argv.length; index++) {
    const arg = argv[index];
    if (arg === '--help' || arg === '-h') options.help = true;
    else if (arg === '--dry-run') options.dryRun = true;
    else if (arg === '--model' || arg === '--timeout') {
      const value = argv[++index];
      if (!value || value.startsWith('-')) throw new Error(`Missing value for ${arg}.`);
      if (arg === '--model') options.model = value;
      else {
        if (!/^\d+$/.test(value) || Number(value) < 1 || Number(value) > 3600) {
          throw new Error('--timeout must be an integer between 1 and 3600 seconds.');
        }
        options.timeoutSeconds = Number(value);
      }
    } else throw new Error(`Unknown poke option: ${arg}`);
  }
  return options;
}

export function buildPokeInvocation(home, model, baseEnv) {
  const env = { ...baseEnv, CODEX_HOME: home, HOME: home, USERPROFILE: home };
  for (const key of ['OPENAI_API_KEY', 'CODEX_API_KEY', 'OPENAI_BASE_URL']) delete env[key];
  return {
    args: [
      'exec', '--ignore-user-config', '--ignore-rules', '--skip-git-repo-check',
      '--ephemeral', '--sandbox', 'read-only', '--model', model,
      '-c', 'model_provider="openai"',
      '-c', 'model_reasoning_effort="low"',
      '-c', 'cli_auth_credentials_store="file"',
      '-c', 'developer_instructions="This is a connectivity ping. Reply only pong. Do not use tools, execute commands, read or write files, or take any other action."',
      'ping!',
    ],
    env,
    cwd: path.join(home, 'work'),
  };
}

export const pokeHelp = `Usage: codex-auth poke [--dry-run] [--model <name>] [--timeout <seconds>]
       codex-auth tickle [options]

Send ping! sequentially only to ChatGPT accounts with an unstarted five-hour window.
Checks fresh API usage, requiring an unused reset exactly five hours away to the minute.
Other accounts print (skipped). Unavailable or stale usage is never pinged.
Default: gpt-6-luna, low reasoning, 120-second timeout per process.
API-key accounts are skipped. Your active account and daemon are not switched.
Requests consume usage; OpenAI controls whether a five-hour window starts.

  --dry-run          Check usage and show eligible accounts without calling Codex
  --model <name>     Override the model (no automatic fallback)
  --timeout <secs>   Per-process timeout, integer from 1 to 3600
  -h, --help         Show this help
`;

function maskEmail(value) {
  const at = value.lastIndexOf('@');
  if (at === -1) return value;
  const local = value.slice(0, at);
  const domain = value.slice(at + 1);
  if (!local || !domain) return '***@***';
  const quoted = local.startsWith('"') && local.endsWith('"') && local.length >= 2;
  const localValue = quoted ? local.slice(1, -1) : local;
  const quote = quoted ? '"' : '';
  const dot = domain.lastIndexOf('.');
  const literal = domain.startsWith('[') && domain.endsWith(']');
  const suffix = literal ? ']' : dot > 0 && dot < domain.length - 1 ? domain.slice(dot) : '';
  const domainPrefix = Array.from(dot === -1 ? domain : domain.slice(0, dot))[0] ?? '';
  return `${quote}${Array.from(localValue).slice(0, 3).join('')}***${quote}@${domainPrefix}***${suffix}`;
}

function authIdentity(bytes) {
  const auth = JSON.parse(bytes.toString());
  if (auth.auth_mode === 'apikey' || (typeof auth.OPENAI_API_KEY === 'string' && auth.OPENAI_API_KEY.trim())) {
    return null;
  }
  const tokens = auth.tokens;
  if (!tokens || typeof tokens.id_token !== 'string'
    || typeof tokens.access_token !== 'string' || !tokens.access_token) throw new Error('Invalid auth');
  const parts = tokens.id_token.split('.');
  if (parts.length !== 3) throw new Error('Invalid auth');
  const claims = JSON.parse(Buffer.from(parts[1], 'base64url').toString());
  const accountClaims = claims['https://api.openai.com/auth'];
  const user = accountClaims?.chatgpt_user_id ?? accountClaims?.user_id;
  const account = tokens.account_id || accountClaims?.chatgpt_account_id;
  if (typeof user !== 'string' || !user || typeof account !== 'string' || !account) throw new Error('Invalid auth');
  const label = typeof claims.email === 'string' ? maskEmail(claims.email) : user;
  return {
    key: `${user}::${account}`,
    label: `${label} (${account})`.replace(/[\x00-\x1f\x7f-\x9f]/g, '').slice(0, 160),
  };
}

export function hasUnstartedFiveHourWindow(account, nowSeconds) {
  const usage = account?.usage;
  if (usage?.source !== 'api' || usage.refresh?.status !== 'ok') return false;
  const windows = [usage.primary, usage.secondary];
  // Match the same five-hour window that the native list displays.
  const window = windows.find(value => value?.window_minutes === 300) ?? usage.primary;
  if (!window || (window.window_minutes != null && window.window_minutes !== 300)) return false;
  return window.used_percent === 0
    && Number.isSafeInteger(window.resets_at)
    && Math.floor(window.resets_at / 60) === Math.floor((nowSeconds + 18000) / 60);
}

function runChild(command, args, { timeoutSeconds, abortSignal, captureStdout = false, ...options }) {
  if (abortSignal?.aborted) return Promise.resolve({ status: null, reason: 'cancelled' });
  return new Promise((resolve) => {
    const child = spawn(command, args, {
      ...options, stdio: captureStdout ? ['ignore', 'pipe', 'ignore'] : 'ignore',
      detached: process.platform !== 'win32',
    });
    let reason;
    let output = '';
    let outputBytes = 0;
    if (captureStdout) {
      child.stdout.setEncoding('utf8');
      child.stdout.on('data', chunk => {
        outputBytes += Buffer.byteLength(chunk);
        if (outputBytes > 8 * 1024 * 1024) stop('output too large');
        else output += chunk;
      });
    }
    let escalation;
    let settled = false;
    function kill(signal) {
      if (!child.pid) return;
      try {
        if (process.platform === 'win32') child.kill(signal);
        else process.kill(-child.pid, signal);
      } catch { /* Process/group has already exited. */ }
    }
    function stop(why) {
      if (reason || settled) return;
      reason = why;
      kill('SIGTERM');
      escalation = setTimeout(() => kill('SIGKILL'), 500);
    }
    function aborted() { stop('cancelled'); }
    const timer = setTimeout(() => stop('timed out'), timeoutSeconds * 1000);
    function finish(status, detail) {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      clearTimeout(escalation);
      abortSignal?.removeEventListener('abort', aborted);
      // Also terminate descendants that outlived their process-group leader.
      kill('SIGKILL');
      resolve({ status: reason ? null : status, reason: reason || detail, stdout: output });
    }
    abortSignal?.addEventListener('abort', aborted, { once: true });
    if (abortSignal?.aborted) aborted();
    child.once('error', () => finish(null, 'could not start process'));
    child.once('close', (status, signal) => finish(status, signal ? `signal ${signal}` : `exit ${status}`));
  });
}

export async function runPoke({ binaryPath, argv, env = process.env, stdout = process.stdout, stderr = process.stderr, now = Date.now }) {
  let options;
  try { options = parsePokeArgs(argv); }
  catch (error) {
    stderr.write(`${error.message}\n${pokeHelp}`);
    return 2;
  }
  if (options.help) { stdout.write(pokeHelp); return 0; }

  const home = path.resolve(env.CODEX_HOME || path.join(os.homedir(), '.codex'));
  const accountsDir = path.join(home, 'accounts');
  const lock = path.join(accountsDir, '.poke.lock');
  let locked = false;
  let staging;
  let succeeded = 0;
  let failed = 0;
  let skipped = 0;
  const controller = new AbortController();
  let interrupted = 0;
  function interrupt(signal) {
    interrupted ||= signal === 'SIGINT' ? 130 : 143;
    controller.abort();
  }
  process.on('SIGINT', interrupt);
  process.on('SIGTERM', interrupt);
  const childOptions = { timeoutSeconds: options.timeoutSeconds, abortSignal: controller.signal };
  try {
    try { await fs.mkdir(lock, { mode: 0o700 }); locked = true; }
    catch (error) {
      if (error.code === 'ENOENT') { stdout.write('No stored accounts.\n'); return 0; }
      if (error.code === 'EEXIST') {
        stderr.write(`Another poke may be running. Check ${lock}; remove a stale lock only after verifying no poke is active.\n`);
        return 1;
      }
      throw error;
    }
    staging = await fs.mkdtemp(path.join(env.TMPDIR || os.tmpdir(), 'codex-auth-poke-'));
    await fs.chmod(staging, 0o700);
    const exportDir = path.join(staging, 'export');
    await fs.mkdir(exportDir, { mode: 0o700 });
    const nativeEnv = { ...env, CODEX_HOME: home };
    await fs.writeFile(path.join(lock, 'owner.json'), JSON.stringify({ pid: process.pid, started: new Date().toISOString() }), { mode: 0o600 });
    let eligibleAccounts;
    try {
      const listed = await runChild(binaryPath, ['list', '--api', '--json'], {
        ...childOptions, env: nativeEnv, captureStdout: true,
      });
      if (interrupted) return interrupted;
      if (listed.status !== 0) throw new Error('Listing failed');
      const listing = JSON.parse(listed.stdout);
      if (listing.schema_version !== 1 || listing.command !== 'list' || !Array.isArray(listing.accounts)) {
        throw new Error('Invalid listing');
      }
      // Evaluate the snapshot once; sequential pings must not age out idle accounts.
      const checkedAt = Math.floor(now() / 1000);
      eligibleAccounts = new Set(listing.accounts
        .filter(account => hasUnstartedFiveHourWindow(account, checkedAt))
        .map(account => account.account_key));
    } catch {
      stderr.write('Could not check five-hour resets; no pings were sent.\n');
      return interrupted || 1;
    }
    // Usage refresh can rotate credentials, so export only after the check.
    const exported = await runChild(binaryPath, ['export', exportDir], { ...childOptions, env: nativeEnv });
    if (interrupted) return interrupted;
    if (exported.status !== 0) { stderr.write('Could not export saved accounts; no pings were sent.\n'); return 1; }
    const files = (await fs.readdir(exportDir)).filter(name => name.endsWith('.auth.json')).sort();
    stdout.write(`${options.dryRun ? 'Dry run' : 'Poking'}: ${options.model}, low reasoning, message ping!\n`);
    for (const [index, name] of files.entries()) {
      if (interrupted) break;
      await fs.chmod(path.join(exportDir, name), 0o600);
      let bytes;
      let identity;
      try { bytes = await fs.readFile(path.join(exportDir, name)); identity = authIdentity(bytes); }
      catch { failed++; stderr.write(`Account ${index + 1}: FAILED (invalid saved auth).\n`); continue; }
      if (!identity) { skipped++; stdout.write(`Account ${index + 1}: SKIPPED (API-key account).\n`); continue; }
      if (!eligibleAccounts.has(identity.key)) {
        skipped++;
        stdout.write(`${identity.label}: (skipped)\n`);
        continue;
      }
      if (options.dryRun) { skipped++; stdout.write(`${identity.label}: would send ping!\n`); continue; }
      const accountHome = path.join(staging, `account-${index}`);
      await fs.mkdir(accountHome, { mode: 0o700 });
      await fs.mkdir(path.join(accountHome, 'work'), { mode: 0o700 });
      await fs.writeFile(path.join(accountHome, 'auth.json'), bytes, { mode: 0o600 });
      const invocation = buildPokeInvocation(accountHome, options.model, env);
      const result = await runChild('codex', invocation.args, { ...childOptions, env: invocation.env, cwd: invocation.cwd });
      let refreshFailure;
      try {
        const updated = await fs.readFile(path.join(accountHome, 'auth.json'));
        if (!updated.equals(bytes)) {
          if (authIdentity(updated)?.key !== identity.key) {
            refreshFailure = 'refreshed auth identity changed; not imported';
          } else if (!(await fs.readFile(path.join(accountsDir, name))).equals(bytes)) {
            refreshFailure = 'source credentials changed concurrently; not overwritten';
          } else {
            const refreshDir = path.join(staging, `refresh-${index}`);
            await fs.mkdir(refreshDir, { mode: 0o700 });
            await fs.writeFile(path.join(refreshDir, name), updated, { mode: 0o600 });
            // Directory import avoids the native single-file account-name API refresh.
            // On interruption, allow a bounded local-only import to retain rotated tokens.
            const imported = await runChild(binaryPath, ['import', refreshDir], {
              env: nativeEnv, timeoutSeconds: Math.min(options.timeoutSeconds, 5),
            });
            if (imported.status !== 0) refreshFailure = 'could not save refreshed auth; check account login';
          }
        }
      } catch { refreshFailure = 'could not validate or save refreshed auth'; }
      await fs.rm(accountHome, { recursive: true, force: true });
      if (result.status === 0 && !refreshFailure) { succeeded++; stdout.write(`${identity.label}: OK (ping sent).\n`); }
      else {
        failed++;
        const detail = refreshFailure || result.reason;
        stderr.write(`${identity.label}: FAILED (${detail}${result.status === 0 ? '; ping sent' : ''}); no model fallback.\n`);
      }
    }
    stdout.write(`Summary: ${succeeded} succeeded, ${failed} failed, ${skipped} skipped${options.dryRun ? ' (dry run)' : ''}.\n`);
    return interrupted || (failed ? 1 : 0);
  } catch {
    stderr.write('Poke failed while preparing or reading saved accounts. No credential details were printed.\n');
    return interrupted || 1;
  } finally {
    try {
      if (staging) await fs.rm(staging, { recursive: true, force: true });
    } finally {
      try {
        if (locked) await fs.rm(lock, { recursive: true, force: true });
      } finally {
        process.off('SIGINT', interrupt);
        process.off('SIGTERM', interrupt);
      }
    }
  }
}
