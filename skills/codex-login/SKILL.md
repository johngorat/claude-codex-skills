---
name: codex-login
description: Check which auth channel the Codex reviewer CLI is on (ChatGPT subscription vs API key vs not logged in) and switch channels as automatedly as each direction allows. Use when the user asks what codex auth is active, wants to switch between subscription and API billing, hits a subscription quota stop and wants to finish a gate on the API, sets up a new machine, or when another skill refuses with "codex is not logged in". Subscription = rolling 5-hour quota window, no per-token bill; API key = pay-per-token, no window. The two are mutually exclusive — codex stores ONE auth mode at a time, so "hybrid" means explicit re-login at chosen moments, and this skill is that switch.
---

# Codex Login (auth-channel status & switch)

## Quick Start

`/codex-login` — report the active channel and offer switches.
`/codex-login api` / `/codex-login subscription` — go straight to that switch.

## Measured facts this skill relies on (do not re-derive)

- codex stores exactly ONE auth mode in `~/.codex/auth.json`; there is no
  per-invocation channel flag. Switching = re-login.
- `codex login status` prints to STDERR; wordings: "Logged in using an API
  key - sk-…" (masked by codex itself) / "Logged in using ChatGPT" /
  "Not logged in".
- An `OPENAI_API_KEY` env var is INERT at runtime (a real exec without
  auth.json fails 401) — it only feeds the explicit `--with-api-key` act.
  Its presence makes the API switch fully automatable; it never activates
  anything by itself.

## Hard rules

- The key is NEVER echoed, stored, or passed through this skill's files,
  the conversation, or a shell COMMAND LINE (a literal key in a command
  lands in shell history). Automation pipes it directly between the env var
  and codex (`printenv OPENAI_API_KEY | codex login --with-api-key`);
  without the env var the user runs, in their own terminal, either their
  secret manager's print command piped the same way or
  `read -rs K && printf '%s' "$K" | codex login --with-api-key` — stdin
  only, never an argument, never the chat.
- Never switch, and never `codex logout`, without the user explicitly
  choosing it THIS session. Reporting is free; switching is an act.
- Only status queries here: `codex login status` / `codex login
  --with-api-key` / handing off `codex login`. Never launch a review, never
  touch models.
- A switch while a debate run dir is open mid-gate will make its next round
  refuse (one channel per run, enforced by review-round.sh) — say so
  whenever a switch is performed.

## Workflow

### 1. Status

```bash
bash "<skill dir>/scripts/auth-status.sh"
```

One line: `auth-status: mode=<apikey|chatgpt|none|unknown> env_key=<yes|no>`.
`unknown` carries the verbatim status in `detail=` — report it as a new CLI
wording to record, not a failure.

### 2. Report (always, before any offer)

State: the active mode; what it means for review cost — subscription:
reviews draw from the plan's rolling 5-hour window, no per-token bill;
API key: pay-per-token — the AUTHORITATIVE number for any gate is
`cost-estimate.sh` output against the verified local price table, never a
remembered figure (non-authoritative 2026-08 example, for scale only: a
5-round top-tier debate gate ≈ $13 worst case, a second-tier check ≈
$0.40) — and whether an env key is present (= the API switch is one
command).

### 3. Switches (on explicit user choice)

Offer the choices through the host's selectable-option UI when one exists
(in Claude Code: the question tool with option buttons — measured user
feedback: prose lists read as information, buttons read as a choice). Keep
option labels in plain outcome terms (what it costs, what changes); file
names and script mechanics never appear in a question.

- **→ API key.** With `env_key=yes`, fully automated:
  `printenv OPENAI_API_KEY | codex login --with-api-key`, then re-run
  auth-status and confirm `mode=apikey`. Without the env var, the user runs
  a stdin-only variant themselves (suggest `! `-prefix in Claude Code):
  their secret manager's print command piped in, or
  `read -rs K && printf '%s' "$K" | codex login --with-api-key`. Never a
  literal key in a command line (shell history), never via chat.
  After a successful switch, run the cost-guard bootstrap (step 4).
- **→ Subscription.** Browser OAuth cannot be automated: hand off
  `codex login` (in Claude Code: `! codex login`), wait for the user to say
  it finished, then re-run auth-status and confirm `mode=chatgpt`.
- **Logout** only when the user explicitly asks: warn first when no env key
  is present — without a stored or env key, only the user can restore the
  API channel.

### 4. Cost-guard bootstrap (API channel only — SILENT, no questions)

The review skills estimate API-gate cost from two machine-local files:

```
${CLAUDE_SKILLS_PIN_DIR:-~/.claude/codex-skills-pins}/api-prices.txt
    <model-slug> <usd-per-1M-input> <usd-per-1M-output>   (one per line)
${CLAUDE_SKILLS_PIN_DIR:-~/.claude/codex-skills-pins}/cap-usd.txt
    <max USD per gate>                                    (optional hard cap)
```

**Prices are the skill's job, never a user question** (measured user
feedback: price-confirmation questions are confusing and the numbers are
findable). On switching to the API, or when `cost-estimate.sh` reports
NO-PRICE: look up the CURRENT prices yourself — the authoritative source is
OpenAI's official pricing page (platform.openai.com/docs/pricing, currently
redirecting to developers.openai.com/api/docs/pricing); cross-check one
secondary source if the page is unreachable — take the WORST-CASE tier when
several exist (e.g. long-context rates), write `api-prices.txt`, and simply
REPORT one line: which models, which rates, which source and date. Refresh
the same way whenever the file is older than ~a month or a gate's estimate
looks implausible.

**The cap is written only when the user themselves asks for a spending
limit** — never offered proactively, never part of a setup questionnaire.
Without a cap the per-gate protection still stands: the review skills show
the dollar estimate and require an explicit yes before every paid gate.
A written cap makes `cost-estimate.sh` refuse gates estimated above it; the
only bypass is the user editing the cap file.

### 5. Verify and close

Re-run auth-status; report the final mode. If a gate run dir was open
mid-switch, repeat the one-channel-per-run warning with the run dir path.
