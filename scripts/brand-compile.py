#!/usr/bin/env python3
"""brand-compile — compile the public engine into a complete branded tree.

    scripts/brand-compile.py <brand.conf> <out-dir> [--source DIR] [--hmac-key-file FILE]

Reads a per-client brand conf (key=value) and emits a fully branded copy of the
engine: CLI, env prefix, XDG paths, telemetry hook token, backup suffixes,
installer, workflows, docs, tests, and the content-repo identity (bot author,
snapshot subject, hub dirname). The branding TOOLCHAIN itself (this compiler,
the verifier, tests/branding/, the CI branding job) is excluded from the output,
so a branded tree ships no self-rebrand kit.

The token map is census-derived (see the plan's census report): line-anchored
value substitutions brand the composed repo-identity defaults in the CLI, then
ordered longest-first text rules sweep every file AND filename. Self-checks make
a silent miss impossible:

  * every census rule must still match its expected minimum (a vanished anchor
    means the engine drifted from the census -> compile FAILS, not silently skips)
  * a case-insensitive residue scan over output contents + filenames must find
    ZERO identity strings (khub / blueblazedev / knowledge-hub) -- any future
    mixed-case or unclassified shape fails here
  * the embedded telemetry helpers inside the branded CLI are rebuilt from the
    branded lib/ sources and must match exactly (embed-block consistency)
  * conf values may not themselves contain a reserved identity substring (a slug
    like "backhub" could never pass the zero-grep)

Deterministic by construction: no timestamps, sorted file order, pure stdlib,
no network. Two compiles from the same source/conf/key are byte-identical.

The emitted `.build-manifest` records source_rev as HMAC-SHA256(key, HEAD sha)
so no raw engine SHA ships, plus content hashes of the conf (conf_rev) and this
compiler (compiler_rev) so the vendor-side drift detector can pin all three.
Compile from a clean tag checkout for releases; a dirty working tree still
compiles (dev/test) but the manifest then names the rev the tree started from.
"""

import argparse
import hashlib
import hmac as hmac_mod
import os
import re
import subprocess
import sys

IDENTITY_RE = re.compile(r"khub|blueblazedev|knowledge-hub", re.IGNORECASE)
RESERVED = ("khub", "blueblazedev", "knowledge-hub")

# conf schema: field -> validating regex (full-match). ghec/default_branch are
# consumed by the release-channel rework (release.yml GHEC-gated attestation,
# client default branch); the compiler validates the full locked schema.
SCHEMA = {
    "slug": r"[a-z][a-z0-9-]*",
    "display_name": r"[^\n]+",
    "env_prefix": r"[A-Z][A-Z0-9_]*",
    "org": r"[A-Za-z0-9][A-Za-z0-9-]*",
    "cli_repo": r"[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+",
    "content_repo": r"[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+",
    "hub_dirname": r"[A-Za-z0-9._-]+",
    "bot_author": r"[^\n]+",
    "bot_subject_prefix": r"[^\n]+",
    "ghec": r"true|false",
    "default_branch": r"[A-Za-z0-9._/-]+",
    "license_text": r".+",
}

# paths (relative, exact or prefix/) that never enter a branded tree
EXCLUDE_EXACT = ("scripts/brand-compile.py", "scripts/brand-verify.sh")
EXCLUDE_PREFIX = ("tests/branding/",)
CI_JOB_BEGIN = "# >>> BEGIN branding job"
CI_JOB_END = "# <<< END branding job"

# embed-block layout mirrored from scripts/embed-telemetry.py (branded names)
EMBED_HELPERS = ("settings_merge.py", "capture_hook.py",
                 "aggregate_tasks.py", "export_redact.py")


def die(msg):
    sys.stderr.write("brand-compile: error: %s\n" % msg)
    sys.exit(1)


def sha256_hex(data):
    return hashlib.sha256(data).hexdigest()


