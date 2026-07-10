# khub

A tiny command-line tool to **clone and keep a delivered `knowledge-hub` snapshot
current** — the read-only context repository your team was granted access to. It
sits beside your code repos and updates in place.

`khub` is interface only: it talks to the private distribution repo using **your
own `gh` login**. Its only dependencies are **git** and **gh** (the GitHub CLI).

## Install

```bash
curl -sfL https://github.com/blueblazedev/khub/releases/latest/download/install.sh | bash
```

This always installs the **latest release** (a stable URL — no version to bump)
into `~/.local/bin`. The installer **verifies the download against that release's
published `SHA256SUMS` before installing** — a mismatch or a missing checksum
fails closed and installs nothing, leaving any existing `khub` untouched.

After that first install, keep the CLI current with **`khub upgrade`** — no need
to remember this command again.

## Verifying your install

Two independent, deliberately honest guarantees:

- **Checksum (`SHA256SUMS`)** — published as a release asset and auto-checked by
  the installer. It is *same-channel*: it catches a corrupted, truncated, or
  partial download. On its own it does **not** prove a release wasn't tampered
  with at the source.
- **Build-provenance attestation** — each release's `khub` and `install.sh` are
  attested to this repo's `release.yml` workflow. With the GitHub CLI (`gh`
  ≥ 2.49) authenticated, confirm an artifact was built by that workflow:

  ```bash
  gh attestation verify ~/.local/bin/khub \
    --repo blueblazedev/khub \
    --signer-workflow blueblazedev/khub/.github/workflows/release.yml
  ```

  `--signer-workflow` matters: a bare `--repo` predicate matches *any* artifact
  this repo has ever built (including an older version), so it proves origin —
  **not** which version you hold. Version binding comes from the tag-pinned
  download URL and that tag's `SHA256SUMS`. The installer prints this command but
  never runs `gh` itself (`gh` is not an install dependency and needs its own
  login).

## Releases

Releases are cut by pushing a `v*` tag, which runs the `release.yml` workflow: it
re-runs the CI gates, then publishes `khub`, `install.sh`, and `SHA256SUMS` and
attests both executables. Tags whose commit is not on `main` are refused, and
only the owner can create `v*` tags. (`v0.1.0`/`v0.1.1` were cut manually and
carry no `SHA256SUMS` — install those only via the legacy pin below.)

## Onboard in 3 commands

From an unauthenticated machine that has only `git` and `gh`:

```bash
gh auth login          # 1. authenticate to GitHub (once per machine)
khub init              # 2. clone the hub as ./knowledge-hub
khub doctor            # 3. confirm everything is wired
```

`khub init [dir]` clones the hub as `knowledge-hub/` under `dir` (default: the
current directory), so it becomes a **sibling** of your code repos:

```text
your-projects/
├── knowledge-hub/     # ← the delivered context (pull-only)
├── service-repo/      # your code — reads ../knowledge-hub for context
└── other-service/     # your code — same
```

Point a code repo at the hub (writes a one-line pointer `CLAUDE.md`):

```bash
(cd knowledge-hub && scripts/bootstrap-sibling.sh <your-code-repo-git-url>)
```

## Commands

| Command | What it does |
| ------- | ------------ |
| `khub init [dir]` | Clone the hub as a sibling under `dir` (default: current dir). |
| `khub update` | Fast-forward the clone to the latest published snapshot. `--path DIR` to point at it; `--reset` to discard local changes (confirms first). |
| `khub doctor` | Diagnose auth, repo access, git-clone access, sibling layout, tampering, and snapshot freshness — each with a fix hint. |
| `khub version` | Print the CLI version and the clone's latest snapshot (SHA + date). |
| `khub track <enable\|disable\|status\|repair\|task>` | Opt-in, **local-only** session telemetry (OFF by default). `task <id>` books tokens to a ticket. See below. |
| `khub metrics [--by-task]` | Show the latest session's local report, or total output tokens per ticket across sessions. |

## Session telemetry (opt-in)

`khub track` is an **opt-in, local-first** way to measure your own ways of working
across Claude Code sessions. It is **OFF until you run `khub track enable`**, and
nothing ever leaves your machine.

