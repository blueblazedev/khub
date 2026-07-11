# CONTEXT

Glossary for this repo's domain language. Terms only — no implementation detail.

- **Hub** — the delivered knowledge-hub snapshot clone that `khub` keeps current. Pull-only: delivered, never authored
  locally.
- **Snapshot** — a bot-published commit of hub content; the unit of delivery.
- **Telemetry** — the opt-in, local-first measurement of a Claude Code session. OFF until enabled; nothing leaves the
  machine except an explicit export.
- **Hook** — the python program registered in Claude Code's settings that observes a session's start and end.
  Fail-open: it may skip work, never break a session.
- **Conf** — the record that telemetry is enabled and how it was installed. Holds only values that are read back;
  single-value concerns live in sidecars, not here.
- **Sidecar** — a one-value-per-file setting beside the conf (active task, salt, cohort, debug marker, DPA token).
  Written and cleared independently of the conf.
- **Store** — the local per-session telemetry data (metrics, report, fingerprint, raw capture). Never leaves the
  machine by itself.
- **Rollup** — turning one finished session's transcript into its store records.
- **Fingerprint** — the setup a session ran under (harness, model, OS, cohort); identity fields appear only as salted
  hashes.
- **Salted hash** — HMAC of an identifier with the per-install salt. The only form
  identity may leave the machine in; a hash without the salt is not produced.
- **Active task** — the ticket label sessions book their tokens to. Survives disable/enable; only a purge removes it.
- **Cohort** — whose machine this install measures: `internal` or `external`. External unlocks nothing without a DPA
  token.
- **Export** — a redacted, review-before-send bundle built from the store. Metrics-only by default.
- **Purge** — scorched-earth removal of everything telemetry ever wrote, consent included.