# ---- conf ---------------------------------------------------------------------
def load_conf(path):
    conf = {}
    try:
        with open(path, encoding="utf-8") as fh:
            for n, raw in enumerate(fh, 1):
                line = raw.rstrip("\n")
                if not line.strip() or line.lstrip().startswith("#"):
                    continue
                if "=" not in line:
                    die("%s:%d: not key=value: %r" % (path, n, line))
                key, val = line.split("=", 1)
                if key in conf:
                    die("%s:%d: duplicate key %r" % (path, n, key))
                conf[key] = val
    except OSError as exc:
        die("cannot read conf: %s" % exc)

    unknown = sorted(set(conf) - set(SCHEMA))
    if unknown:
        die("unknown conf field(s): %s (the schema is closed — a field with no "
            "landing site is census drift)" % ", ".join(unknown))
    missing = sorted(set(SCHEMA) - set(conf))
    if missing:
        die("missing required conf field(s): %s" % ", ".join(missing))
    for key, pattern in SCHEMA.items():
        if not re.fullmatch(pattern, conf[key]):
            die("conf field %s=%r does not match %r" % (key, conf[key], pattern))
    for key, val in conf.items():
        low = val.lower()
        for word in RESERVED:
            if word in low:
                die("conf field %s contains the reserved identity string %r — "
                    "the zero-identity gate could never pass" % (key, word))
    for repo_field in ("cli_repo", "content_repo"):
        if not conf[repo_field].startswith(conf["org"] + "/"):
            die("%s=%r is not under org %r" % (repo_field, conf[repo_field], conf["org"]))
    conf["license_text"] = conf["license_text"].replace("\\n", "\n")
    return conf


# ---- source enumeration ---------------------------------------------------------
def list_source_files(source):
    """Relative paths, sorted. git ls-files when source is a git repo (tracked
    files only), else a filesystem walk skipping VCS/OS noise."""
    if os.path.isdir(os.path.join(source, ".git")):
        try:
            raw = subprocess.run(
                ["git", "-C", source, "ls-files", "-z"],
                capture_output=True, check=True).stdout
            return sorted(p.decode("utf-8") for p in raw.split(b"\0") if p)
        except (OSError, subprocess.CalledProcessError):
            pass
    files = []
    for root, dirs, names in os.walk(source):
        dirs[:] = sorted(d for d in dirs if d != ".git")
        for name in sorted(names):
            if name == ".DS_Store" or name.endswith(".log"):
                continue
            files.append(os.path.relpath(os.path.join(root, name), source))
    return sorted(files)


def source_head_rev(source):
    if os.path.isdir(os.path.join(source, ".git")):
        try:
            out = subprocess.run(["git", "-C", source, "rev-parse", "HEAD"],
                                 capture_output=True, check=True)
            return out.stdout.decode("ascii").strip()
        except (OSError, subprocess.CalledProcessError):
            pass
    return "no-git"


# ---- rule table ------------------------------------------------------------------
def line_subs(conf):
    """Anchored value substitutions on the CLI file. Each must hit EXACTLY once —
    zero means the census anchor vanished (engine drift), more means a duplicate."""
    cli_name = conf["cli_repo"].split("/", 1)[1]
    content_name = conf["content_repo"].split("/", 1)[1]
    return [
        (re.compile(r'^ORG="blueblazedev"', re.M),
         'ORG="%s"' % conf["org"], "ORG"),
        (re.compile(r'^KHUB_REPO="\$\{ORG\}/khub"', re.M),
         'KHUB_REPO="${ORG}/%s"' % cli_name, "KHUB_REPO"),
        (re.compile(r'^CLIENT_REPO="\$\{KHUB_CLIENT_REPO:-\$\{ORG\}/knowledge-hub-client\}"', re.M),
         'CLIENT_REPO="${KHUB_CLIENT_REPO:-${ORG}/%s}"' % content_name, "CLIENT_REPO"),
        (re.compile(r'^HUB_DIRNAME="knowledge-hub"', re.M),
         'HUB_DIRNAME="%s"' % conf["hub_dirname"], "HUB_DIRNAME"),
        (re.compile(r'^BOT_SUBJECT_PREFIX="publish: snapshot"', re.M),
         'BOT_SUBJECT_PREFIX="%s"' % conf["bot_subject_prefix"], "BOT_SUBJECT_PREFIX"),
        (re.compile(r'^BOT_AUTHOR="knowledge-hub-bot"', re.M),
         'BOT_AUTHOR="%s"' % conf["bot_author"], "BOT_AUTHOR"),
        (re.compile(r'^TRACK_DEFAULT_COHORT=""', re.M),
         'TRACK_DEFAULT_COHORT="external"', "TRACK_DEFAULT_COHORT"),
    ]


