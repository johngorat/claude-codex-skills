# claude-codex-skills

Claude Code skills that wire **OpenAI Codex** in as an independent, adversarial
code reviewer. Two different frontier models check each other's work: Claude
writes the code, Codex — the **top-tier GPT model available on your plan**
(currently GPT-5.6 Sol; Terra/Luna/5.5 as fallbacks or by choice) — tries to
tear it apart, and the loop only ends when the reviewer signs off — or a human
breaks the tie.

Codex runs in a **read-only OS-enforced sandbox** on your ChatGPT subscription.
It cannot edit files, and its feedback is never applied blindly — Claude judges
every finding and pushes back on false positives with evidence.

## How the debate loop works

```
/codex-debate <task>
      │
      ▼
 1. Claude implements the task, runs local checks (compile/tests)
      │
      ▼
 2. git diff  ──►  codex exec (top-tier model, --sandbox read-only)
      │                    returns {verdict, findings[]} per JSON schema
      ▼
 3. APPROVED? ──yes──►  done: report rounds, fixes, rebuttals
      │no
      ▼
 4. Claude judges each finding:
      real → fix   ·   wrong → rebut with evidence (file:line, docs, tests)
      │
      ▼
 5. Fixes + rebuttals + updated diff ──► codex exec resume <same thread>
      └──── loop to 3  (max 5 rounds; an unchanged diff is never re-sent)
```

Deadlocks go to the human: after 5 rounds without consensus, or if Codex
repeats findings on an unchanged diff, the loop stops and presents both
positions.

## Skills

| Skill | What it does |
|---|---|
| [`codex-debate`](skills/codex-debate/SKILL.md) | Run a task, then debate the resulting diff with Codex — fix real findings, rebut false ones, loop until `APPROVED` + green local checks. Up to 5 rounds, flagship model. |
| [`codex-check`](skills/codex-check/SKILL.md) | One-shot advisory review of the diff — single round, second-tier model, no loop. Claude triages the findings; an unresolved major escalates to `/codex-debate`. |
| [`codex-plan`](skills/codex-plan/SKILL.md) | Turn a multi-stage task into a staged plan: review tier per stage, past reviewer findings baked in as hard requirements, tools to reuse named. Approve the plan, then it executes via the two skills above. |

### Which one to use

- `/codex-plan` — the entry point for anything multi-stage (a port, a migration,
  a new pipeline run). It decides where the other two are applied.
- `/codex-check` — routine changes that follow already-reviewed patterns, small
  diffs, config/docs edits, a quick pre-commit sanity pass.
- `/codex-debate` — infrastructure code, the first run of a new pipeline or
  template, validators and self-checks, changes whose bugs surface late and are
  expensive to find.
- Escalation: if a check leaves a `blocker`/`major` finding standing, run a full
  debate for that change. The cheap pass doubles as triage for the expensive one.

Each skill is a self-contained folder under `skills/` (SKILL.md + bundled
files). More Codex-related skills may land here later; they all install the
same way.

## Companion packs

Task-sharpened packs (e.g. an engine-to-engine porting pipeline) build ON TOP
of this generic family — their gates invoke `codex-debate`/`codex-check` and
their planning follows `codex-plan` — while the generic family stays pure and
never references any pack or its conventions. Packs live in their own
repositories and install the same way — copy or symlink each pack skill
folder into `~/.claude/skills/` alongside the generic three.

## Requirements

