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

This always installs the **latest release** (a stable URL — no version to bump).
It lands in `~/.local/bin`; verify the binary against the SHA256 in that release's
notes:

```bash
shasum -a 256 ~/.local/bin/khub
```

After that first install, keep the CLI current with **`khub upgrade`** — no need
to remember this command again.

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

## License

Released under the [MIT License](./LICENSE).
