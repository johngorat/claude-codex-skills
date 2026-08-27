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
import os, subprocess, sys

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

# classify on the WHOLE text, not line-wise (parsing law): the status output
# is short; unknown shapes are reported verbatim rather than guessed at.
# ONLY the measured wordings claim a channel — a generic "logged in"
# fallback would classify a future API wording (or an error sentence that
# merely contains the words) as the subscription channel and pin the wrong
# BILLING identity; anything unmatched is unknown, honestly.
low = text.lower()
if "logged in using an api key" in low:
    mode = "apikey"
elif "logged in using chatgpt" in low:
    mode = "chatgpt"
elif "not logged in" in low:
    mode = "none"
else:
    mode = "unknown"
env_key = "yes" if os.environ.get("OPENAI_API_KEY") else "no"
line = "auth-status: mode=%s env_key=%s" % (mode, env_key)
if mode == "unknown":
    compact = " ".join(text.split()) or "<empty>"
    line += " detail=\"%s\"" % compact.replace("\\", "\\\\").replace("\"", "\\\"")
print(line)
AUTH_PY
