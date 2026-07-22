# Install runbook — Codex reviewer skills for Claude Code

> **To the human:** clone this repo (or download it as a zip from GitHub), open
> Claude Code anywhere, and say: `follow INSTALL.md from <path to this repo>`.
>
> **To Claude executing this runbook:** work through the steps in order,
> autonomously. Verify every step's outcome before moving on; adapt commands to
> the host OS. The only steps that need the human are the scope choice (Step 1),
> the interactive `codex login`, and any system-level package install (ask
> first). Never use `--dangerously-bypass-approvals-and-sandbox` in any codex
> invocation.

## What you are setting up

Skills from this repo's `skills/` folder — currently `codex-debate`: Claude
implements a task, sends the diff to OpenAI Codex (top-tier model available on
the plan, read-only sandbox) for adversarial review, debates the findings
(fixes real ones, rebuts false positives with evidence), and loops — resuming
the same Codex thread — until Codex returns `APPROVED` and local checks are
green. Max 5 rounds, anti-loop guards included.

Codex runs on a ChatGPT subscription (OAuth login), not a paid API key — review
tokens draw from the plan's rolling 5-hour quota window, not a per-token bill.

## Step 1 — Ask the human: install scope

Ask which scope they want (and which skills, if more than one exists in
`skills/`):

- **Project scope** — `<project>/.claude/skills/` — the skill exists only in
  that project and travels with its repo (teammates get it on clone if
  committed).
- **User scope** — `~/.claude/skills/` (Windows: `%USERPROFILE%\.claude\skills`)
  — available in every project on this machine, personal to this user.

## Step 2 — Preflight

1. Detect OS (macOS / Windows / Linux) and shell. On Windows, Claude Code runs
   commands through Git Bash — `/tmp` exists there and maps to the user temp
   dir, so the skills' `/tmp/...` paths work as-is. If `/tmp` turns out not
   writable, substitute a writable temp dir in the copied SKILL.md.
2. For **project scope**: confirm the target project is a git repository
   (`git rev-parse --git-dir`). Codex refuses non-git dirs and the skill depends
   on `git diff`. For **user scope**: the skill still only *runs* inside git
   projects; no check needed at install time.
3. Confirm `node`/`npm` exist (`node -v` — need Node ≥ 22). If missing, ask the
   human before installing (macOS: `brew install node`; Windows: winget/nvm).

## Step 3 — Codex CLI

```bash
codex --version
```

- **Not installed** → `npm install -g @openai/codex@latest` (unified path for
  macOS/Windows/Linux). Re-check `codex --version`.
- **Installed but < 0.145.0** → upgrade. Find the install method first:
  `npm ls -g @openai/codex` (npm-global → upgrade via npm, even if the binary
  lives under a Homebrew path — it may be a symlink into npm's tree;
  `brew upgrade codex` will NOT work for those). Only use brew/winget if it was
  actually installed that way.
- Version ≥ 0.145.0 is required for the `gpt-5.6-sol` model.

## Step 4 — Auth (interactive — hand to the human)

```bash
codex login status 2>&1
```

**Gotcha:** the status line prints to **stderr**, not stdout — always merge
streams and match "Logged in" on the combined output; exit code is 0 either way.

If not logged in, ask the human to run `codex login` themselves (in Claude Code
they can type `! codex login`) — it opens a browser OAuth flow into their
ChatGPT workspace. Known failure modes:

| Symptom | Fix |
|---|---|
| `403 - Unauthorized. Contact your ChatGPT administrator` | Workspace admin must enable **Settings and Permissions → "Allow members to use Codex Local"** at chatgpt.com/admin/settings |
| `Error 400: No eligible ChatGPT workspaces found` | Same admin toggle — workspace not Codex-enabled |
| 401 `require_sso_login` after SSO refresh | `codex logout && codex login` |
| No browser (headless/remote) | `codex login --device-auth` |

## Step 5 — Discover available models, verify the top tier, let the human choose

All probes run from inside a git directory, Bash timeout ≥ 180000 ms.

1. **Refresh the model catalog** (it updates whenever codex runs):

   ```bash
   echo "" | codex exec --sandbox read-only --json "Reply with exactly: OK" 2>&1 | tail -3
   ```