- [Claude Code](https://claude.com/claude-code) (CLI, desktop, or IDE extension)
- git, bash (macOS's 3.2 is fine; Windows: Git Bash), python3 ≥ 3.9
- Node ≥ 22 — only if you install codex through npm; the standalone codex
  package needs no Node
- A ChatGPT plan with Codex enabled (Free/Plus/Pro/Business/Edu/Enterprise).
  Company workspaces: an admin must have **"Allow members to use Codex Local"**
  switched on at chatgpt.com/admin/settings.
- No OpenAI API key needed — auth is the Codex CLI's own `codex login` (OAuth);
  reviews draw from the plan's rolling 5-hour quota, not a per-token bill.

## Installation

### Option A — let Claude install it (recommended)

Clone this repo, open Claude Code, and say:

```
follow INSTALL.md from <path to this repo>
```

Claude works through [INSTALL.md](INSTALL.md) adaptively: detects your OS
(macOS/Windows/Linux), installs or upgrades the Codex CLI (≥ 0.145.0; npm or
the standalone package — upgrades go through whichever channel installed it),
walks you through `codex login`, discovers which models your plan actually has
(Sol / Terra / Luna / 5.5 …), live-verifies the top tier and lets you pick —
if the flagship isn't available it tells you and suggests requesting access
from your workspace admin or upgrading the subscription — then runs the
bundled transactional installer (`install.sh`) and a smoke test. You'll also
be asked the install scope:

- **Project** — `<project>/.claude/skills/` — travels with that repo, teammates
  get it on clone if committed.
- **User** — `~/.claude/skills/` (Windows: `%USERPROFILE%\.claude\skills`) —
  available in every project on your machine.

### Option B — manual (2 minutes)

```bash
# 1. Codex CLI + login (once per machine)
npm install -g @openai/codex@latest  # or the standalone package (no Node needed)
codex login                          # browser OAuth into your ChatGPT workspace

# 2. Install the skills — transactional, records what it installed
bash install.sh                                            # user scope, all skills
bash install.sh --dest <project>/.claude/skills codex-debate   # project scope, one skill

# 3. Restart your Claude Code session so the skills register
```

`install.sh` picks copy or symlink by a real capability test at the
destination (copy is the primary mode — no privileges needed). Later:
`bash install.sh --verify` checks every recorded install against both its
record and the source; `bash install.sh --refresh` updates copy installs
transactionally (symlink installs update via `git pull` alone). The skills'
own once-per-session environment probe re-runs the same record check, so a
stale or corrupted install is caught before review quota is spent on it.

## Model selection

Each run resolves its reviewer through a strict ladder — strongest source
first:

1. **Per-invocation override** — `/codex-debate ... use terra` (or `luna`,
   `5.5`).
2. **Pin** — a `model.txt` in the skill dir locks a specific validated slug
   (e.g. a cheaper tier to save quota; delete the file to return to auto).
   Pins are only ever written with your explicit confirmation — nothing
   creates one silently.
3. **Auto** — the top validated catalog tier. Today that's `gpt-5.6-sol`;
   when 5.7/5.8 families ship, auto picks them up — no skill edit needed.

When nothing resolves (no override, no pin, no usable catalog), the skill
**refuses to run** and prints a guided bootstrap: validated candidates with
evidence, and how to confirm one as the pin. It never guesses a model and
never silently substitutes another one mid-review — a model-access or quota
failure is a hard stop with the remedy named, not a downgrade.

Reviewer freshness is checked separately:
`bash <skill dir>/scripts/preflight-model.sh` is silent when everything is
current and otherwise prints one line naming what is stale (catalog map, pin,
codex binary) and its exact remedy — it reports only, never updates anything.

## Usage

Implement something with review built in:

```
/codex-debate add a retry with exponential backoff to the upload client, max 3 attempts
```

Review-only for work that's already done:

```
/codex-debate review current changes, the task was: <what was done>
```

At the end you get a report: rounds used, findings fixed, findings rebutted and
why, or — on deadlock — both sides' positions so you can decide.

## Security posture

- Codex is always invoked with `--sandbox read-only`; the skill's hard rules
  explicitly forbid `--dangerously-bypass-approvals-and-sandbox`.
- No API keys are used or stored by these skills. OAuth tokens live in
  `~/.codex/auth.json`, managed entirely by the Codex CLI.
- Reviewer feedback is never auto-applied; Claude verifies each finding against
  the actual code first.
- Codex holds a veto over "done", not decision power: it cannot change code,
  and unresolved disagreements always land with the human.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `codex login status` looks empty | It prints to **stderr** — check `codex login status 2>&1` |
| `403 - Unauthorized. Contact your ChatGPT administrator` | Admin must enable "Allow members to use Codex Local" |
| `Error 400: No eligible ChatGPT workspaces found` | Same admin toggle — workspace not Codex-enabled |
| 401 `require_sso_login` | `codex logout && codex login` |
| "model requires a newer version of Codex" | upgrade through the channel that installed it: `npm install -g @openai/codex@latest`, or the standalone package's own updater |
| A skill refuses with "no model resolves" | `bash <installed skill dir>/scripts/resolve-model.sh --propose debate`; if it lists candidates, confirm one and write it to `<installed skill dir>/model.txt` — if it lists NONE, restore a naming source first (its printed remedy; usually reinstall/update codex) |
| Reviews feel stale (old model family) | `bash <installed skill dir>/scripts/preflight-model.sh` — silent means fresh; otherwise one line names what is stale and the fix |
| Installed skill behaves oddly / files differ | `bash install.sh --verify` names the drift and its remedy; `--refresh` fixes copy installs |
| Rate-limit mid-debate | Plan quota (rolling 5-hour window) exhausted — the loop stops cleanly; retry later |
| Review of a big diff dies at the Bash timeout; background run killed in ~a minute | Run the round detached (`nohup … &`) and poll its events log — `codex-debate` step 3. A growing log means it's working: wait, don't retry |
| Round 2+ fails with `unexpected argument '--sandbox'` | `codex exec resume` takes options **before** the session id and has no `--sandbox` — use `-c sandbox_mode='"read-only"'` (see `codex-debate` step 5) |
