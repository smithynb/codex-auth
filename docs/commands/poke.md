# `codex-auth poke` / `codex-auth tickle`

## Usage

```shell
codex-auth poke [--dry-run] [--model <name>] [--timeout <seconds>]
codex-auth tickle [options]
```

Both aliases behave identically. Top-level help pins personal commands above the
native command list, using magenta in terminals (plain text when redirected or
when `NO_COLOR` is set).

## Behavior

- Checks fresh API usage, then sends `ping!` sequentially only to stored ChatGPT accounts with an unstarted five-hour window.
- A window is eligible when usage is zero and its reset is exactly five hours away, compared to the minute. Accounts with active windows, stale usage, or failed usage refreshes print `(skipped)`.
- If the usage check fails entirely, no pings are sent.
- Default model: `gpt-6-luna`; reasoning effort: `low`.
- Each account receives an isolated, ephemeral, read-only Codex session.
- Your active account, daemon, and user configuration are not switched or loaded.
- API-key accounts are skipped (no ChatGPT subscription window applies).
- Failed accounts are reported and do not stop later accounts.
- There is no automatic model fallback or retry.

## Options

| Option | Description |
|--------|-------------|
| `--dry-run` | Refresh API usage and show eligible accounts without sending pings; the refresh may update saved authentication tokens |
| `--model <name>` | Override the model (no fallback if unavailable) |
| `--timeout <secs>` | Per-process timeout; integer 1–3600 (default 120) |
| `-h`, `--help` | Show help |

## Important Notes

- **Requests consume usage.** Each ping is a real model request. OpenAI controls whether a five-hour usage window starts, resets, or remains unchanged.
- **No tools or actions.** The developer instruction asks the model to reply `pong` only. Read-only sandboxing and ephemeral isolation are applied, but this is not an API-level guarantee that the model cannot attempt a tool call.
- **Auth refresh persistence.** If Codex refreshes authentication tokens during a session, refreshed credentials for the same identity are saved back to your account store. Credentials with a changed identity are rejected. A changed source snapshot detected before import is not overwritten. That check is not atomic against unrelated native writers; avoid switching, importing, or refreshing the same accounts concurrently.
- **Exclusive lock.** Only one poke/tickle runs at a time per `CODEX_HOME`. A stale lock after `SIGKILL` or power loss must be verified and removed manually from `~/.codex/accounts/.poke.lock`.
- **Cleanup.** Temporary credential directories are removed on normal completion, failure, timeout, `SIGINT`, and `SIGTERM`. `SIGKILL` and power loss cannot guarantee cleanup; check your system temp directory.

## Exit Codes

| Code | Meaning |
|------|---------|
| `0` | All eligible accounts succeeded, or dry-run/no-accounts |
| `1` | One or more accounts failed |
| `2` | Invalid command usage |
| `130` | Interrupted by SIGINT |
| `143` | Interrupted by SIGTERM |

## Installation

This is a personal command. It requires the checkout launcher to be linked:

```shell
cd /home/code/codex-auth
npm install --ignore-scripts --package-lock=false
zig build # Zig 0.16.0; rebuild after native source changes
ln -sfn /home/code/codex-auth/bin/codex-auth.js /root/.bun/bin/codex-auth
```

A global `npm install -g @loongphy/codex-auth` will replace the symlink. Repeat the `ln -sfn` command to restore personal dispatch.

## Fork Maintenance

This checkout uses `origin` (`git@github.com:smithynb/codex-auth.git`) for
personal changes and `upstream` (`https://github.com/Loongphy/codex-auth.git`)
for the original project. Personal changes live on `main` in the fork.
Commit or stash local work before merging updates:

```shell
cd /home/code/codex-auth
git fetch upstream
git merge upstream/main
node --test tests/personal_poke_test.mjs
python3 tests/personal_restart_test.py
python3 tests/personal_help_test.py
git push origin main
```

Merging keeps already-published personal commits intact; no force push is needed.
Run the isolated Zig tests as described in [docs/tests.md](../tests.md) when
upstream or personal native code changes, then run `zig build` to rebuild.
The launcher prefers `zig-out/bin/codex-auth` from the local build so native
customizations stay active. Without that build, it falls back to the upstream
npm platform binary (see [local reset-credit expiry](../local-reset-credit-expiry.md)).
