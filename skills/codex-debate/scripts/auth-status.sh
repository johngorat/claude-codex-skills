#!/usr/bin/env bash
# auth-status.sh — report which auth CHANNEL the codex CLI is on, machine-readably.
#
# stdout contract: EXACTLY one line
#   auth-status: mode=<apikey|chatgpt|none|unknown> env_key=<yes|no>[ detail="<verbatim>"]
# `detail` is present only for mode=unknown (the unrecognized or timed-out
# status, quotes and backslashes escaped). Exit 0 whenever the line was
# produced; exit 1 only when codex or python3 is missing (env-probe's remedy).
#
# Channel facts this reports are MEASURED (2026-08-28, plan AUTH-SCOREBOARD-
# WATCHDOG Stage 0):
#   - codex stores exactly ONE auth mode at a time in ~/.codex/auth.json;
#     switching channels is a re-login, never a flag.
#   - `codex login status` prints to STDERR; "Logged in using an API key"
#     on the api channel, "Logged in using ChatGPT" on the subscription,
#     "Not logged in" when logged out.
#   - An OPENAI_API_KEY env var is INERT at runtime (a real exec without
#     auth.json fails 401 "Missing bearer") — it only feeds the explicit
#     `codex login --with-api-key` act, so env_key=yes is a convenience
#     note for the switch offer, never an active channel.
#
# codex invocation policy: `codex login status` is a pure, BOUNDED (5s,
# enforced by subprocess timeout — a hung codex must never block a round
# launch; the process-contract harness caught exactly that) local status
# query — no thread, no model, no quota. Together with preflight's
# `codex --version` these are the ONLY sanctioned codex calls outside
# review-round.sh.
#
# Test seams: AUTH_STATUS_FIXTURE (a file whose CONTENT is taken as the
# status text — no codex invocation at all; a bash-script stub cannot be
# exec'd by a native-Windows python, so the seam redirects the SOURCE, same
# philosophy as CODEX_HOME/CLAUDE_SKILLS_PIN_DIR) and CODEX_BIN (alternate
# binary; the guard checks the EFFECTIVE one).
#
# The key itself is NEVER printed: the status line codex emits masks it, and
# only the mode classification passes through (a masked line can appear in
# detail= for unknown modes only — codex masks it there too).
set -u

if [ -z "${AUTH_STATUS_FIXTURE:-}" ]; then
  command -v "${CODEX_BIN:-codex}" >/dev/null 2>&1 || {
    echo "ERROR: codex not found — run env-probe.sh and follow its remedy" >&2
    exit 1
  }
fi
command -v python3 >/dev/null 2>&1 || {
  echo "ERROR: python3 not found — run env-probe.sh and follow its remedy" >&2
  exit 1
}

export PYTHONIOENCODING=utf-8
exec python3 - <<'AUTH_PY'
import os, re, subprocess, sys

fixture = os.environ.get("AUTH_STATUS_FIXTURE")
if fixture:
    try:
        with open(fixture, encoding="utf-8") as f:
            text = f.read()
    except (OSError, UnicodeError) as e:
        text = "<fixture unreadable: %s>" % e
else:
    try:
        out = subprocess.run([os.environ.get("CODEX_BIN") or "codex",
                              "login", "status"],
                             capture_output=True, stdin=subprocess.DEVNULL,
                             timeout=5)
        # both streams merged — the status line is on stderr (measured)
        text = (out.stdout + out.stderr).decode("utf-8", "replace")
    except subprocess.TimeoutExpired:
        text = "<status query timed out after 5s>"
    except OSError as e:
        text = "<status query failed: %s>" % e

# classify the WHOLE normalized status, ANCHORED (parsing law): only the
# measured wordings, as complete shapes, claim a channel. Substring matching
# would let a negated or quoting diagnostic claim one ("Not logged in using
# an API key" contains the api phrase) and pin the wrong BILLING identity;
# anything unmatched is unknown, verbatim, honestly.
norm = " ".join(text.split()).lower()
if re.fullmatch(r"logged in using an api key( - \S+)?", norm):
    mode = "apikey"
elif norm == "logged in using chatgpt":
    mode = "chatgpt"
elif norm == "not logged in":
    mode = "none"
else:
    mode = "unknown"
env_key = "yes" if os.environ.get("OPENAI_API_KEY") else "no"
line = "auth-status: mode=%s env_key=%s" % (mode, env_key)
if mode == "unknown":
    # VERBATIM detail on one line: every original character survives —
    # control characters are escaped, never collapsed (a diagnostic needs
    # the exact future wording, spacing included)
    esc = (text.replace("\\", "\\\\").replace("\"", "\\\"")
               .replace("\r", "\\r").replace("\n", "\\n").replace("\t", "\\t"))
    line += " detail=\"%s\"" % (esc or "<empty>")
print(line)
AUTH_PY
