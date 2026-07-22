# claude-codex-skills

Claude Code skills that wire **OpenAI Codex** in as an independent, adversarial
code reviewer. Codex runs in a read-only OS sandbox on your ChatGPT
subscription; Claude stays the one making changes.

## Install

Clone this repo (or download the zip), open Claude Code, and say:

```
follow INSTALL.md from <path to this repo>
```

Claude handles the rest adaptively — Codex CLI install/upgrade, login, model
availability probe (with automatic fallback), copying the skills, and a smoke
test. You'll be asked one thing: install **per-project**
(`<project>/.claude/skills/`) or **per-user** (`~/.claude/skills/`, all projects
on the machine).

Requirements: git, Node ≥ 22, a ChatGPT plan with Codex enabled
(Free/Plus/Pro/Business/Edu/Enterprise — for company workspaces an admin must
have "Allow members to use Codex Local" on).

## Skills

| Skill | What it does |
|---|---|
| [`codex-debate`](skills/codex-debate/SKILL.md) | Run a task, then debate the resulting diff with Codex (GPT-5.6 Sol, read-only) — fix real findings, rebut false ones with evidence, loop until `APPROVED` + green local checks. Max 5 rounds, anti-loop guards. |

More Codex-related skills may land here later — each lives in its own folder
under `skills/`, self-contained (SKILL.md + bundled files), and installs the
same way.

## Security posture

- Codex is always invoked with `--sandbox read-only`; the bypass flag
  (`--dangerously-bypass-approvals-and-sandbox`) is explicitly forbidden by the
  skill's hard rules.
- No API keys are used or stored by these skills — auth is the Codex CLI's own
  `codex login` (OAuth; tokens live in `~/.codex/auth.json`, managed by the CLI).
- Reviewer feedback is never auto-applied: Claude judges every finding, and on
  disagreement the human decides.
