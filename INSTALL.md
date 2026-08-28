# Install runbook — Codex reviewer skills for Claude Code

> **To the human:** clone this repo (or download it as a zip from GitHub), open
> Claude Code anywhere, and say: `follow INSTALL.md from <path to this repo>`.
>
> **To Claude executing this runbook:** work through the steps in order,
> autonomously. Verify every step's outcome before moving on; adapt commands to
> the host OS. The only steps that need the human are the scope choice (Step 1),
> the interactive `codex login`, any system-level package install (ask first),
> and the model-pin confirmation (Step 6 — never write a pin unconfirmed).
> Never use `--dangerously-bypass-approvals-and-sandbox` in any codex
> invocation.

## What you are setting up

Skills from this repo's `skills/` folder — the Codex reviewer family:

- **`codex-debate`** — the full loop: Claude implements a task, sends the diff
  to OpenAI Codex (top-tier model available on the plan, read-only sandbox)
  for adversarial review, debates the findings (fixes real ones, rebuts false
  positives with evidence), and loops — resuming the same Codex thread — until
  Codex returns `APPROVED` and local checks are green. Max 5 rounds, anti-loop
  guards included.
- **`codex-check`** — one-shot advisory review (second-tier model, quota-cheap)
  for routine changes; escalates to a debate when a major finding stands.
- **`codex-plan`** — turns a substantial multi-stage task into a staged plan
  with a review tier per stage.
- **`codex-login`** — reports which auth channel codex is on (subscription /
  API key) and drives switches; seeds the API cost-guard files.

Install all four unless the human says otherwise — check and plan reference
the debate skill, and the others lean on codex-login for auth.

Codex runs on a ChatGPT subscription (OAuth login), not a paid API key — review
tokens draw from the plan's rolling 5-hour quota window, not a per-token bill.

## Two distribution channels

- **This runbook (canonical):** clone + `install.sh` — transactional installs,
  staleness records, `--verify`/`--refresh`, bare skill names (`/codex-check`).
  Steps 1–10 below.
- **Plugin channel (additional):** marketplace install, no clone needed.
  Skills arrive NAMESPACED (`/codex-skills:codex-check`):

  ```
  /plugin marketplace add johngorat/claude-codex-skills
  /plugin install codex-skills@codex-skills
  ```

  Updates are NOT automatic by default: either enable auto-update for this
  marketplace in the `/plugin` menu (opt-in), or update manually —
  `/plugin marketplace update codex-skills` then
  `claude plugin update codex-skills` (a restart applies it). Updates track
  the repo's commits (no version field to bump).

  Steps 3–6 (codex CLI, auth, probe, model choice) apply unchanged — run the
  probe/resolver scripts from the installed plugin's skill directories. One
  difference is load-bearing: the plugin cache is REPLACED WHOLESALE on every
  update, so an in-tree `model.txt` pin cannot live there — plugin installs
  pin via the MACHINE PIN instead (`~/.claude/codex-skills-pins/<skill>.txt`,
  Step 6), which survives updates and is exactly what the resolver's guided
  bootstrap offers. Do not install BOTH channels on one machine: two
  same-described copies of every skill would compete for model-triggered
  invocation.

## Step 1 — Ask the human: install scope

- **User scope** (default) — `~/.claude/skills/` (Windows:
  `%USERPROFILE%\.claude\skills`) — available in every project on this
  machine, personal to this user.
- **Project scope** — `<project>/.claude/skills/` — the skill exists only in
  that project and travels with its repo (teammates get it on clone if
  committed). With the installer below that is just `--dest
  <project>/.claude/skills`.

## Step 2 — Prerequisites (all declared, all capability-tested later)

| Tool | Why | Notes |
|---|---|---|
| bash | every script runs as `bash <script>` | macOS ships 3.2 — that IS the floor; Windows: Git Bash (Claude Code uses it anyway) |
| git | diffs, identity hashing | any recent version |
| python3 ≥ 3.9 | all installer/resolver logic | must resolve as `python3` (macOS: `xcode-select --install`; Windows: python.org installer — NOT the Store alias) |
| codex CLI ≥ 0.145.0 | the reviewer | two channels, Step 3 |
| Node ≥ 22 | ONLY for the npm codex channel | not needed with the standalone package |

