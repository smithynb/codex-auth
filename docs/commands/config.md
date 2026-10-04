# `codex-auth config`

## Usage

```shell
codex-auth config live --interval <seconds>
codex-auth config time --format <12h|24h>
```

## Time format

Choose how clock times appear in account lists and the switch/remove pickers, including live views:

```shell
codex-auth config time --format 12h
codex-auth list --skip-api
```

- `12h` uses AM/PM, for example `2:05 PM`, `12:00 AM` at midnight, and `12:00 PM` at noon.
- `24h` uses a zero-padded hour, for example `14:05` or `00:00`. This is the default.
- Reset times and reset-credit expiry use the selected format and the machine's local timezone. Dates keep their existing format.
- Relative activity times such as `5m ago` and JSON timestamps are unchanged.
- In narrow terminals, reset cells can show only the percentage, and reset-credit cells can show only the count. Displayed 12-hour clock times retain AM/PM.

The setting persists for subsequent commands in the resolved Codex home: `CODEX_HOME`, or `~/.codex` by default. Restart an already-running live view after changing it.

To return to the default:

```shell
codex-auth config time --format 24h
```

Only `12h` and `24h` are accepted. A missing value, an unsupported format, an unknown flag, or an extra argument produces a usage error without saving the setting.

The setting is stored as top-level `"time_format": "12h"` or `"24h"` in `accounts/registry.json`. Missing or invalid stored values use `24h`. Changing other configuration or rebuilding accounts with `import --purge` preserves a valid time format.

## Live Refresh Config

`config live --interval <seconds>` sets the live TUI refresh interval.

- Allowed range: `5` to `3600`.
- Stored in `registry.json` as top-level `interval_seconds`.

## API Refresh

API-backed refresh is the default for supported foreground paths. Use per-command `--skip-api` to run a foreground command with local data only. Older `registry.json` files may contain an `api` object; current builds ignore it and omit it on the next registry save.

API behavior and endpoint details live in [docs/api.md](../api.md).