def text_rules(conf):
    """Ordered longest/most-specific-first plain replacements applied to every
    file and filename. min_count is the census floor across the WHOLE tree; 0
    marks a shape normally consumed upstream (line-subs / LICENSE replacement)
    kept as a safety net for future occurrences."""
    slug = conf["slug"]
    slug_ident = slug.replace("-", "_")
    prefix = conf["env_prefix"]
    return [
        ("blueblazedev/khub", conf["cli_repo"], 1),
        ("knowledge-hub-bot", conf["bot_author"], 0),
        ("knowledge-hub-client", conf["content_repo"].split("/", 1)[1], 1),
        ("knowledge-hub", conf["hub_dirname"], 1),
        ("khub-telemetry", "%s-telemetry" % slug, 1),
        ("_khub", "_%s" % slug_ident, 1),
        ("khub_", "%s_" % slug_ident, 1),
        ("KHUB_", "%s_" % prefix, 1),
        ("KHUB", prefix, 1),
        ("publish: snapshot", conf["bot_subject_prefix"], 0),
        ("khub", slug, 1),
        ("blueblazedev", conf["org"], 0),
    ]


def strip_ci_branding_job(text):
    """Drop the marker-fenced branding job from a workflow file (absent = no-op)."""
    out, skipping, found = [], False, False
    for line in text.splitlines(keepends=True):
        if CI_JOB_BEGIN in line:
            skipping, found = True, True
            continue
        if CI_JOB_END in line:
            skipping = False
            continue
        if not skipping:
            out.append(line)
    if skipping:
        die(".github/workflows/ci.yml: unterminated branding-job markers")
    return "".join(out), found


# ---- embed-block consistency ------------------------------------------------------
def build_embed_block(tree, slug_ident, prefix):
    begin = ("# >>> BEGIN embedded telemetry helpers "
             "(generated by scripts/embed-telemetry.py) >>>")
    end = "# <<< END embedded telemetry helpers <<<"
    delim = "%s_EMBEDDED_PY_EOF" % prefix
    out = [begin,
           "# DO NOT EDIT BY HAND — regenerate with: python3 scripts/embed-telemetry.py",
           "# Source of truth: lib/telemetry/*.py"]
    for fname in EMBED_HELPERS:
        src = tree["lib/telemetry/" + fname].decode("utf-8")
        out.append("_%s_py_%s() {" % (slug_ident, fname[:-3]))
        out.append("cat <<'%s'" % delim)
        out.append(src.rstrip("\n"))
        out.append(delim)
        out.append("}")
    out.append(end)
    return "\n".join(out), begin, end


def check_embed_consistency(tree, cli_path, slug_ident, prefix):
    cli = tree[cli_path].decode("utf-8")
    block, begin, end = build_embed_block(tree, slug_ident, prefix)
    try:
        start = cli.index(begin)
        stop = cli.index(end) + len(end)
    except ValueError:
        die("branded CLI lost its embedded-helpers markers")
    if cli[start:stop] != block:
        die("embedded telemetry helpers inside the branded CLI do not match a "
            "rebuild from the branded lib/ sources — transformation divergence")


