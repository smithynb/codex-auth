# Local reset-credit expiry display

The `RESET CREDITS` column includes the earliest expiration among available,
unexpired banked resets, for example `3 (exp 2026-10-04 14:52 PDT)`.
Dates use the machine's local timezone. This is the expiry of an existing banked
reset, not the weekly quota reset or the time a new credit will be granted.

API-backed refresh additionally reads
`GET https://chatgpt.com/backend-api/wham/rate-limit-reset-credits` using the same
OpenAI account credentials as usage refresh. It never redeems credits.
Unavailable, malformed, or failed expiry responses do not discard usage data;
the column falls back to the existing credit count. Local-only listings use the
cached expiry, if present and still in the future.

The optional `reset_credits_expires_at` field stores Unix seconds in the usage
snapshot and JSON output. It is backward-compatible with schema version 4.
Cloning and snapshot equality include the field so expiry changes are saved even
when the credit count remains unchanged.

This is a local source/native-binary customization; reinstalling or upgrading the
npm package can overwrite the installed native binary. The separate launcher
customization that prompts for a daemon restart after switching remains intact.