- `khub track enable` — after printing exactly what it does, it backs up your
  `~/.claude/settings.json`, then **non-destructively** registers a small python3
  hook under `SessionStart` + `SessionEnd`. Only khub's own entries are added
  (identified by a marker, never by position), so any existing hooks are left
  byte-for-byte intact. Requires `python3`; if it is missing, enable changes
  nothing and tells you. Use `--project` to install into the current repo's
  `.claude/settings.json` instead of user scope.
- `khub track disable` — removes **only** khub's entries and the hook file; your
  settings backups are kept.
- `khub track status` — shows whether telemetry is enabled, whether the hook is
  registered, and whether the hook file still matches what was installed.
- `khub track repair` — reinstalls the hook and re-asserts registration if either
  drifted.

When a session ends, the hook reads that session's transcript and writes **process
metrics** — prompt/turn counts, tool usage, token totals, edits, error→retry loops,
subagents, session duration — to your local state dir. Run **`khub metrics`** to see
the latest session's report. The metrics file holds **counts only, no raw prompt or
response text**; a separate raw capture (also local) is kept briefly for a future
opt-in, redacted export. Automation sessions (`sdk-ts`) are ignored.

**Tokens per ticket.** To measure how many tokens a task/ticket cost, tag your work:
`khub track task <ticket-id>` books every following session's tokens to that ticket
(clear with `khub track task --clear`). With no tag set, tokens attribute to the git
branch each turn ran on. `khub metrics --by-task` then totals **output tokens per
ticket** across however many sessions the ticket took.

**Setup fingerprint.** Each session is also tagged with the *setup* it ran under —
harness (ClaudeKit vs vanilla), model, OS, skill/rule presence, a git-branch/repo id,
and an optional cohort (`khub track enable --cohort internal|external`) — so you can
compare ways of working. Identifying fields (repo id, skill names) are stored only as
**salted hashes** using a random per-install key that never leaves your machine.

**Troubleshooting.** The hook is fail-open (it never blocks a session), so it's silent
on errors. If capture isn't happening, turn on the opt-in debug log with `khub track
debug on`, reproduce a session, then run **`khub track doctor`** — a **redacted,
paste-ready** report (config, hook registration, integrity, store counts, and the last
debug lines; `$HOME`→`~`, no prompts/paths/skill names). Safe to share for support or
for an agent to self-diagnose. `khub track debug off` stops it.

A later release adds `khub export` (metrics-only by default) and `khub track purge`,
plus a full privacy doc.

## Pull-only policy

The hub clone is **delivered, not authored**. Your work lives in your own code
repos — the clone is **pulled, never pushed**. `khub update` refuses to run over
local commits and tells you how to recover, because a clone that has diverged can
no longer take clean updates.

## Access & revocation

Access is granted by the repository owner adding you as a collaborator. Removing
a collaborator **stops future pulls** for that person — but any snapshot already
cloned to their machine remains on disk. Treat delivery as a copy, not a lease.

If `khub update` ever reports that upstream history was **rewritten**, that is the
owner's documented response to a content incident: delete your clone and
`khub init` again. Do not try to reconcile it.

## Troubleshooting

Run `khub doctor` — it checks each prerequisite and prints the exact fix:

- **`gh not authenticated`** → `gh auth login`
- **`no access to …knowledge-hub-client`** → ask the owner to add you as a collaborator
- **`git cannot clone`** (API works but clone fails) → `gh auth setup-git`
- **`no knowledge-hub/ clone found`** → `khub init`
- **`points at ../knowledge-hub but no hub clone is beside it`** → `khub init ..`

## Installing a legacy release (advanced)

Releases before `v0.1.2` predate `SHA256SUMS`, so the installer cannot verify
them and will fail closed. To install one on purpose, set `KHUB_SKIP_VERIFY=1` —
this **disables integrity checking** and should be used only for a known legacy
pin:

```bash
curl -sfL https://github.com/blueblazedev/khub/releases/latest/download/install.sh \
  | KHUB_INSTALL_VERSION=v0.1.1 KHUB_SKIP_VERIFY=1 bash
```

Prefer `v0.1.2` or later, which are checksum-verified automatically.

## License

Released under the [MIT License](./LICENSE).
