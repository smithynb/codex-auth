# Upstream integration implementation plan

**Goal:** Integrate upstream main through 25b0016 while preserving personal commands,
email masking, configurable clocks, reset-credit expiry, and interactive recovery.

**Architecture:** Keep upstream's native daemon coordination as the sole recovery
implementation. The checkout launcher retains its confirmation prompt and invokes
a second native switch with `--restart-daemon` for the selected account. Keep the
upstream responsive layout and merge the fork's display and persistence behavior.

**Tech stack:** Zig 0.16.0, Node.js, Python pseudoterminal integration tests.

**Spec:** User authorization in this session: merge upstream upgrades, retain fork
features, and connect the existing confirmation prompt to upstream recovery.

## Constraints

- All CLI messages remain English.
- Read local Zig definitions before introducing or changing API usage.
- Run `zig build run -- list` against an isolated account home after Zig edits.
- Use offline fixtures; do not change real accounts or restart the real daemon.
- Preserve the legacy `reset_credits_expires_at` JSON and registry field.
- Import upstream's version metadata without creating or pushing release tags.

## Tasks

1. Merge upstream without committing. Resolve additive fields and test registration
   by retaining both sides. Reconcile reset-credit enrichment into one request and
   maintain cached expiry compatibility. Adapt fork clock formatting and highlighting
   to the upstream column identities and width allocation.
2. Change `bin/codex-auth.js` so confirmation calls the native binary for the exact
   selected account with `--restart-daemon`. Suppress the prompt for explicit recovery
   and help/JSON routes. Preserve the prompt after exiting live switching. Propagate recovery failures to the process exit code.
   Update `tests/personal_restart_test.py` with isolated fake native/daemon processes.
3. Extend actual-binary tests for unchanged-file recovery, decline/cancel, explicit
   flags, failure exit codes, clock preference, redaction, and narrow table output.
   Update command and fork docs with the combined behavior.
4. Run Zig formatting, full tests, required list smoke, all launcher/terminal suites,
   npm version/metadata checks, and supported target cross-compiles. Inspect the final
   diff and test preservation of each fork feature before completing the merge.

## Review focus

- A concurrent account change while the confirmation prompt is open must stop recovery
  without reverting the newer account selection.
- Grouped live rows must keep their masked shared identity.
- A recovery retry must work even when auth.json already contains the desired account.
- The launcher must avoid a second prompt after explicit recovery.
- Recovery must target the selected account by stable key, including `switch -`.
- Narrow 12-hour cells must retain AM/PM or fall back to a complete shorter value.
- Reset-credit cards must be freed/cloned correctly and legacy expiry must survive
  parse, save, JSON, and refresh paths.

## Validation commands

Run with isolated HOME and CODEX_HOME from a temporary working directory, using
`--build-file /home/code/codex-auth/build.zig` for Zig commands:

```sh
zig build test --summary all
zig build run -- list
zig build
node --test /home/code/codex-auth/tests/personal_poke_test.mjs
python3 /home/code/codex-auth/tests/personal_restart_test.py
python3 /home/code/codex-auth/tests/personal_help_test.py
python3 /home/code/codex-auth/tests/list_terminal_test.py
node /home/code/codex-auth/scripts/npm/check-versions.mjs v0.3.2-alpha.2
node /home/code/codex-auth/scripts/npm/check-release-metadata.mjs
```