No `jq` and no other JSON tool is needed anywhere — the scripts parse with
python3 only. Version floors are enforced where they bite: `codex --version`
in Step 3, Node during the npm install, python3 by `install.sh` itself
(refuses below 3.9). Step 5 then verifies CAPABILITIES and payload health
(not version numbers) — so do not over-verify here.

## Step 3 — Codex CLI (two channels)

```bash
codex --version
```

- **Not installed** → either channel works; pick what fits the machine:
  - **npm channel** (macOS/Linux, or Windows with Node):
    `npm install -g @openai/codex@latest`
  - **standalone channel** (Windows without Node): the platform package from
    the Codex release page — no Node required at all.
- **Installed but < 0.145.0** → upgrade THROUGH ITS OWN CHANNEL. Find it
  first: `npm ls -g @openai/codex` — if it is npm-global, upgrade via npm even
  when the binary sits under a Homebrew path (it may be a symlink into npm's
  tree; `brew upgrade codex` will NOT work for those). A standalone install
  updates via its own updater/package, never via npm.
- Version ≥ 0.145.0 is required for the `gpt-5.6` model family.

## Step 4 — Auth: pick a CHANNEL, then log in (interactive — hand to the human)

```bash
codex login status 2>&1
```

**Gotcha:** the status line prints to **stderr**, not stdout — always merge
streams and match "Logged in" on the combined output; exit code is 0 either way.

Codex holds exactly ONE auth mode at a time — the human picks the channel:

