# White-label: per-client branded builds

The engine can be compiled into a **complete branded tree** for delivery from a client's own GitHub
org: CLI name, env prefix, XDG paths, telemetry hook token, backup suffixes, installer, workflows,
docs, tests, and the content-repo identity (bot author, snapshot subject, hub dirname) are all
transformed. Nothing in the branded output greps back to this engine.

Everything in this document uses the **fictional** fixture brand `epsilon-hub` (org
`epsilon-labs`). Real client confs never enter this repository — they live in a private vendor
repo, and client names appear nowhere public.

## How it works

```
scripts/brand-compile.py <brand.conf> <out-dir> [--source DIR] --hmac-key-file <key>
scripts/brand-verify.sh  <out-dir>
```

`brand-compile.py` is a pure-stdlib, deterministic compiler: two runs over the same source, conf,
and key are byte-identical. The token map is **census-derived** (every `khub`-shaped string in the
engine is classified) and the compiler refuses to emit a tree when the engine drifts from that
census (a vanished anchor or an unclassified identity shape is a hard error, not a silent leak).
Its self-checks:

- **Zero identity residue** — a case-insensitive scan for engine identity strings over output
  contents AND filenames must find nothing. No allowlist: the engine's own fixtures are
  brand-neutral by construction.
- **Composed defaults land** — the repo-identity expressions (`ORG=…`, `…_REPO="${ORG}/…"`) are
  substituted by anchored, exactly-once rules and validated against the conf.
- **Identifier safety** — identifier contexts use `slug_ident` (`epsilon-hub` → `epsilon_hub`), so
  a hyphenated slug can never corrupt Python or shell names.
- **Embedded-helpers consistency** — the telemetry helpers embedded in the branded CLI are rebuilt
  from the branded `lib/` sources and must match exactly.
- **Toolchain exclusion** — the branded tree ships no self-rebrand kit: the compiler, the verifier,
  `tests/branding/`, and the CI branding job are stripped (asserted, not assumed).

`brand-verify.sh` then proves the tree **behaves**: parse checks, shellcheck, mode bits, the full
telemetry suite run in-tree, smoke tests for the verbs branding rewrites (`version`, `doctor`,
`init`, `upgrade --check` against a local `file://` fixture via the `{PREFIX}_API_BASE` override),
and the private-channel contract (below). Every gate is named on failure; the harness is tested to
fail loudly on planted leaks, corrupted identifiers, lost exec bits, and toolchain leakage.

## Brand conf

Plain `key=value`, `#` comments allowed. All fields required; unknown keys are rejected.

| Field | Example | Notes |
|-------|---------|-------|
| `slug` | `epsilon-hub` | CLI/asset name; lowercase, hyphens ok |
| `display_name` | `Epsilon Hub` | human-facing name |
| `env_prefix` | `EPSILON_HUB` | replaces `KHUB_` everywhere |
| `org` | `epsilon-labs` | client GitHub org |
| `cli_repo` | `epsilon-labs/epsilon-hub-cli` | hosts the branded CLI + releases |
| `content_repo` | `epsilon-labs/epsilon-hub-content` | the delivered hub content repo |
| `hub_dirname` | `epsilon-knowledge` | clone dirname `<slug> init` creates |
| `bot_author` | `epsilon-hub-bot` | snapshot publisher identity |
| `bot_subject_prefix` | `publish: epsilon snapshot` | snapshot commit subject |
| `ghec` | `false` | `true` → release workflow emits attestation |
| `default_branch` | `main` | client repo's default branch |
| `license_text` | `Copyright (c) …\n…` | replaces LICENSE wholesale; `\n` escapes |

Values that land inside the generated CLI's quoted strings reject every shell-active character
(`$`, backtick, `"`, `\`) — a conf value can never expand or execute at runtime. No value may
contain a reserved engine identity substring (the zero-residue gate could never pass). Both repos
must live under `org`, and derived values (`slug_ident`, `<slug>-telemetry`, `.<slug>-bak`,
`~/.config|.cache/<slug>`) come from the compiler, not the conf.

## Release channels

`RELEASE_CHANNEL` is a censused build default in both the CLI and `install.sh`:

- **`anonymous`** (this public repo): plain curl against `github.com` release URLs.
- **`gh`** (branded/private): every fetch goes through the authenticated GitHub CLI. Installs and
  `<slug> upgrade` use `gh release download`; latest-tag probes send the `gh` token and degrade to
  an anonymous probe without one. Engineers bootstrap from the private repo, e.g.:

```
gh release download --repo epsilon-labs/epsilon-hub-cli --pattern install.sh -O - | bash
```

**The fail-closed contract is identical on both channels** and is enforced behaviorally by
`brand-verify.sh`: the binary and `SHA256SUMS` are fetched from the SAME pinned tag; a checksum
mismatch, a release without `SHA256SUMS`, or checksums from another release each abort with
nothing installed. An installer tampered back to anonymous curl — or one that skips verification —
fails verification.

## Trust boundary (stated honestly)

- Releases are built and hosted **inside the client's own org**. Trust = the client's org security
  + `SHA256SUMS`, plus a build-provenance attestation **iff** the org is GitHub Enterprise Cloud
  (`ghec=true`; attestations on private repos are a GHEC feature).
- There is **no vendor countersignature** and no vendor signing key in client CI. A compromise of
  the client org is outside this threat model — the client owns that boundary.
- Every branded tree carries a `.build-manifest`: `source_rev` is an HMAC of the engine revision
  under a vendor-private key (no raw engine identifier ships), plus content hashes of the conf and
  compiler. The vendor can recompile at those three revisions and diff — a forensic drift check,
  not a release gate.
- Zero-identity grep is necessary, not sufficient: code similarity and release-date correlation
  remain honest residual fingerprints.

## Telemetry cohort in branded builds

Branded builds substitute `TRACK_DEFAULT_COHORT="external"`, so `<slug> track enable` provisions
the external cohort sidecar automatically and `<slug> export` is hard-blocked (exit-coded, with a
clear message) until a named DPA owner provisions the consent token. The public engine default is
empty — behavior here is unchanged.

## Onboarding preflight (per client)

Answered before any delivery PR:

1. Is the CLI repo private, and under which org? (`cli_repo`, `content_repo`)
2. Are GitHub Actions enabled for private repos in that org?
3. Is the org on GitHub Enterprise Cloud? (`ghec` — decides attestation)
4. What is the default branch name? (`default_branch` — the release workflow refuses tags that are
   not ancestors of it)
5. Does org SSO allow an outside collaborator or a fine-grained PAT scoped to single repos (CLI
   delivery PRs; content-snapshot publishing)?
6. Who cuts release tags? (The client does — the vendor never pushes to the default branch or tags.)
7. License text for this engagement (`license_text`).

## Boundaries

- The branded tree self-verifies with no engine access; client CI runs the same gates.
- Real confs, client rosters, release drivers, and the HMAC key live in private vendor tooling —
  never in this repository. The key under `tests/branding/fixtures/` is a labeled non-secret test
  fixture.
- The `epsilon-hub` brand in `tests/branding/` is fictional and exists only so CI can prove the
  compiler and verifier work.
