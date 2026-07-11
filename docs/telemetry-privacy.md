# khub telemetry — privacy

`khub track` is **opt-in** and **local-first**. It is OFF until you run
`khub track enable`, everything it records stays on your machine, and **nothing is
ever uploaded** — `khub export` only writes a local bundle for you to review and
send yourself, if you choose to.

## What it records (per session)

When a Claude Code session ends, a hook reads that session's transcript and writes
three things under `${XDG_STATE_HOME:-~/.local/state}/khub-telemetry/`:

| File | Contents | Leaves your machine? |
| ---- | -------- | -------------------- |
| `metrics/<id>.json` | **Counts only** — prompt/turn counts, tool-use counts by name, token totals, edit/rework counts, error→retry count, subagent counts, duration, and the setup fingerprint. No prompt or response text. | Only in an export (redacted) |
| `report/<id>.txt` | A human-rendered version of the metrics (same counts). | No |
| `fingerprint/<id>.json` | The **setup** the session ran under: harness (ClaudeKit/vanilla), model, OS, python, skill/rule presence, cohort. Identifying fields (repo id, skill names, rules) are stored **only as salted hashes** using a random per-install key. | Only in an export |
| `capture/<id>.jsonl` | **Raw** prompt + response text (truncated to 2000 chars/turn), kept for an opt-in redacted snippet export. | Only via `export --with-snippets`, redacted |

Raw `capture/*.jsonl` is **auto-purged after 14 days** (or a 50 MB cap). Automation
sessions (any `sdk-*` surface) and synthetic (non-LLM) turns are ignored.

## What an export contains

- `khub export` → **metrics only**, grep-proof by default: no raw prompt/response
  text, no `$HOME`, no login, no raw repo id, no secret. `mcp__…` tool names (which
  reveal your installed toolchain) are hashed.
- `khub export --with-snippets` → additionally includes prompt/response snippets, run
  through a secret scrubber (`$HOME`→`~`, login→`<user>`, and patterns for gh tokens,
  `sk-` keys, AWS keys, JWTs, PEM private keys, URL credentials, emails, and
  `SECRET=…` assignments). This is high-touch — review the bundle before sharing.

The bundle is written to `…/khub-telemetry/export/<timestamp>/` with a `manifest.json`
(session count, cohort, consent stamp). Inspect it; send it only if you're satisfied.

## Cohorts and external work

`khub track enable --cohort internal|external` labels the install. **External-cohort
export is hard-blocked in code**: `khub export` refuses to run unless a named data
owner has provisioned a DPA consent token at
`${XDG_CONFIG_HOME:-~/.config}/khub/telemetry-dpa-token`. This is deliberate — sharing
telemetry from a client machine contradicts khub's pull-only trust model and needs an
owner's written sign-off. For external, response bodies are also excluded from snippets.

## Inspect, disable, purge

- Inspect what's stored: `khub metrics` (points at every file), `khub track doctor`
  (a redacted status you can paste for support).
- See the debug log of what the hook did: `khub track debug on`, then
  `khub track doctor`.
- Stop capturing: `khub track disable` (removes only khub's hook entries + config;
  your settings backup is kept).
- Delete everything: `khub track purge` (removes the local data store, config, and
  khub's `settings.json` backups; confirms first).