| Channel | Login | Billing |
|---|---|---|
| **ChatGPT subscription** (default) | `codex login` (browser OAuth; in Claude Code: `! codex login`) | reviews draw from the plan's rolling 5-hour quota window — no per-token bill |
| **API key** | `printenv OPENAI_API_KEY \| codex login --with-api-key` — the key must reach stdin WITHOUT appearing in the command line (an already-set env var, a secret manager's print command, or `read -rs K && printf '%s' "$K" \| codex login --with-api-key`); a literal key typed into a command lands in shell history | pay-per-token; the review skills show a cost estimate and honor a machine-local cap before spending (seeded via `/codex-login` after Step 7) |

An `OPENAI_API_KEY` env var alone does NOT authenticate codex (measured:
a run without login fails 401) — it only feeds the explicit login command.
After Step 7 the installed `/codex-login` skill reports the active channel
and drives switches. Known subscription-login failure modes:

| Symptom | Fix |
|---|---|
| `403 - Unauthorized. Contact your ChatGPT administrator` | Workspace admin must enable **Settings and Permissions → "Allow members to use Codex Local"** at chatgpt.com/admin/settings |
| `Error 400: No eligible ChatGPT workspaces found` | Same admin toggle — workspace not Codex-enabled |
| 401 `require_sso_login` after SSO refresh | `codex logout && codex login` |
| No browser (headless/remote) | `codex login --device-auth` |

## Step 5 — Environment probe (one command proves the machine)

```bash
bash skills/codex-debate/scripts/env-probe.sh
```

Silent with exit 0 = the machine is healthy: bash entrypoint, git, a REAL
python3 (JSON + UTF-8 capability, not a Store alias), a codex install whose
ACTIVE payload actually matches this machine (on the npm channel that includes
Node and the platform-correct native binary), writable temp and cache, and —
once skills are installed — the installation records (Step 8). It checks
capabilities, never version numbers, and never invokes codex. Every failure
is one line on stderr naming the exact remedy; fix and re-run until silent.
The skills themselves run this probe as their declared once-per-session
prerequisite.

## Step 6 — Models: resolve, verify, let the human choose

The skills resolve their reviewer model through a strict ladder — explicit
override (`use terra` in the invocation) → in-tree pin
(`<skill dir>/model.txt`) → machine pin
(`~/.claude/codex-skills-pins/<skill>.txt` — survives plugin updates and
refreshes; the ONLY pin a plugin install can hold) → catalog → role map — and
**REFUSE with a guided bootstrap when nothing resolves**. They never guess,
never silently fall back to another model, and never write a pin by
themselves. A present-but-broken pin at either rung refuses rather than fall
through — an explicit choice is never silently masked.

1. On the npm channel the catalog cache refreshes whenever codex runs; warm it
   once (also a live smoke of the CLI):

   ```bash
   echo "" | codex exec --sandbox read-only --json "Reply with exactly: OK" 2>&1 | tail -3
   ```

2. List validated candidates with their evidence (all parsing is inside the
   resolver):

   ```bash
   bash skills/codex-debate/scripts/resolve-model.sh --propose debate
   ```

3. Live-probe the top candidate — a catalog listing does not guarantee plan
   access:

   ```bash
   echo "" | codex exec -m <top-slug> --sandbox read-only --json "Reply with exactly: OK" 2>&1 | tail -6
   ```

   - `agent_message` with `OK` → verified.
   - "requires a newer version of Codex" → redo Step 3's upgrade, probe again.
   - Model-access / plan error → tell the human plainly: the top tier is not
     available on this plan/workspace (they can ask the workspace admin or
     upgrade); probe the next candidates in order until one verifies.
   - Rate-limit error → the 5-hour quota window is exhausted; wait and retry.

4. Present the verified candidates and let the human choose (cheaper tiers
   review faster and burn less quota, at the cost of shallower critique).

5. Pin rule — **a pin is written only on the human's explicit confirmation**:
   - Choice = the verified catalog top → **no pin**; auto mode follows the
     catalog and picks up future families (5.7, 5.8, …) by itself.
   - Any other choice, or the flagship is not accessible on this plan →
     confirm with the human, then (after Step 7) write the slug into the
     INSTALLED skill dir: `echo <slug> > <installed skill dir>/model.txt` —
     or, on the plugin channel (or to survive ANY reinstall), into the
     machine pin: `mkdir -p ~/.claude/codex-skills-pins && echo <slug> >
     ~/.claude/codex-skills-pins/<skill>.txt` (`<skill>` = `codex-check` /
     `codex-debate`). If both exist, the in-tree pin wins.
   - If a skill later refuses with "no model resolves", that refusal prints
     this same bootstrap: run `--propose`, confirm a listed candidate with
     the human, write the pin — the only sanctioned way a pin comes into
     existence. When `--propose` itself reports NO candidates (no catalog
     and no role map to validate against), a pin cannot help: restore a
     naming source first, exactly as its printed remedy says (usually
     reinstall/update codex), then rerun the resolver.

## Step 7 — Install the skills (the installer owns this step)

From the repo root:

```bash
bash install.sh                                   # all skills → ~/.claude/skills, mode auto
bash install.sh --dest <dir> --mode copy <skill>  # explicit dest/mode/skill selection
```

- Modes: `copy` is the PRIMARY mode (no privileges needed anywhere);
  `symlink` is an optimization where links really work; `auto` (default) picks
  by performing a REAL directory-link capability test at the destination —
  never by guessing from git config. A symlink install updates via `git pull`
  alone; a copy install updates via `--refresh`; `--update` does everything
  in one command for either mode (Step 8).
- The install is transactional (stage → verify bytes → activate; the previous
  installation survives as a backup until the new one is verified AND
  recorded; failures roll back and say exactly what happened). Concurrent
  installs serialize on a lock.
- Each install writes a record OUTSIDE both the checkout and the destination
  (`${XDG_STATE_HOME:-~/.local/state}/claude-codex-skills/`) holding the
  canonical source location and per-file content identities — that record is
  what makes staleness DETECTABLE, not just fixable.
- A `model.txt` pin in the destination survives every refresh and mode
  switch; if both sides of a mode switch carry DIFFERENT pins, the installer
  refuses and tells the human to reconcile.

Restart the Claude Code session afterwards so new skills register.

## Step 8 — The staleness contract (what guards the install from now on)

```bash
bash install.sh --verify            # all recorded installs, both sides checked
bash install.sh --refresh           # transactional update of copy installs
bash install.sh --update            # ONE command: git pull + refresh + NEW skills
```

**Updating an existing install** (any age) is one command in the checkout:
`bash install.sh --update`. It fast-forwards the checkout, then the freshly
pulled installer refreshes every recorded install AND adopts skills that are
new upstream into your recorded destination (in your recorded mode; pins
survive). A pull that cannot fast-forward refuses with git's message and
touches nothing. Equivalent ask, if a Claude session is handy: "update the
codex skills". Plugin installs update via `claude plugin update` instead
(Step 1); a brand-new skill registers after a session restart.

`--verify` — and the record check inside `env-probe.sh`, which the skills run
as their once-per-session prerequisite — recheck both sides and fail closed.
What each loud failure means:

| Message contains | Meaning | Remedy (always printed with it) |
|---|---|---|
| `stale copy` / `source checkout changed` | the recorded source content changed — upstream update, a local edit, or corruption | look at what changed in the source first, then `bash install.sh --refresh <skill>` (refresh installs whatever the source NOW contains) |
| `differs from its record` | the installed copy was edited or corrupted | `--refresh` (restores from source) |
| `moved or disappeared` / `no longer canonical` / `aliased` | the recorded source or destination path is not the real location anymore | reinstall from/into the real location |
| `record says COPY but ... symlink` | someone replaced the installed tree | remove it and reinstall |
| `malformed` / `unreadable` / `does not BIND` (record) | the installation record itself is damaged | delete that record file and reinstall the skill |
| `holds the lock` | another install/refresh is running | wait for it, retry |
| `carry a model.txt and they DIFFER` | two conflicting pins on a mode switch | keep one of the two named files, re-run |
| `pin must be a regular file` | the pin is a symlink/special file | replace it with a plain file |
| `unsupported special file` | a FIFO/socket/device sits in the payload | remove it from the skill |

Reviewer staleness (is the MODEL current, not the files) is a separate,
report-only check — run it against the INSTALLED skill (the pin it inspects
is the EFFECTIVE one: the `model.txt` next to its own script directory when
present, else the machine pin under `~/.claude/codex-skills-pins/`):

```bash
bash <installed skill dir>/scripts/preflight-model.sh
```

Silent = fresh. Otherwise it prints ONE machine-readable line naming the stale
class — `map-missing`, `pin-unknown-to-map`, `update-not-active`,
`running-version-differs` — each with its exact remedy. It never updates codex
itself (updating the reviewer mid-gate would change the instrument).

## Step 9 — Smoke test

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
(`<verified-slug>` = the model chosen in Step 6.)

## Step 10 — Report to the human

Tell them, in plain language:

- Codex CLI version, and WHICH CHANNEL it came from (npm / standalone) — that
  channel is also its upgrade path.
- Which model was verified and chosen — auto top-tier (follows future
  families automatically) or pinned via `model.txt` (and that the pin was
  written on their confirmation). If the flagship was not accessible, repeat
  the advice to request access or upgrade the subscription.
- Which skills were installed, at which scope, and WHICH MODE the capability
  test picked — symlink (update = `git pull` in the checkout) or copy
  (update = `git pull` + `bash install.sh --refresh`); either way,
  `--verify` and the entry-time probe will catch a stale or corrupted
  install before any quota is spent on it.
- That auth is via their ChatGPT workspace login — reviews consume the plan's
  rolling 5-hour quota, not money per token.
- Usage: `/codex-debate <task description>`; for review-only of existing
  changes: `/codex-debate review current changes, the task was: <what was done>`.
- Codex is a veto on "done", not a decision maker: it cannot edit code, Claude
  judges every finding, and on deadlock (5 rounds / unchanged diff) the human
  decides.
