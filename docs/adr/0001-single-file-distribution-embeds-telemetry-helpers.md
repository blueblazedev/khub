# ADR-0001 — Single-file distribution embeds the telemetry helpers

**Status:** accepted (2026-07-11)

## Context

`khub` ships as one executable file, checksum-verified and provenance-attested per
release. The telemetry feature needs four python helpers (`settings_merge`,
`capture_hook`, `aggregate_tasks`, `export_redact`). A packaged install has no
`lib/` beside the binary, so the helpers must reach the user's machine somehow.

Alternatives considered:

1. **Ship `lib/` as extra release assets** the installer downloads — more CI
   plumbing (4 more assets + SHA256SUMS entries + attestation surface), a
   multi-file install, and a partial-download failure mode.
2. **Require a full checkout / `KHUB_LIB_DIR`** — telemetry silently unusable from
   the standard one-liner install (this was the shipped state briefly, and it
   failed exactly that way).
3. **Embed the helpers in the `khub` script** (chosen) — the sources stay canonical
   in `lib/telemetry/*.py`; `scripts/embed-telemetry.py` regenerates a heredoc
   block inside `khub`; CI (`scripts/check-embedded-telemetry.sh`) fails on drift;
   at runtime an on-disk `lib/` wins (dev), else the embedded copy is materialised
   to a temp dir (`tel_prepare`, parent-shell scope).

## Decision

Embed. One file remains the whole integrity story (one checksum, one attestation),
the one-liner install keeps working from any folder, and dev iteration still edits
real python files.

## Consequences

- `khub` carries a ~1,300-line generated block; the script is large but the
  distribution stays single-file.
- **Every additional shared python file costs a new embedded heredoc + import
  contract.** Cross-file refactors must clear that bar — this is why the
  store-walk dedupe and a shared hash module were declined, and why the
  salted-hash contract is instead kept as two byte-identical copies with pinned
  comments (`capture_hook._salted` / `export_redact._hash`).
- Future architecture reviews should not re-propose extracting shared python
  modules unless the single-file constraint itself is being reopened.
