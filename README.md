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

### Specialized skill packs

Task-specific skills live in their own directories, separate from the generic
family, and install the same way (copy or symlink the folder into
`~/.claude/skills/`). Note: unlike the generic pack, `skills-ue-cocos` also
requires `python3` (3.8+, stdlib only) on PATH — its contract checks are
executable scripts, not prose:

| Pack | Skill | What it does |
|---|---|---|
| `skills-ue-cocos/` | [`ue-cocos-anchors-codex`](skills-ue-cocos/ue-cocos-anchors-codex/SKILL.md) | Anchor contract for UE→Cocos FX ports: machine-readable anchors binding every ported value to its UE dump source and Cocos runtime target; script-validated, script-compared — numeric render truth instead of visual verdicts. |

## Requirements

- [Claude Code](https://claude.com/claude-code) (CLI, desktop, or IDE extension)
- git, Node ≥ 22
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
(macOS/Windows/Linux), installs or upgrades the Codex CLI (≥ 0.145.0 via
`npm install -g @openai/codex@latest`), walks you through `codex login`,
discovers which models your plan actually has (Sol / Terra / Luna / 5.5 …),
live-verifies the top tier and lets you pick — if the flagship isn't available
it tells you and suggests requesting access from your workspace admin or
upgrading the subscription — then copies the skill and runs a smoke test.
You'll also be asked the install scope:

- **Project** — `<project>/.claude/skills/` — travels with that repo, teammates
  get it on clone if committed.
- **User** — `~/.claude/skills/` (Windows: `%USERPROFILE%\.claude\skills`) —
  available in every project on your machine.

### Option B — manual (2 minutes)

```bash
# 1. Codex CLI + login (once per machine)
npm install -g @openai/codex@latest
codex login                          # browser OAuth into your ChatGPT workspace

# 2. Copy the skill — pick ONE scope
cp -R skills/codex-debate  <your-project>/.claude/skills/   # project scope
cp -R skills/codex-debate  ~/.claude/skills/                # user scope

# 3. Restart your Claude Code session so the skill registers
```

## Model selection

By default the skill runs in **auto top-tier mode**: at the start of every
debate it resolves the highest-tier model the Codex CLI knows about (from
`~/.codex/models_cache.json`, sorted by priority). Today that's `gpt-5.6-sol`;
when 5.7/5.8 families ship, it upgrades itself — no skill edit needed.

Overrides, strongest first:

1. **Per-invocation** — `/codex-debate ... use terra` (or `luna`, `5.5`).
2. **Pin** — `echo gpt-5.6-terra > <skill dir>/model.txt` to lock a cheaper
   tier (saves quota; delete the file to return to auto). The installer writes
   this pin automatically when the flagship isn't accessible on your plan.
3. **Auto** — top catalog tier, as above.

If a model turns out inaccessible mid-loop, the skill steps down to the next
tier, finishes the review, and tells you — with the advice to request flagship
access or upgrade the subscription.

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
| "model requires a newer version of Codex" | `npm install -g @openai/codex@latest` |
| Rate-limit mid-debate | Plan quota (rolling 5-hour window) exhausted — the loop stops cleanly; retry later |
| Review of a big diff dies at the Bash timeout; background run killed in ~a minute | Run the round detached (`nohup … &`) and poll its events log — `codex-debate` step 3. A growing log means it's working: wait, don't retry |
| Round 2+ fails with `unexpected argument '--sandbox'` | `codex exec resume` takes options **before** the session id and has no `--sandbox` — use `-c sandbox_mode='"read-only"'` (see `codex-debate` step 5) |