2. **List what the CLI sees**, best tier first (lower `priority` = higher tier):

   ```bash
   jq -r '[.models[] | select(.visibility=="list")] | sort_by(.priority) | .[] | "\(.slug) — \(.description)"' ~/.codex/models_cache.json
   ```

3. **Live-probe the top entry** — a catalog listing does not guarantee plan
   access:

   ```bash
   echo "" | codex exec -m <top-slug> --sandbox read-only --json "Reply with exactly: OK" 2>&1 | tail -6
   ```

   - `agent_message` with `OK` → top tier verified.
   - "requires a newer version of Codex" → redo Step 3 upgrade, probe again.
   - Model-access / plan error → **tell the human plainly**: the top-tier model
     is not available on this plan/workspace, and they should ask their ChatGPT
     workspace admin for access or upgrade the subscription to get the strongest
     reviewer. Then probe the next slugs in priority order (e.g. terra → luna →
     gpt-5.5) until one verifies.
   - Rate-limit error → the 5-hour quota window is exhausted; wait and retry.

4. **Ask the human to choose** among the verified models. Recommend the best
   verified tier for the reviewer role; mention that cheaper tiers (terra/luna)
   review faster and burn less quota, at the cost of shallower critique.

5. Remember the choice for Step 6:
   - Best verified tier chosen and it equals the catalog top → **no pin**: the
     skill's auto mode always resolves the top catalog entry, so it will pick up
     future families (5.7, 5.8, …) automatically.
   - Anything else chosen (or the catalog top is NOT accessible on this plan) →
     **pin it**: after copying the skill, write the slug into
     `<skill dir>/model.txt` (e.g. `echo gpt-5.6-terra > .../model.txt`). The
     pin prevents the auto mode from repeatedly trying an inaccessible flagship.

## Step 6 — Copy the skill folders

Copy each chosen skill folder from this repo's `skills/` into the destination
from Step 1, keeping the folder as-is (SKILL.md resolves its bundled files, e.g.
`review-schema.json`, relative to its own directory):

```bash
# project scope
mkdir -p "<project>/.claude/skills" && cp -R skills/codex-debate "<project>/.claude/skills/"
# user scope
mkdir -p ~/.claude/skills && cp -R skills/codex-debate ~/.claude/skills/
```

If Step 5 decided on a pin, write it now:

```bash
echo <chosen-slug> > "<installed skill dir>/model.txt"
```

## Step 7 — Smoke test

From inside a git project (Bash timeout 300000 ms), with `$SCHEMA` pointing at
the installed `review-schema.json`:

```bash
V=$(mktemp "${TMPDIR:-/tmp}/codex-debate-smoke.XXXXXX")
echo "diff: (empty — this is a wiring test). Return verdict APPROVED, empty findings." | \
codex exec -m <verified-slug> -c model_reasoning_effort=low --sandbox read-only --json \
  --output-schema "$SCHEMA" \
  -o "$V" \
  "You are a code reviewer. Follow the stdin instruction." 2>&1 | tail -3
cat "$V"
```

(Unique temp path via `mktemp` on purpose — fixed shared paths would collide
with a debate running in another session on the same machine.)

Expected: `{"verdict":"APPROVED","summary":"...","findings":[]}`.
(`<verified-slug>` = the model chosen in Step 5.)

## Step 8 — Report to the human

Tell them, in plain language:

- Codex CLI version installed/upgraded and where it came from.
- Which model was chosen and verified — and whether it runs in auto top-tier
  mode (will pick up future model families automatically) or is pinned via
  `model.txt`. If the flagship was NOT accessible, repeat the advice to request
  access or upgrade the subscription.
- Which skills were installed and at which scope (restart the Claude Code
  session for the new skill to appear).
- That auth is via their ChatGPT workspace login — reviews consume the plan's
  rolling 5-hour quota, not money per token.
- Usage: `/codex-debate <task description>`; for review-only of existing
  changes: `/codex-debate review current changes, the task was: <what was done>`.
- Codex is a veto on "done", not a decision maker: it cannot edit code, Claude
  judges every finding, and on deadlock (5 rounds / unchanged diff) the human
  decides.