# ---- compile ------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(
        prog="brand-compile.py",
        description="compile the engine into a branded tree (see module docstring)")
    ap.add_argument("conf")
    ap.add_argument("out_dir")
    ap.add_argument("--source", default=None,
                    help="engine checkout to compile (default: this script's repo)")
    ap.add_argument("--hmac-key-file", required=True,
                    help="vendor-private key file; source_rev ships only as "
                         "HMAC-SHA256(key, HEAD sha)")
    args = ap.parse_args()

    script_dir = os.path.dirname(os.path.abspath(__file__))
    source = os.path.abspath(args.source or os.path.dirname(script_dir))
    out_dir = os.path.abspath(args.out_dir)
    if not os.path.isdir(source):
        die("source is not a directory: %s" % source)
    if os.path.exists(out_dir) and os.listdir(out_dir):
        die("out-dir exists and is not empty: %s" % out_dir)
    if os.path.commonpath([source, out_dir]) == source:
        die("out-dir must live outside the source tree")
    try:
        with open(args.hmac_key_file, "rb") as fh:
            hmac_key = fh.read().strip()
    except OSError as exc:
        die("cannot read --hmac-key-file: %s" % exc)
    if not hmac_key:
        die("--hmac-key-file is empty")

    conf = load_conf(args.conf)
    slug = conf["slug"]
    slug_ident = slug.replace("-", "_")
    prefix = conf["env_prefix"]

    rel_files = [p for p in list_source_files(source)
                 if p not in EXCLUDE_EXACT
                 and not any(p.startswith(pre) for pre in EXCLUDE_PREFIX)]
    if "khub" not in rel_files:
        die("source has no 'khub' CLI at its root — wrong --source?")

    subs = line_subs(conf)
    rules = text_rules(conf)
    rule_hits = {pat: 0 for pat, _, _ in rules}
    tree = {}          # branded rel path -> bytes
    modes = {}         # branded rel path -> int mode

    for rel in rel_files:
        src_path = os.path.join(source, rel)
        if os.path.islink(src_path):
            die("symlinks are not supported: %s" % rel)
        with open(src_path, "rb") as fh:
            data = fh.read()

        if rel == "LICENSE":
            new_text = conf["license_text"]
            if not new_text.endswith("\n"):
                new_text += "\n"
            branded = new_text.encode("utf-8")
        else:
            try:
                text = data.decode("utf-8")
            except UnicodeDecodeError:
                if IDENTITY_RE.search(data.decode("latin-1")):
                    die("binary file carries identity strings and cannot be "
                        "branded: %s" % rel)
                branded, text = data, None
            if data == b"" or text is None:
                branded = data
            else:
                if rel == ".github/workflows/ci.yml":
                    text, _ = strip_ci_branding_job(text)
                if rel == "khub":
                    for pat, repl, name in subs:
                        text, n = pat.subn(lambda _m, r=repl: r, text)
                        if n != 1:
                            die("census drift: anchor %s matched %d times in the "
                                "CLI (expected exactly 1) — re-run the census and "
                                "update the map" % (name, n))
                for pat, repl, _minc in rules:
                    hits = text.count(pat)
                    if hits:
                        rule_hits[pat] += hits
                        text = text.replace(pat, repl)
                branded = text.encode("utf-8")

        out_rel = rel
        for pat, repl, _minc in rules:
            if pat in out_rel:
                rule_hits[pat] += out_rel.count(pat)
                out_rel = out_rel.replace(pat, repl)
        tree[out_rel] = branded
        modes[out_rel] = os.stat(src_path).st_mode & 0o777

    # ---- self-check 1: census floors (dead rule = drift) ----
    for pat, _repl, minc in rules:
        if rule_hits[pat] < minc:
            die("census drift: rule %r matched %d times (census floor %d) — the "
                "engine no longer carries this shape; re-run the census" %
                (pat, rule_hits[pat], minc))

    # ---- self-check 2: zero-identity residue over contents + filenames ----
    leaks = []
    for out_rel in sorted(tree):
        if IDENTITY_RE.search(out_rel):
            leaks.append("filename: %s" % out_rel)
        try:
            content = tree[out_rel].decode("utf-8")
        except UnicodeDecodeError:
            content = tree[out_rel].decode("latin-1")
        for n, line in enumerate(content.splitlines(), 1):
            if IDENTITY_RE.search(line):
                leaks.append("%s:%d: %s" % (out_rel, n, line.strip()[:100]))
    if leaks:
        die("identity residue survived compilation (unclassified census shape?):\n  "
            + "\n  ".join(leaks[:20]))

    # ---- self-check 3: embedded helpers consistent inside the branded CLI ----
    check_embed_consistency(tree, slug, slug_ident, prefix)

    # ---- manifest (deterministic; no raw engine SHA) ----
    head = source_head_rev(source)
    source_rev = hmac_mod.new(hmac_key, head.encode("ascii"),
                              hashlib.sha256).hexdigest()
    with open(args.conf, "rb") as fh:
        conf_rev = sha256_hex(fh.read())
    with open(os.path.abspath(__file__), "rb") as fh:
        compiler_rev = sha256_hex(fh.read())
    tree[".build-manifest"] = (
        "schema_version=1\n"
        "source_rev=%s\n"
        "conf_rev=%s\n"
        "compiler_rev=%s\n" % (source_rev, conf_rev, compiler_rev)).encode("ascii")
    modes[".build-manifest"] = 0o644

    # ---- write ----
    for out_rel in sorted(tree):
        dest = os.path.join(out_dir, out_rel)
        os.makedirs(os.path.dirname(dest) or out_dir, exist_ok=True)
        with open(dest, "wb") as fh:
            fh.write(tree[out_rel])
        os.chmod(dest, modes[out_rel])

    print("brand-compile: %s -> %s (%d files; brand %s; source_rev %s...)" %
          (source, out_dir, len(tree), slug, source_rev[:12]))


if __name__ == "__main__":
    main()
