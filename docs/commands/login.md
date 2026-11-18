# `codex-auth login`

## Usage

```shell
codex-auth login [--device-auth] [--no-restart-daemon]
```

## Behavior

- Runs `codex login`, or `codex login --device-auth` when requested.
- Reads and validates the new credentials from a temporary Codex home.
- Adds or updates the current account in `registry.json`.
- Stores a managed account snapshot under `accounts/<account file key>.auth.json`.
- Makes the logged-in account active and applies the credentials to a running daemon using the same rules as [switch](./switch.md#applying-a-switch-to-a-running-daemon). A daemon without reload support may restart and disconnect attached sessions. Use `--no-restart-daemon` to allow only an in-place reload.

## Notes

- `codex` must be available on `PATH`.
- Login-created accounts do not get an alias. Use `import <file> --alias <alias>` when an alias is needed.
- Invalid or incomplete auth files are rejected with the same auth validation rules used by `import`.
